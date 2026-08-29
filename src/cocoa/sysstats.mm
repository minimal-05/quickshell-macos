#include "sysstats.hpp"

#include <mach/mach.h>
#include <stdlib.h>
#include <sys/sysctl.h>

namespace qs::cocoa {

SystemStats::SystemStats(QObject* parent): QObject(parent) {
	// hw.memsize and the page size never change while the process lives.
	size_t len = sizeof this->mMemTotal;
	sysctlbyname("hw.memsize", &this->mMemTotal, &len, nullptr, 0);

	vm_size_t page = 0;
	host_page_size(mach_host_self(), &page);
	this->mPageSize = page;

	QObject::connect(&this->mTimer, &QTimer::timeout, this, &SystemStats::sample);
	this->mTimer.setTimerType(Qt::CoarseTimer);
	this->mTimer.start(this->mInterval);

	// Populated before the first property read, so a consumer's initial binding
	// never sees zeros and its tick diff has a real baseline one interval later.
	this->sample();
}

void SystemStats::setInterval(int interval) {
	if (interval < 0) interval = 0;
	if (interval == this->mInterval) return;
	this->mInterval = interval;

	if (interval == 0) this->mTimer.stop();
	else this->mTimer.start(interval);

	emit this->intervalChanged();
}

void SystemStats::sample() {
	auto host = mach_host_self();
	mach_msg_type_number_t count = 0;

	host_cpu_load_info_data_t cpu {};
	count = HOST_CPU_LOAD_INFO_COUNT;
	if (host_statistics64(host, HOST_CPU_LOAD_INFO, reinterpret_cast<host_info64_t>(&cpu), &count)
	    == KERN_SUCCESS)
	{
		// CPU_STATE_USER, _SYSTEM, _IDLE, _NICE are 0, 1, 2, 3.
		for (int i = 0; i < 4; i++) {
			auto raw = static_cast<quint32>(cpu.cpu_ticks[i]);
			if (raw < this->mLastRawCpu[i]) this->mCpuWrap[i] += quint64(1) << 32;
			this->mLastRawCpu[i] = raw;
			this->mCpu[i] = this->mCpuWrap[i] + raw;
		}
	}

	vm_statistics64_data_t vm {};
	count = HOST_VM_INFO64_COUNT;
	if (host_statistics64(host, HOST_VM_INFO64, reinterpret_cast<host_info64_t>(&vm), &count)
	    == KERN_SUCCESS)
	{
		auto page = this->mPageSize;
		this->mMemFree = quint64(vm.free_count) * page;
		this->mMemActive = quint64(vm.active_count) * page;
		this->mMemInactive = quint64(vm.inactive_count) * page;
		this->mMemWired = quint64(vm.wire_count) * page;
		this->mMemCompressed = quint64(vm.compressor_page_count) * page;
		this->mMemUsed = this->mMemActive + this->mMemWired + this->mMemCompressed;
		this->mMemAvailable = this->mMemTotal > this->mMemUsed ? this->mMemTotal - this->mMemUsed : 0;
	}

	struct xsw_usage swap {};
	size_t len = sizeof swap;
	if (sysctlbyname("vm.swapusage", &swap, &len, nullptr, 0) == 0) {
		this->mSwapTotal = swap.xsu_total;
		this->mSwapUsed = swap.xsu_used;
		this->mSwapFree = swap.xsu_avail;
	}

	double load[3] = {0, 0, 0};
	if (getloadavg(load, 3) == 3) {
		this->mLoad = {load[0], load[1], load[2]};
	}

	emit this->sampled();
}

} // namespace qs::cocoa
