#pragma once

#include <qobject.h>
#include <qqmlintegration.h>
#include <qstring.h>
#include <qtmetamacros.h>

namespace qs::cocoa {

/// The internal battery and the system power mode, read in-process.
///
/// This is the backing store for the Quickshell.Services.UPower shim. There is
/// no UPower daemon on macOS; the same facts live in two places and this
/// object joins them:
///
/// - IOPowerSources (IOPSCopyPowerSourcesInfo): what `pmset -g batt` prints --
///   the integer percentage, whether the machine draws from the adapter, the
///   time estimates, the name and serial.
/// - The AppleSmartBattery node of the IORegistry: what `ioreg -c
///   AppleSmartBattery` prints -- raw mAh capacities, voltage, current, cycle
///   count, temperature and the charge/full flags.
///
/// Changes are event driven. IOPSNotificationCreateRunLoopSource fires on every
/// power-source change (a percent tick, plug, unplug, estimate update), so no
/// timer runs; NSProcessInfo posts Low Power Mode and thermal changes.
///
/// Units follow UPower: @@percentage is a fraction, times are seconds, energy
/// is watt-hours, @@energyRate is watts and is signed (positive while charging).
/// @@state uses UPowerDeviceState's numbering so a shim can assign it directly.
class Power: public QObject {
	Q_OBJECT;
	QML_NAMED_ELEMENT(Power);
	QML_SINGLETON;
	// clang-format off
	/// True once the first read has completed. Always true after construction.
	Q_PROPERTY(bool ready READ ready NOTIFY changed);
	/// A battery is installed. False on a desktop Mac.
	Q_PROPERTY(bool isPresent READ isPresent NOTIFY changed);
	/// The machine is drawing from the battery.
	Q_PROPERTY(bool onBattery READ onBattery NOTIFY changed);
	/// An adapter is plugged in, whether or not it is charging.
	Q_PROPERTY(bool externalConnected READ externalConnected NOTIFY changed);
	/// Charge as a fraction from 0 to 1. Rounded the same way pmset rounds it.
	Q_PROPERTY(qreal percentage READ percentage NOTIFY changed);
	Q_PROPERTY(qs::cocoa::Power::State state READ state NOTIFY changed);
	/// Seconds until empty; 0 unless discharging with an estimate.
	Q_PROPERTY(qreal timeToEmpty READ timeToEmpty NOTIFY changed);
	/// Seconds until full; 0 unless charging with an estimate.
	Q_PROPERTY(qreal timeToFull READ timeToFull NOTIFY changed);
	/// Watt-hours now, at full, and at full when new.
	Q_PROPERTY(qreal energy READ energy NOTIFY changed);
	Q_PROPERTY(qreal energyCapacity READ energyCapacity NOTIFY changed);
	Q_PROPERTY(qreal energyFullDesign READ energyFullDesign NOTIFY changed);
	/// Watts into (positive) or out of (negative) the battery.
	Q_PROPERTY(qreal energyRate READ energyRate NOTIFY changed);
	Q_PROPERTY(qreal voltage READ voltage NOTIFY changed);
	/// Amps, same sign as @@energyRate.
	Q_PROPERTY(qreal current READ current NOTIFY changed);
	/// Degrees Celsius.
	Q_PROPERTY(qreal temperature READ temperature NOTIFY changed);
	Q_PROPERTY(int cycleCount READ cycleCount NOTIFY changed);
	Q_PROPERTY(int designCycleCount READ designCycleCount NOTIFY changed);
	/// Full-charge capacity as a percentage of design capacity; 0 if unknown.
	Q_PROPERTY(qreal healthPercentage READ healthPercentage NOTIFY changed);
	/// IOKit's own word for it: "Good", "Fair", "Poor" or "".
	Q_PROPERTY(QString healthCondition READ healthCondition NOTIFY changed);
	/// UPower's freedesktop icon name for the current state.
	Q_PROPERTY(QString iconName READ iconName NOTIFY changed);
	/// "InternalBattery-0".
	Q_PROPERTY(QString name READ name NOTIFY changed);
	/// The gas gauge's device name.
	Q_PROPERTY(QString model READ model NOTIFY changed);
	Q_PROPERTY(QString serial READ serial NOTIFY changed);
	/// Low Power Mode, as System Settings shows it.
	Q_PROPERTY(bool lowPowerMode READ lowPowerMode NOTIFY powerModeChanged);
	/// High Power Mode is on. Only some MacBook Pros have the setting.
	Q_PROPERTY(bool highPowerMode READ highPowerMode NOTIFY powerModeChanged);
	Q_PROPERTY(bool hasHighPowerMode READ hasHighPowerMode NOTIFY powerModeChanged);
	Q_PROPERTY(qs::cocoa::Power::ThermalState thermalState READ thermalState NOTIFY thermalStateChanged);
	// clang-format on

public:
	/// UPowerDeviceState's values.
	enum class State : quint8 {
		Unknown = 0,
		Charging = 1,
		Discharging = 2,
		Empty = 3,
		FullyCharged = 4,
		PendingCharge = 5,
		PendingDischarge = 6,
	};
	Q_ENUM(State);

	/// NSProcessInfoThermalState's values.
	enum class ThermalState : quint8 {
		Nominal = 0,
		Fair = 1,
		Serious = 2,
		Critical = 3,
	};
	Q_ENUM(ThermalState);

	explicit Power(QObject* parent = nullptr);
	~Power() override;
	Q_DISABLE_COPY_MOVE(Power);

	[[nodiscard]] bool ready() const { return this->mReady; }
	[[nodiscard]] bool isPresent() const { return this->s.isPresent; }
	[[nodiscard]] bool onBattery() const { return this->s.onBattery; }
	[[nodiscard]] bool externalConnected() const { return this->s.externalConnected; }
	[[nodiscard]] qreal percentage() const { return this->s.percentage; }
	[[nodiscard]] State state() const { return this->s.state; }
	[[nodiscard]] qreal timeToEmpty() const { return this->s.timeToEmpty; }
	[[nodiscard]] qreal timeToFull() const { return this->s.timeToFull; }
	[[nodiscard]] qreal energy() const { return this->s.energy; }
	[[nodiscard]] qreal energyCapacity() const { return this->s.energyCapacity; }
	[[nodiscard]] qreal energyFullDesign() const { return this->s.energyFullDesign; }
	[[nodiscard]] qreal energyRate() const { return this->s.energyRate; }
	[[nodiscard]] qreal voltage() const { return this->s.voltage; }
	[[nodiscard]] qreal current() const { return this->s.current; }
	[[nodiscard]] qreal temperature() const { return this->s.temperature; }
	[[nodiscard]] int cycleCount() const { return this->s.cycleCount; }
	[[nodiscard]] int designCycleCount() const { return this->s.designCycleCount; }
	[[nodiscard]] qreal healthPercentage() const { return this->s.healthPercentage; }
	[[nodiscard]] QString healthCondition() const { return this->s.healthCondition; }
	[[nodiscard]] QString iconName() const { return this->s.iconName; }
	[[nodiscard]] QString name() const { return this->s.name; }
	[[nodiscard]] QString model() const { return this->s.model; }
	[[nodiscard]] QString serial() const { return this->s.serial; }
	[[nodiscard]] bool lowPowerMode() const { return this->mLowPowerMode; }
	[[nodiscard]] bool highPowerMode() const { return this->mHighPowerMode; }
	[[nodiscard]] bool hasHighPowerMode() const { return this->mHasHighPowerMode; }
	[[nodiscard]] ThermalState thermalState() const { return this->mThermalState; }

	/// Re-read everything now. The notifications already call this.
	Q_INVOKABLE void refresh();

signals:
	/// Any battery property changed.
	void changed();
	void powerModeChanged();
	void thermalStateChanged();

private:
	struct Snapshot {
		bool isPresent = false;
		bool onBattery = false;
		bool externalConnected = false;
		qreal percentage = 0;
		State state = State::Unknown;
		qreal timeToEmpty = 0;
		qreal timeToFull = 0;
		qreal energy = 0;
		qreal energyCapacity = 0;
		qreal energyFullDesign = 0;
		qreal energyRate = 0;
		qreal voltage = 0;
		qreal current = 0;
		qreal temperature = 0;
		int cycleCount = 0;
		int designCycleCount = 0;
		qreal healthPercentage = 0;
		QString healthCondition;
		QString iconName;
		QString name;
		QString model;
		QString serial;

		bool operator==(const Snapshot&) const = default;
	};

	void readBattery();
	void readPowerMode();
	void readThermalState();

	bool mReady = false;
	Snapshot s;
	bool mLowPowerMode = false;
	bool mHighPowerMode = false;
	bool mHasHighPowerMode = false;
	ThermalState mThermalState = ThermalState::Nominal;

	void* mSource = nullptr;      // CFRunLoopSourceRef
	void* mPowerObserver = nullptr;   // NSNotificationCenter token
	void* mThermalObserver = nullptr; // NSNotificationCenter token
};

} // namespace qs::cocoa
