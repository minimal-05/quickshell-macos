// qs-sysstats: one JSON line of system counters for the shell's ResourceUsage
// service. Replaces `top -l 1 -n 0` (~0.26 s CPU per run) with four Mach/sysctl
// calls (~1 ms). qs-bundle compiles it into
// Quickshell.app/Contents/Resources/tools/qs-sysstats.
//
// CPU ticks are cumulative since boot, like the `cpu` line of /proc/stat, so
// the caller diffs consecutive samples: usage = 1 - d(idle)/d(total).
// Memory "used" is (active + wired + compressor) pages, Activity Monitor's
// definition rather than top's PhysMem (which counts file cache as used).
// All memory sizes are bytes. Build: cc -O2 -o qs-sysstats qs-sysstats.c
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/sysctl.h>

int main(void) {
    host_t host = mach_host_self();
    mach_msg_type_number_t count;

    host_cpu_load_info_data_t cpu;
    count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics64(host, HOST_CPU_LOAD_INFO, (host_info64_t)&cpu, &count) != KERN_SUCCESS) {
        fputs("qs-sysstats: host_statistics64(HOST_CPU_LOAD_INFO) failed\n", stderr);
        return 1;
    }

    vm_statistics64_data_t vm;
    count = HOST_VM_INFO64_COUNT;
    if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS) {
        fputs("qs-sysstats: host_statistics64(HOST_VM_INFO64) failed\n", stderr);
        return 1;
    }

    vm_size_t page = 0;
    host_page_size(host, &page);

    unsigned long long memsize = 0;
    size_t len = sizeof memsize;
    sysctlbyname("hw.memsize", &memsize, &len, NULL, 0);

    struct xsw_usage swap = {0};
    len = sizeof swap;
    sysctlbyname("vm.swapusage", &swap, &len, NULL, 0);

    double load[3] = {0, 0, 0};
    getloadavg(load, 3);

    unsigned long long used = ((unsigned long long)vm.active_count + vm.wire_count
                               + vm.compressor_page_count) * page;
    unsigned long long avail = memsize > used ? memsize - used : 0;

    printf("{\"cpu\":{\"user\":%u,\"system\":%u,\"idle\":%u,\"nice\":%u},"
           "\"mem\":{\"total\":%llu,\"used\":%llu,\"available\":%llu,\"free\":%llu,"
           "\"active\":%llu,\"inactive\":%llu,\"wired\":%llu,\"compressed\":%llu,\"pagesize\":%lu},"
           "\"swap\":{\"total\":%llu,\"used\":%llu,\"free\":%llu},"
           "\"load\":[%.2f,%.2f,%.2f]}\n",
           cpu.cpu_ticks[CPU_STATE_USER], cpu.cpu_ticks[CPU_STATE_SYSTEM],
           cpu.cpu_ticks[CPU_STATE_IDLE], cpu.cpu_ticks[CPU_STATE_NICE],
           memsize, used, avail, (unsigned long long)vm.free_count * page,
           (unsigned long long)vm.active_count * page, (unsigned long long)vm.inactive_count * page,
           (unsigned long long)vm.wire_count * page, (unsigned long long)vm.compressor_page_count * page,
           (unsigned long)page,
           (unsigned long long)swap.xsu_total, (unsigned long long)swap.xsu_used,
           (unsigned long long)swap.xsu_avail,
           load[0], load[1], load[2]);
    return 0;
}
