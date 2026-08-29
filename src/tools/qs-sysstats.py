#!/usr/bin/env python3
"""Fallback for bin/qs-sysstats.bin when it has not been built: the same JSON
line from the same kernel calls, through ctypes. ~30 ms of interpreter startup
per run instead of ~1 ms, still far below the 260 ms `top -l 1` it replaces.
Keep the field set identical to qs-sysstats.c."""
import ctypes
import json
import os

libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
host = libc.mach_host_self()


def host_stats(flavor, nfields):
    buf = (ctypes.c_uint32 * nfields)()
    count = ctypes.c_uint32(nfields)
    if libc.host_statistics64(host, flavor, buf, ctypes.byref(count)) != 0:
        raise SystemExit(f"qs-sysstats: host_statistics64({flavor}) failed")
    return list(buf)


def sysctl(name, ctype):
    val = ctype()
    size = ctypes.c_size_t(ctypes.sizeof(val))
    libc.sysctlbyname(name.encode(), ctypes.byref(val), ctypes.byref(size), None, 0)
    return val


# HOST_CPU_LOAD_INFO = 3: cpu_ticks[user, system, idle, nice]
user, system, idle, nice = host_stats(3, 4)

# HOST_VM_INFO64 = 4: vm_statistics64 is 38 natural_t words: free, active,
# inactive, wire, then fourteen uint64 counters (28 words), then
# compressor_page_count at word 32 — see <mach/vm_statistics.h>.
vm = host_stats(4, 38)
free, active, inactive, wired = vm[0], vm[1], vm[2], vm[3]
compressed = vm[32]

page = ctypes.c_size_t()
libc.host_page_size(host, ctypes.byref(page))
page = page.value

memsize = sysctl("hw.memsize", ctypes.c_uint64).value


class XswUsage(ctypes.Structure):
    _fields_ = [("total", ctypes.c_uint64), ("avail", ctypes.c_uint64),
                ("used", ctypes.c_uint64), ("pagesize", ctypes.c_uint32),
                ("encrypted", ctypes.c_bool)]


swap = sysctl("vm.swapusage", XswUsage)
load = (ctypes.c_double * 3)()
libc.getloadavg(load, 3)

used = (active + wired + compressed) * page
print(json.dumps({
    "cpu": {"user": user, "system": system, "idle": idle, "nice": nice},
    "mem": {"total": memsize, "used": used, "available": max(memsize - used, 0),
            "free": free * page, "active": active * page, "inactive": inactive * page,
            "wired": wired * page, "compressed": compressed * page, "pagesize": page},
    "swap": {"total": swap.total, "used": swap.used, "free": swap.avail},
    "load": [round(load[0], 2), round(load[1], 2), round(load[2], 2)],
}, separators=(",", ":")))
