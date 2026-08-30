#include "power.hpp"

#import <Foundation/Foundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/ps/IOPSKeys.h>
#include <IOKit/ps/IOPowerSources.h>

#include <algorithm>
#include <cmath>
#include <optional>

// What `pmset -g` reads to print lowpowermode/highpowermode. Exported by IOKit
// since 10.x and used by Apple's own pmset, but declared only in the private
// IOPMLibPrivate.h, so the prototype is repeated here. The public
// NSProcessInfo.lowPowerModeEnabled covers Low Power Mode; nothing public
// says whether a High Power Mode setting exists on this machine.
extern "C" CFDictionaryRef IOPMCopyActivePMPreferences(void);

namespace qs::cocoa {

namespace {

std::optional<double> numberAt(CFDictionaryRef dict, const char* key) {
	if (dict == nullptr) return std::nullopt;
	auto* cfKey = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
	auto value = CFDictionaryGetValue(dict, cfKey);
	CFRelease(cfKey);
	if (value == nullptr) return std::nullopt;

	// The gas gauge publishes signed counters (Amperage while discharging) as
	// 64-bit OSNumbers with the sign bit set; ioreg prints those as huge unsigned
	// values, but a signed 64-bit read gives the real figure directly.
	if (CFGetTypeID(value) == CFNumberGetTypeID()) {
		auto* num = static_cast<CFNumberRef>(value);
		if (CFNumberIsFloatType(num)) {
			double d = 0;
			CFNumberGetValue(num, kCFNumberDoubleType, &d);
			return d;
		}
		qint64 i = 0;
		CFNumberGetValue(num, kCFNumberSInt64Type, &i);
		return static_cast<double>(i);
	}

	// IOPowerSources encodes an unknown time estimate as the string "-1".
	if (CFGetTypeID(value) == CFStringGetTypeID()) {
		return QString::fromCFString(static_cast<CFStringRef>(value)).toDouble();
	}

	if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
		return CFBooleanGetValue(static_cast<CFBooleanRef>(value)) ? 1 : 0;
	}

	return std::nullopt;
}

std::optional<bool> boolAt(CFDictionaryRef dict, const char* key) {
	auto n = numberAt(dict, key);
	if (!n) return std::nullopt;
	return *n != 0;
}

QString stringAt(CFDictionaryRef dict, const char* key) {
	if (dict == nullptr) return {};
	auto* cfKey = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
	auto value = CFDictionaryGetValue(dict, cfKey);
	CFRelease(cfKey);
	if (value == nullptr || CFGetTypeID(value) != CFStringGetTypeID()) return {};
	return QString::fromCFString(static_cast<CFStringRef>(value));
}

CFDictionaryRef dictAt(CFDictionaryRef dict, const char* key) {
	if (dict == nullptr) return nullptr;
	auto* cfKey = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
	auto value = CFDictionaryGetValue(dict, cfKey);
	CFRelease(cfKey);
	if (value == nullptr || CFGetTypeID(value) != CFDictionaryGetTypeID()) return nullptr;
	return static_cast<CFDictionaryRef>(value);
}

// UPower's own IconName values, so Quickshell.iconPath() lookups in consumer
// configs land on the freedesktop names they would on Linux.
QString iconNameFor(Power::State state, int percent, bool present) {
	if (!present) return "battery-missing-symbolic";
	if (state == Power::State::FullyCharged) return "battery-full-charged-symbolic";
	QString suffix = state == Power::State::Charging ? "-charging" : "";
	QString level = percent > 80 ? "full"
	              : percent > 50 ? "good"
	              : percent > 20 ? "low"
	              : percent > 5  ? "caution"
	                             : "empty";
	return "battery-" + level + suffix + "-symbolic";
}

void powerSourcesChanged(void* context) { static_cast<Power*>(context)->refresh(); }

} // namespace

Power::Power(QObject* parent): QObject(parent) {
	// Fires on every power-source change: a percent tick, a plug or unplug, a
	// new time estimate. Scheduled on the main run loop, which Qt's Cocoa event
	// dispatcher drives, so refresh() runs on the object's own thread.
	auto* source = IOPSNotificationCreateRunLoopSource(&powerSourcesChanged, this);
	if (source != nullptr) {
		CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
		this->mSource = source;
	}

	// NSProcessInfo posts these on a global queue, not the main thread; the
	// main-queue observer moves them onto it before any property changes.
	// The tokens come back autoreleased and this file is not built with ARC,
	// so they are retained by hand and released with the observer.
	auto* center = [NSNotificationCenter defaultCenter];
	this->mPowerObserver = [[center
	    addObserverForName:NSProcessInfoPowerStateDidChangeNotification
	                object:nil
	                 queue:[NSOperationQueue mainQueue]
	            usingBlock:^(NSNotification*) { this->readPowerMode(); }] retain];
	this->mThermalObserver = [[center
	    addObserverForName:NSProcessInfoThermalStateDidChangeNotification
	                object:nil
	                 queue:[NSOperationQueue mainQueue]
	            usingBlock:^(NSNotification*) { this->readThermalState(); }] retain];

	this->readThermalState();
	this->refresh();
}

Power::~Power() {
	if (this->mSource != nullptr) {
		auto* source = static_cast<CFRunLoopSourceRef>(this->mSource);
		CFRunLoopRemoveSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
		CFRelease(source);
	}

	auto* center = [NSNotificationCenter defaultCenter];
	for (void* token : {this->mPowerObserver, this->mThermalObserver}) {
		if (token == nullptr) continue;
		[center removeObserver:static_cast<id>(token)];
		[static_cast<id>(token) release];
	}
}

void Power::refresh() {
	this->readBattery();
	// Low Power Mode has separate battery and adapter settings, so a plug event
	// changes the effective value without the user touching System Settings.
	this->readPowerMode();
}

void Power::readBattery() {
	Snapshot next;

	// IOPowerSources: pmset's view.
	CFDictionaryRef ps = nullptr;
	auto info = IOPSCopyPowerSourcesInfo();
	CFArrayRef list = info != nullptr ? IOPSCopyPowerSourcesList(info) : nullptr;
	if (list != nullptr) {
		for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
			auto* desc = IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(list, i));
			if (stringAt(desc, kIOPSTypeKey) == QString::fromUtf8(kIOPSInternalBatteryType)) {
				ps = desc;
				break;
			}
		}
	}

	if (info != nullptr) {
		auto providing = IOPSGetProvidingPowerSourceType(info);
		next.onBattery = providing != nullptr
		              && CFStringCompare(providing, CFSTR(kIOPMBatteryPowerKey), 0) == kCFCompareEqualTo;
	}

	// IORegistry: ioreg's view. A desktop Mac has no AppleSmartBattery node.
	CFMutableDictionaryRef reg = nullptr;
	auto service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
	if (service != IO_OBJECT_NULL) {
		if (IORegistryEntryCreateCFProperties(service, &reg, kCFAllocatorDefault, 0) != KERN_SUCCESS) {
			reg = nullptr;
		}
		IOObjectRelease(service);
	}

	next.isPresent = boolAt(reg, "BatteryInstalled").value_or(boolAt(ps, kIOPSIsPresentKey).value_or(false));
	next.externalConnected = boolAt(reg, "ExternalConnected")
	                             .value_or(stringAt(ps, kIOPSPowerSourceStateKey) == QString::fromUtf8(kIOPSACPowerValue));
	auto charging = boolAt(reg, "IsCharging").value_or(boolAt(ps, kIOPSIsChargingKey).value_or(false));
	auto full = boolAt(reg, "FullyCharged").value_or(boolAt(ps, kIOPSIsChargedKey).value_or(false));

	if (next.isPresent) {
		// FullyCharged is tested first: a full battery on the adapter reports
		// IsCharging = No too, and "plugged in but held below full by optimised
		// charging" is PendingCharge, which a percentage alone cannot tell from
		// a real discharge.
		if (next.externalConnected && full) next.state = State::FullyCharged;
		else if (charging) next.state = State::Charging;
		else if (next.externalConnected) next.state = State::PendingCharge;
		else next.state = State::Discharging;
	}

	// IOPowerSources normalises the internal battery to Max = 100 and an
	// integer Current, which is the figure pmset prints. The registry ratio is
	// the same number (percent on Apple silicon, mAh on Intel) as a fallback.
	auto psCur = numberAt(ps, kIOPSCurrentCapacityKey);
	auto psMax = numberAt(ps, kIOPSMaxCapacityKey);
	auto regCur = numberAt(reg, "CurrentCapacity");
	auto regMax = numberAt(reg, "MaxCapacity");
	auto rawCur = numberAt(reg, "AppleRawCurrentCapacity").value_or(0);
	auto rawMax = numberAt(reg, "AppleRawMaxCapacity").value_or(0);
	auto design = numberAt(reg, "DesignCapacity").value_or(0);
	if (psCur && psMax && *psMax > 0) next.percentage = *psCur / *psMax;
	else if (regCur && regMax && *regMax > 0) next.percentage = *regCur / *regMax;
	else if (rawMax > 0) next.percentage = rawCur / rawMax;
	next.percentage = std::clamp(next.percentage, 0.0, 1.0);

	// Minutes. IOPowerSources says -1 while macOS has no estimate ("(no
	// estimate)" in pmset); the gas gauge's own averages use 65535 for that.
	auto minutes = [&](const char* psKey, const char* regKey) -> qreal {
		auto m = numberAt(ps, psKey).value_or(-1);
		if (m > 0) return m * 60;
		m = numberAt(reg, regKey).value_or(0);
		return m > 0 && m < 65535 ? m * 60 : 0;
	};
	if (next.state == State::Discharging) next.timeToEmpty = minutes(kIOPSTimeToEmptyKey, "AvgTimeToEmpty");
	if (next.state == State::Charging) next.timeToFull = minutes(kIOPSTimeToFullChargeKey, "AvgTimeToFull");

	// mAh x mV = uWh. Computed at the present terminal voltage rather than a
	// design voltage, which is as close as the gauge gets to UPower's figures.
	auto mv = numberAt(reg, "Voltage").value_or(0);
	next.voltage = mv / 1000;
	next.energy = rawCur * mv / 1e6;
	next.energyCapacity = rawMax * mv / 1e6;
	next.energyFullDesign = design * mv / 1e6;

	// Amperage is the gauge's averaged current, negative while the battery
	// supplies the load. Apple's PowerTelemetryData carries a better-averaged
	// power figure in mW on the Macs that publish it; its sign is taken from
	// the current so the two never disagree.
	auto ma = numberAt(reg, "Amperage").value_or(0);
	next.current = ma / 1000;
	auto sign = ma < 0 ? -1.0 : 1.0;
	auto telemetry = dictAt(reg, "PowerTelemetryData");
	auto mw = numberAt(telemetry, "BatteryPower");
	next.energyRate = mw ? sign * std::fabs(*mw) / 1000 : ma * mv / 1e6;

	next.temperature = numberAt(reg, "Temperature").value_or(0) / 100;
	next.cycleCount = static_cast<int>(numberAt(reg, "CycleCount").value_or(0));
	next.designCycleCount = static_cast<int>(numberAt(reg, "DesignCycleCount9C").value_or(0));

	// UPower's Capacity property: full-charge capacity over design capacity.
	// ponytail: System Settings' "Maximum Capacity" is a smoothed figure that
	// runs a point or two off this (81% here against 79% raw / 82% nominal).
	// Ceiling: the exact Apple number needs `system_profiler SPPowerDataType`,
	// a 1 s spawn. Upgrade path: read it once an hour in the shim if anyone
	// asks for parity with the Settings pane.
	if (design > 0 && rawMax > 0) next.healthPercentage = rawMax / design * 100;
	next.healthCondition = stringAt(ps, kIOPSBatteryHealthKey);

	next.iconName = iconNameFor(next.state, static_cast<int>(std::lround(next.percentage * 100)), next.isPresent);
	next.name = stringAt(ps, kIOPSNameKey);
	next.model = stringAt(reg, "DeviceName");
	next.serial = stringAt(ps, kIOPSHardwareSerialNumberKey);

	if (reg != nullptr) CFRelease(reg);
	if (list != nullptr) CFRelease(list);
	if (info != nullptr) CFRelease(info);

	// A battery that is present but did not read must not publish zeros: a
	// consumer treats a 0% discharging battery as flat, and end-4's battery
	// service answers flat with a suspend. Keep the previous reading instead.
	if (next.isPresent && !(next.percentage > 0) && this->mReady) return;

	auto wasReady = this->mReady;
	this->mReady = true;
	if (wasReady && next == this->s) return;
	this->s = next;
	emit this->changed();
}

void Power::readPowerMode() {
	auto low = [NSProcessInfo processInfo].lowPowerModeEnabled == YES;
	auto high = false;
	auto hasHigh = false;

	// The setting pmset -g lists as highpowermode, in the active source's
	// dictionary. Only the MacBook Pros that offer the mode carry the key.
	auto prefs = IOPMCopyActivePMPreferences();
	if (prefs != nullptr) {
		for (const char* source : {kIOPMACPowerKey, kIOPMBatteryPowerKey}) {
			auto set = dictAt(prefs, source);
			auto value = numberAt(set, "HighPowerMode");
			if (!value) continue;
			hasHigh = true;
			auto active = this->s.onBattery ? kIOPMBatteryPowerKey : kIOPMACPowerKey;
			if (source == active) high = *value != 0;
		}
		CFRelease(prefs);
	}

	if (low == this->mLowPowerMode && high == this->mHighPowerMode && hasHigh == this->mHasHighPowerMode) {
		return;
	}

	this->mLowPowerMode = low;
	this->mHighPowerMode = high;
	this->mHasHighPowerMode = hasHigh;
	emit this->powerModeChanged();
}

void Power::readThermalState() {
	auto state = static_cast<ThermalState>([NSProcessInfo processInfo].thermalState);
	if (state == this->mThermalState) return;
	this->mThermalState = state;
	emit this->thermalStateChanged();
}

} // namespace qs::cocoa
