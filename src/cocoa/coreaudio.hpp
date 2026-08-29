#pragma once

#include <qhash.h>
#include <qlist.h>
#include <qobject.h>
#include <qqmlintegration.h>
#include <qstring.h>
#include <qtmetamacros.h>

namespace qs::cocoa {

class CoreAudio;

/// One CoreAudio device, as the HAL reports it.
///
/// A device may play, record, or both (a Bluetooth headset does both), so the
/// volume and mute controls come in an output and an input set. A set whose
/// device has no streams in that direction reports zero channels and
/// unsupported controls; reads return 0 / false and writes are dropped.
///
/// Every value here is pushed by the HAL's property listener the moment it
/// changes, whoever changed it (the volume keys, another app, the Sound
/// settings pane). Nothing is polled.
///
/// Mute on a device without a hardware mute control (most USB microphones) is
/// emulated: muting parks the volume at zero and unmuting restores the last
/// non-zero level. `outputMuteSupported` / `inputMuteSupported` tell the two
/// apart.
class CoreAudioDevice: public QObject {
	Q_OBJECT;
	QML_NAMED_ELEMENT(CoreAudioDevice);
	QML_UNCREATABLE("CoreAudioDevice objects are owned by the CoreAudio singleton.");
	/// The AudioObjectID, stable for as long as the device stays plugged in.
	Q_PROPERTY(quint32 id READ id CONSTANT);
	/// kAudioDevicePropertyDeviceUID: the persistent identifier, e.g.
	/// "BuiltInSpeakerDevice", which survives unplug/replug and reboots.
	Q_PROPERTY(QString uid READ uid CONSTANT);
	/// The user-facing name, e.g. "MacBook Air Speakers".
	Q_PROPERTY(QString name READ name NOTIFY nameChanged);
	/// The bus, lowercased: "builtin", "usb", "bluetooth", "hdmi", "airplay",
	/// "continuity", "virtual", "aggregate", ... or "unknown".
	Q_PROPERTY(QString transport READ transport CONSTANT);

	Q_PROPERTY(int outputChannels READ outputChannels NOTIFY outputChanged);
	/// 0.0 - 1.0 scalar (kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
	/// falling back to per-channel kAudioDevicePropertyVolumeScalar).
	Q_PROPERTY(float outputVolume READ outputVolume WRITE setOutputVolume NOTIFY outputChanged);
	Q_PROPERTY(bool outputMuted READ outputMuted WRITE setOutputMuted NOTIFY outputChanged);
	Q_PROPERTY(bool outputVolumeSupported READ outputVolumeSupported NOTIFY outputChanged);
	Q_PROPERTY(bool outputMuteSupported READ outputMuteSupported NOTIFY outputChanged);

	Q_PROPERTY(int inputChannels READ inputChannels NOTIFY inputChanged);
	Q_PROPERTY(float inputVolume READ inputVolume WRITE setInputVolume NOTIFY inputChanged);
	Q_PROPERTY(bool inputMuted READ inputMuted WRITE setInputMuted NOTIFY inputChanged);
	Q_PROPERTY(bool inputVolumeSupported READ inputVolumeSupported NOTIFY inputChanged);
	Q_PROPERTY(bool inputMuteSupported READ inputMuteSupported NOTIFY inputChanged);

public:
	~CoreAudioDevice() override;
	Q_DISABLE_COPY_MOVE(CoreAudioDevice);

	[[nodiscard]] quint32 id() const { return this->mId; }
	[[nodiscard]] QString uid() const { return this->mUid; }
	[[nodiscard]] QString name() const { return this->mName; }
	[[nodiscard]] QString transport() const { return this->mTransport; }

	[[nodiscard]] int outputChannels() const { return this->mOutput.channels; }
	[[nodiscard]] float outputVolume() const { return this->mOutput.volume; }
	[[nodiscard]] bool outputMuted() const { return this->mOutput.muted; }
	[[nodiscard]] bool outputVolumeSupported() const { return this->mOutput.volumeSupported; }
	[[nodiscard]] bool outputMuteSupported() const { return this->mOutput.muteSupported; }
	void setOutputVolume(float volume);
	void setOutputMuted(bool muted);

	[[nodiscard]] int inputChannels() const { return this->mInput.channels; }
	[[nodiscard]] float inputVolume() const { return this->mInput.volume; }
	[[nodiscard]] bool inputMuted() const { return this->mInput.muted; }
	[[nodiscard]] bool inputVolumeSupported() const { return this->mInput.volumeSupported; }
	[[nodiscard]] bool inputMuteSupported() const { return this->mInput.muteSupported; }
	void setInputVolume(float volume);
	void setInputMuted(bool muted);

signals:
	void nameChanged();
	/// Any output-side value changed: channels, volume, mute or support flags.
	void outputChanged();
	/// Any input-side value changed.
	void inputChanged();

private:
	friend class CoreAudio;

	struct Controls {
		int channels = 0;
		float volume = 0.0F;
		bool muted = false;
		bool volumeSupported = false;
		bool muteSupported = false;
		// Emulated mute (no hardware control): the level to come back to.
		float restoreVolume = 0.5F;
	};

	explicit CoreAudioDevice(quint32 id, QObject* parent);

	// Re-read one side (or the name) from the HAL and emit if anything moved.
	void refreshName();
	void refresh(Controls& controls, unsigned scope);
	void setVolume(Controls& controls, unsigned scope, float volume);
	void setMuted(Controls& controls, unsigned scope, bool muted);
	void emitChanged(const Controls& controls);

	quint32 mId;
	QString mUid;
	QString mName;
	QString mTransport;
	Controls mOutput;
	Controls mInput;
	// The AudioObjectPropertyListenerBlock installed on this device; a wildcard
	// address, so one registration covers volume, mute, name and stream layout.
	void* mListener = nullptr;
};

/// The system's audio devices and defaults, straight from the CoreAudio HAL.
///
/// This is what the Pipewire compatibility shim reads. It replaces the
/// osascript / SwitchAudioSource polling the shim used to do: every property
/// here is kept current by AudioObjectAddPropertyListenerBlock, so a volume
/// key press or a device being plugged in reaches QML within a millisecond
/// and costs nothing while idle.
///
/// Writing `defaultOutput` / `defaultInput` switches the system default; the
/// property only reflects the change once the HAL confirms it, the way
/// pipewire's preferred-default metadata works upstream.
class CoreAudio: public QObject {
	Q_OBJECT;
	QML_NAMED_ELEMENT(CoreAudio);
	QML_SINGLETON;
	/// Every device the HAL lists, in HAL order. Objects keep their identity for
	/// as long as the device is present.
	Q_PROPERTY(QList<QObject*> devices READ devices NOTIFY devicesChanged);
	Q_PROPERTY(qs::cocoa::CoreAudioDevice* defaultOutput READ defaultOutput WRITE setDefaultOutput NOTIFY defaultOutputChanged);
	Q_PROPERTY(qs::cocoa::CoreAudioDevice* defaultInput READ defaultInput WRITE setDefaultInput NOTIFY defaultInputChanged);

public:
	explicit CoreAudio(QObject* parent = nullptr);
	~CoreAudio() override;
	Q_DISABLE_COPY_MOVE(CoreAudio);

	[[nodiscard]] QList<QObject*> devices() const { return this->mDeviceList; }
	[[nodiscard]] CoreAudioDevice* defaultOutput() const { return this->mDefaultOutput; }
	[[nodiscard]] CoreAudioDevice* defaultInput() const { return this->mDefaultInput; }
	void setDefaultOutput(CoreAudioDevice* device);
	void setDefaultInput(CoreAudioDevice* device);

signals:
	void devicesChanged();
	void defaultOutputChanged();
	void defaultInputChanged();

private:
	void refreshDevices();
	void refreshDefaults();
	// Called on the Qt thread for a listener event on `id`; `what` is a mask of
	// the Refresh bits in coreaudio.mm.
	void onDeviceEvent(quint32 id, unsigned what);
	CoreAudioDevice* attach(quint32 id);

	QHash<quint32, CoreAudioDevice*> mDevices;
	QList<QObject*> mDeviceList;
	CoreAudioDevice* mDefaultOutput = nullptr;
	CoreAudioDevice* mDefaultInput = nullptr;
	void* mSystemListener = nullptr;
};

} // namespace qs::cocoa
