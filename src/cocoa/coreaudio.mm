#include "coreaudio.hpp"

#import <AudioToolbox/AudioServices.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreFoundation/CoreFoundation.h>

#include <Block.h>
#include <algorithm>
#include <cstdlib>
#include <dispatch/dispatch.h>

#include <qcoreapplication.h>
#include <qhash.h>
#include <qlist.h>
#include <qlogging.h>
#include <qmetaobject.h>
#include <qpointer.h>
#include <qstring.h>

namespace qs::cocoa {

namespace {

enum Refresh : unsigned {
	RefreshName = 1,
	RefreshOutput = 2,
	RefreshInput = 4,
};

AudioObjectPropertyAddress address(
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal,
    AudioObjectPropertyElement element = kAudioObjectPropertyElementMain
) {
	return {selector, scope, element};
}

// Listeners run on a libdispatch queue, not the Qt thread. The block only
// classifies the event and hops to the main thread with the device id, so no
// QObject is touched off-thread. A global queue is fine: every hop re-reads
// the HAL rather than carrying a value, so delivery order does not matter.
dispatch_queue_t listenerQueue() { return dispatch_get_global_queue(QOS_CLASS_UTILITY, 0); }

bool has(AudioObjectID object, const AudioObjectPropertyAddress& addr) {
	return AudioObjectHasProperty(object, &addr);
}

bool settable(AudioObjectID object, const AudioObjectPropertyAddress& addr) {
	Boolean result = false;
	return AudioObjectIsPropertySettable(object, &addr, &result) == noErr && result;
}

template <typename T>
bool get(AudioObjectID object, const AudioObjectPropertyAddress& addr, T& out) {
	UInt32 size = sizeof(T);
	return AudioObjectGetPropertyData(object, &addr, 0, nullptr, &size, &out) == noErr;
}

template <typename T>
bool set(AudioObjectID object, const AudioObjectPropertyAddress& addr, const T& value) {
	return AudioObjectSetPropertyData(object, &addr, 0, nullptr, sizeof(T), &value) == noErr;
}

QString getString(AudioObjectID object, AudioObjectPropertySelector selector) {
	CFStringRef string = nullptr;
	if (!get(object, address(selector), string) || string == nullptr) return {};
	auto result = QString::fromCFString(string);
	CFRelease(string);
	return result;
}

int channelCount(AudioObjectID object, AudioObjectPropertyScope scope) {
	auto addr = address(kAudioDevicePropertyStreamConfiguration, scope);
	UInt32 size = 0;
	if (AudioObjectGetPropertyDataSize(object, &addr, 0, nullptr, &size) != noErr || size == 0) return 0;

	auto* list = static_cast<AudioBufferList*>(std::malloc(size));
	if (list == nullptr) return 0;

	int channels = 0;
	if (AudioObjectGetPropertyData(object, &addr, 0, nullptr, &size, list) == noErr) {
		for (UInt32 i = 0; i < list->mNumberBuffers; ++i) {
			channels += static_cast<int>(list->mBuffers[i].mNumberChannels);
		}
	}

	std::free(list);
	return channels;
}

QString transportName(UInt32 transport) {
	switch (transport) {
	case kAudioDeviceTransportTypeBuiltIn: return QStringLiteral("builtin");
	case kAudioDeviceTransportTypeAggregate: return QStringLiteral("aggregate");
	case kAudioDeviceTransportTypeVirtual: return QStringLiteral("virtual");
	case kAudioDeviceTransportTypePCI: return QStringLiteral("pci");
	case kAudioDeviceTransportTypeUSB: return QStringLiteral("usb");
	case kAudioDeviceTransportTypeFireWire: return QStringLiteral("firewire");
	case kAudioDeviceTransportTypeBluetooth:
	case kAudioDeviceTransportTypeBluetoothLE: return QStringLiteral("bluetooth");
	case kAudioDeviceTransportTypeHDMI: return QStringLiteral("hdmi");
	case kAudioDeviceTransportTypeDisplayPort: return QStringLiteral("displayport");
	case kAudioDeviceTransportTypeAirPlay: return QStringLiteral("airplay");
	case kAudioDeviceTransportTypeAVB: return QStringLiteral("avb");
	case kAudioDeviceTransportTypeThunderbolt: return QStringLiteral("thunderbolt");
	case kAudioDeviceTransportTypeContinuityCaptureWired:
	case kAudioDeviceTransportTypeContinuityCaptureWireless: return QStringLiteral("continuity");
	default: return QStringLiteral("unknown");
	}
}

// Volume lives in one of three places depending on the driver: the HAL's
// virtual main volume (what the Sound settings slider and the volume keys
// move), a main-element scalar, or only per-channel scalars. Apple's built-in
// devices expose the first two; some USB interfaces expose only the last.
// Reads and writes try them in that order.
const AudioObjectPropertySelector VOLUME_SELECTORS[] = {
    kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
    kAudioDevicePropertyVolumeScalar,
};

bool readVolume(AudioObjectID object, AudioObjectPropertyScope scope, int channels, float& out) {
	for (auto selector: VOLUME_SELECTORS) {
		auto addr = address(selector, scope);
		Float32 value = 0;
		if (has(object, addr) && get(object, addr, value)) {
			out = value;
			return true;
		}
	}

	float sum = 0;
	int found = 0;
	for (int channel = 1; channel <= channels; ++channel) {
		auto addr = address(kAudioDevicePropertyVolumeScalar, scope, channel);
		Float32 value = 0;
		if (has(object, addr) && get(object, addr, value)) {
			sum += value;
			++found;
		}
	}

	if (found == 0) return false;
	out = sum / static_cast<float>(found);
	return true;
}

bool writeVolume(AudioObjectID object, AudioObjectPropertyScope scope, int channels, float volume) {
	for (auto selector: VOLUME_SELECTORS) {
		auto addr = address(selector, scope);
		if (has(object, addr) && settable(object, addr)) return set(object, addr, static_cast<Float32>(volume));
	}

	bool any = false;
	for (int channel = 1; channel <= channels; ++channel) {
		auto addr = address(kAudioDevicePropertyVolumeScalar, scope, channel);
		if (has(object, addr) && settable(object, addr)) any |= set(object, addr, static_cast<Float32>(volume));
	}

	return any;
}

bool volumeWritable(AudioObjectID object, AudioObjectPropertyScope scope, int channels) {
	for (auto selector: VOLUME_SELECTORS) {
		auto addr = address(selector, scope);
		if (has(object, addr) && settable(object, addr)) return true;
	}

	for (int channel = 1; channel <= channels; ++channel) {
		auto addr = address(kAudioDevicePropertyVolumeScalar, scope, channel);
		if (has(object, addr) && settable(object, addr)) return true;
	}

	return false;
}

// Mute: a main-element control, or per-channel controls that all move together.

bool readMute(AudioObjectID object, AudioObjectPropertyScope scope, int channels, bool& out) {
	for (int element = 0; element <= channels; ++element) {
		auto addr = address(kAudioDevicePropertyMute, scope, element);
		UInt32 value = 0;
		if (has(object, addr) && get(object, addr, value)) {
			out = value != 0;
			return true;
		}
	}

	return false;
}

bool writeMute(AudioObjectID object, AudioObjectPropertyScope scope, int channels, bool muted) {
	auto main = address(kAudioDevicePropertyMute, scope);
	if (has(object, main) && settable(object, main)) return set(object, main, static_cast<UInt32>(muted));

	bool any = false;
	for (int channel = 1; channel <= channels; ++channel) {
		auto addr = address(kAudioDevicePropertyMute, scope, channel);
		if (has(object, addr) && settable(object, addr)) any |= set(object, addr, static_cast<UInt32>(muted));
	}

	return any;
}

bool muteWritable(AudioObjectID object, AudioObjectPropertyScope scope, int channels) {
	for (int element = 0; element <= channels; ++element) {
		auto addr = address(kAudioDevicePropertyMute, scope, element);
		if (has(object, addr) && settable(object, addr)) return true;
	}

	return false;
}

// Which of a device's sides an event touches. Anything not listed (sample
// rate, running state, latency, ...) is ignored.
unsigned classify(UInt32 count, const AudioObjectPropertyAddress* addresses) {
	unsigned what = 0;

	for (UInt32 i = 0; i < count; ++i) {
		const auto& addr = addresses[i];

		switch (addr.mSelector) {
		case kAudioObjectPropertyName: what |= RefreshName; break;
		// Plugging headphones into the jack switches the data source, and with
		// it which controls exist, without any volume notification.
		case kAudioDevicePropertyDataSource: what |= RefreshOutput | RefreshInput; break;
		case kAudioDevicePropertyVolumeScalar:
		case kAudioDevicePropertyVolumeDecibels:
		case kAudioHardwareServiceDeviceProperty_VirtualMainVolume:
		case kAudioDevicePropertyMute:
		case kAudioDevicePropertyStreamConfiguration:
		case kAudioDevicePropertyStreams:
			if (addr.mScope == kAudioObjectPropertyScopeOutput) what |= RefreshOutput;
			else if (addr.mScope == kAudioObjectPropertyScopeInput) what |= RefreshInput;
			else what |= RefreshOutput | RefreshInput;
			break;
		default: break;
		}
	}

	return what;
}

// Every registration uses the wildcard address, so removal does too.
const AudioObjectPropertyAddress WILDCARD = {
    kAudioObjectPropertySelectorWildcard,
    kAudioObjectPropertyScopeWildcard,
    kAudioObjectPropertyElementWildcard,
};

} // namespace

// --- CoreAudioDevice ---------------------------------------------------------

CoreAudioDevice::CoreAudioDevice(quint32 id, QObject* parent): QObject(parent), mId(id) {
	this->mUid = getString(id, kAudioDevicePropertyDeviceUID);
	this->mName = getString(id, kAudioObjectPropertyName);

	UInt32 transport = 0;
	get(id, address(kAudioDevicePropertyTransportType), transport);
	this->mTransport = transportName(transport);

	this->refresh(this->mOutput, kAudioObjectPropertyScopeOutput);
	this->refresh(this->mInput, kAudioObjectPropertyScopeInput);
}

CoreAudioDevice::~CoreAudioDevice() {
	if (this->mListener == nullptr) return;
	auto block = (AudioObjectPropertyListenerBlock) this->mListener;
	AudioObjectRemovePropertyListenerBlock(this->mId, &WILDCARD, listenerQueue(), block);
	Block_release(block);
	this->mListener = nullptr;
}

void CoreAudioDevice::refreshName() {
	auto name = getString(this->mId, kAudioObjectPropertyName);
	if (name.isEmpty() || name == this->mName) return;
	this->mName = name;
	emit this->nameChanged();
}

void CoreAudioDevice::refresh(Controls& controls, unsigned scope) {
	Controls next = controls;
	next.channels = channelCount(this->mId, scope);
	next.volumeSupported = volumeWritable(this->mId, scope, next.channels);
	next.muteSupported = muteWritable(this->mId, scope, next.channels);

	if (!readVolume(this->mId, scope, next.channels, next.volume)) next.volume = 0.0F;
	if (next.volume > 0.0F) next.restoreVolume = next.volume;

	if (next.muteSupported) {
		if (!readMute(this->mId, scope, next.channels, next.muted)) next.muted = false;
	} else {
		next.muted = next.volumeSupported && next.volume <= 0.0F;
	}

	bool changed = next.channels != controls.channels || next.volume != controls.volume
	            || next.muted != controls.muted || next.volumeSupported != controls.volumeSupported
	            || next.muteSupported != controls.muteSupported;

	controls = next;
	if (changed) this->emitChanged(controls);
}

void CoreAudioDevice::setVolume(Controls& controls, unsigned scope, float volume) {
	volume = std::clamp(volume, 0.0F, 1.0F);
	if (!controls.volumeSupported) return;
	if (!writeVolume(this->mId, scope, controls.channels, volume)) {
		qWarning() << "CoreAudio: could not set volume on" << this->mName;
		return;
	}

	// Re-read rather than trust the request: hardware quantises (16 notches on
	// the built-in speakers), and QML should show where the level landed.
	// The HAL's own notification follows and finds nothing left to change.
	this->refresh(controls, scope);
}

void CoreAudioDevice::setMuted(Controls& controls, unsigned scope, bool muted) {
	if (controls.muteSupported) {
		if (muted == controls.muted) return;
		if (!writeMute(this->mId, scope, controls.channels, muted)) {
			qWarning() << "CoreAudio: could not set mute on" << this->mName;
			return;
		}
		this->refresh(controls, scope);
		return;
	}

	// No mute control: park the level at zero and remember where it was.
	if (!controls.volumeSupported || muted == controls.muted) return;
	auto level = muted ? 0.0F : (controls.restoreVolume > 0.0F ? controls.restoreVolume : 0.5F);
	auto restore = controls.restoreVolume;
	this->setVolume(controls, scope, level);
	controls.restoreVolume = restore;
}

void CoreAudioDevice::emitChanged(const Controls& controls) {
	if (&controls == &this->mOutput) emit this->outputChanged();
	else emit this->inputChanged();
}

void CoreAudioDevice::setOutputVolume(float volume) {
	this->setVolume(this->mOutput, kAudioObjectPropertyScopeOutput, volume);
}

void CoreAudioDevice::setOutputMuted(bool muted) {
	this->setMuted(this->mOutput, kAudioObjectPropertyScopeOutput, muted);
}

void CoreAudioDevice::setInputVolume(float volume) {
	this->setVolume(this->mInput, kAudioObjectPropertyScopeInput, volume);
}

void CoreAudioDevice::setInputMuted(bool muted) {
	this->setMuted(this->mInput, kAudioObjectPropertyScopeInput, muted);
}

// --- CoreAudio ---------------------------------------------------------------

CoreAudio::CoreAudio(QObject* parent): QObject(parent) {
	auto self = QPointer<CoreAudio>(this);
	auto block = ^(UInt32 count, const AudioObjectPropertyAddress* addresses) {
	  bool devices = false;
	  bool defaults = false;
	  for (UInt32 i = 0; i < count; ++i) {
		  switch (addresses[i].mSelector) {
		  case kAudioHardwarePropertyDevices: devices = true; break;
		  case kAudioHardwarePropertyDefaultOutputDevice:
		  case kAudioHardwarePropertyDefaultInputDevice: defaults = true; break;
		  default: break;
		  }
	  }
	  if (!devices && !defaults) return;

	  QMetaObject::invokeMethod(
	      QCoreApplication::instance(),
	      [self, devices, defaults]() {
		      if (!self) return;
		      if (devices) self->refreshDevices();
		      if (defaults) self->refreshDefaults();
	      },
	      Qt::QueuedConnection
	  );
	};

	auto copy = Block_copy(block);
	this->mSystemListener = copy;
	AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &WILDCARD, listenerQueue(), copy);

	this->refreshDevices();
	this->refreshDefaults();
}

CoreAudio::~CoreAudio() {
	if (this->mSystemListener != nullptr) {
		auto block = (AudioObjectPropertyListenerBlock) this->mSystemListener;
		AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &WILDCARD, listenerQueue(), block);
		Block_release(block);
		this->mSystemListener = nullptr;
	}

	// Children are deleted by QObject, but their listeners must be gone before
	// a late event can look one of them up.
	for (auto* device: this->mDevices) delete device;
	this->mDevices.clear();
}

CoreAudioDevice* CoreAudio::attach(quint32 id) {
	auto* device = new CoreAudioDevice(id, this);

	auto self = QPointer<CoreAudio>(this);
	auto block = ^(UInt32 count, const AudioObjectPropertyAddress* addresses) {
	  auto what = classify(count, addresses);
	  if (what == 0) return;

	  QMetaObject::invokeMethod(
	      QCoreApplication::instance(),
	      [self, id, what]() {
		      if (self) self->onDeviceEvent(id, what);
	      },
	      Qt::QueuedConnection
	  );
	};

	auto copy = Block_copy(block);
	device->mListener = copy;
	AudioObjectAddPropertyListenerBlock(id, &WILDCARD, listenerQueue(), copy);

	return device;
}

void CoreAudio::onDeviceEvent(quint32 id, unsigned what) {
	auto* device = this->mDevices.value(id, nullptr);
	if (device == nullptr) return;

	if ((what & RefreshName) != 0) device->refreshName();
	if ((what & RefreshOutput) != 0) device->refresh(device->mOutput, kAudioObjectPropertyScopeOutput);
	if ((what & RefreshInput) != 0) device->refresh(device->mInput, kAudioObjectPropertyScopeInput);
}

void CoreAudio::refreshDevices() {
	auto addr = address(kAudioHardwarePropertyDevices);
	UInt32 size = 0;
	if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, nullptr, &size) != noErr) return;

	auto ids = QList<AudioDeviceID>(size / sizeof(AudioDeviceID));
	if (!ids.isEmpty()
	    && AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, nullptr, &size, ids.data()) != noErr)
	{
		return;
	}

	auto kept = QHash<quint32, CoreAudioDevice*>();
	auto list = QList<QObject*>();
	bool changed = false;

	for (auto id: ids) {
		auto* device = this->mDevices.value(id, nullptr);
		if (device == nullptr) {
			device = this->attach(id);
			changed = true;
		}
		kept.insert(id, device);
		list.append(device);
	}

	auto gone = QList<CoreAudioDevice*>();
	for (auto* device: this->mDevices) {
		if (!kept.contains(device->id())) gone.append(device);
	}

	changed = changed || !gone.isEmpty() || list != this->mDeviceList;
	this->mDevices = kept;
	this->mDeviceList = list;

	if (changed) emit this->devicesChanged();

	// A vanished device may have been a default; resolve that against the new
	// list before the object goes away so QML never holds a dangling default.
	if (!gone.isEmpty()) {
		this->refreshDefaults();
		// deleteLater, not delete: the shim's rebuild handlers run inside the
		// devicesChanged emission above and may still be reading the object.
		for (auto* device: gone) device->deleteLater();
	}
}

void CoreAudio::refreshDefaults() {
	AudioDeviceID output = 0;
	AudioDeviceID input = 0;
	get(kAudioObjectSystemObject, address(kAudioHardwarePropertyDefaultOutputDevice), output);
	get(kAudioObjectSystemObject, address(kAudioHardwarePropertyDefaultInputDevice), input);

	// The default can change to a device whose Devices notification has not
	// been delivered yet (the two arrive separately on plug-in).
	if ((output != 0 && !this->mDevices.contains(output)) || (input != 0 && !this->mDevices.contains(input))) {
		this->refreshDevices();
	}

	auto* newOutput = this->mDevices.value(output, nullptr);
	auto* newInput = this->mDevices.value(input, nullptr);

	if (newOutput != this->mDefaultOutput) {
		this->mDefaultOutput = newOutput;
		emit this->defaultOutputChanged();
	}

	if (newInput != this->mDefaultInput) {
		this->mDefaultInput = newInput;
		emit this->defaultInputChanged();
	}
}

void CoreAudio::setDefaultOutput(CoreAudioDevice* device) {
	if (device == nullptr || device == this->mDefaultOutput || device->outputChannels() == 0) return;
	if (!set(kAudioObjectSystemObject, address(kAudioHardwarePropertyDefaultOutputDevice), static_cast<AudioDeviceID>(device->id()))) {
		qWarning() << "CoreAudio: could not make" << device->name() << "the default output";
		return;
	}
	this->refreshDefaults();
}

void CoreAudio::setDefaultInput(CoreAudioDevice* device) {
	if (device == nullptr || device == this->mDefaultInput || device->inputChannels() == 0) return;
	if (!set(kAudioObjectSystemObject, address(kAudioHardwarePropertyDefaultInputDevice), static_cast<AudioDeviceID>(device->id()))) {
		qWarning() << "CoreAudio: could not make" << device->name() << "the default input";
		return;
	}
	this->refreshDefaults();
}

} // namespace qs::cocoa
