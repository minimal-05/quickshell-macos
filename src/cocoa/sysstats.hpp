#pragma once

#include <qobject.h>
#include <qqmlintegration.h>
#include <qtimer.h>
#include <qtmetamacros.h>

namespace qs::cocoa {

/// In-process CPU, memory and swap counters for a resource widget.
///
/// Linux configs read /proc/stat and /proc/meminfo; macOS has neither, and the
/// substitutes (`top -l 1`, or a helper binary) are a process spawn per sample.
/// The same counters are three Mach/sysctl calls from inside the shell, so this
/// samples them on a timer and publishes them as properties: zero spawns, and
/// about a microsecond of CPU per sample.
///
/// CPU ticks are cumulative since boot, like the `cpu` line of /proc/stat, so a
/// consumer diffs consecutive samples: usage = 1 - d(cpuIdle)/d(cpuTotal). The
/// kernel counter is 32 bits per state and wraps after roughly a month of
/// uptime; the values here are widened to 64 bits so they only ever grow.
///
/// Memory sizes are bytes. `memUsed` is (active + wired + compressor) pages,
/// Activity Monitor's definition rather than top's PhysMem line, which counts
/// file cache as used. `memAvailable` is total minus that.
class SystemStats: public QObject {
	Q_OBJECT;
	QML_NAMED_ELEMENT(SystemStats);
	QML_SINGLETON;
	// clang-format off
	/// Milliseconds between samples. 0 stops the timer.
	Q_PROPERTY(int interval READ interval WRITE setInterval NOTIFY intervalChanged);
	/// Ticks spent idle, and in every state, summed over all cores since boot.
	Q_PROPERTY(quint64 cpuIdle READ cpuIdle NOTIFY sampled);
	Q_PROPERTY(quint64 cpuTotal READ cpuTotal NOTIFY sampled);
	/// hw.memsize.
	Q_PROPERTY(quint64 memTotal READ memTotal NOTIFY sampled);
	Q_PROPERTY(quint64 memUsed READ memUsed NOTIFY sampled);
	Q_PROPERTY(quint64 memAvailable READ memAvailable NOTIFY sampled);
	/// vm.swapusage, bytes.
	Q_PROPERTY(quint64 swapTotal READ swapTotal NOTIFY sampled);
	Q_PROPERTY(quint64 swapFree READ swapFree NOTIFY sampled);
	// clang-format on

public:
	explicit SystemStats(QObject* parent = nullptr);

	[[nodiscard]] int interval() const { return this->mInterval; }
	void setInterval(int interval);

	[[nodiscard]] quint64 cpuIdle() const { return this->mCpu[2]; }
	[[nodiscard]] quint64 cpuTotal() const {
		return this->mCpu[0] + this->mCpu[1] + this->mCpu[2] + this->mCpu[3];
	}

	[[nodiscard]] quint64 memTotal() const { return this->mMemTotal; }
	[[nodiscard]] quint64 memUsed() const { return this->mMemUsed; }
	[[nodiscard]] quint64 memAvailable() const { return this->mMemAvailable; }
	[[nodiscard]] quint64 swapTotal() const { return this->mSwapTotal; }
	[[nodiscard]] quint64 swapFree() const { return this->mSwapFree; }

	/// Seconds since the user last touched a key, the mouse or the trackpad,
	/// as the window server counts it. What IdleMonitor polls.
	Q_INVOKABLE [[nodiscard]] double idleSeconds() const;

signals:
	void sampled();
	void intervalChanged();

private:
	void sample();

	int mInterval = 3000;
	QTimer mTimer;

	// user, system, idle, nice -- the CPU_STATE_* order.
	quint64 mCpu[4] = {0, 0, 0, 0};
	quint32 mLastRawCpu[4] = {0, 0, 0, 0};
	quint64 mCpuWrap[4] = {0, 0, 0, 0};

	quint64 mPageSize = 0;
	quint64 mMemTotal = 0;
	quint64 mMemUsed = 0;
	quint64 mMemAvailable = 0;
	quint64 mSwapTotal = 0;
	quint64 mSwapFree = 0;
};

} // namespace qs::cocoa
