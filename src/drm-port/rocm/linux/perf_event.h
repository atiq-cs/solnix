/*
 * linux/perf_event.h - illumos stub for libhsakmt's perfctr.c.
 *
 * perfctr.c (the hsaKmtPmc* HW performance-counter trace path) includes
 * <linux/perf_event.h> but only for the two PERF_EVENT_IOC_ENABLE/DISABLE
 * ioctl request numbers -- it does NOT call perf_event_open() nor use
 * struct perf_event_attr (the AMD PMU counters are enabled through the trace
 * fds, not the Linux perf syscall). We supply just those two constants (Linux
 * values, base '$') so perfctr.c compiles.
 *
 * The counters themselves are HARDWARE-GATED (need a powered GPU + the
 * amdgpu PMU); on illumos the enable/disable ioctls target fds the KFD hands
 * out, so the runtime path is a hardware concern, not a compile one.
 */
#ifndef _SOLNIX_LINUX_PERF_EVENT_STUB_H_
#define _SOLNIX_LINUX_PERF_EVENT_STUB_H_

#include "solnix-ioctl-compat.h"

#define PERF_EVENT_IOC_ENABLE	_IO('$', 0)
#define PERF_EVENT_IOC_DISABLE	_IO('$', 1)
#define PERF_EVENT_IOC_RESET	_IO('$', 3)

#endif /* _SOLNIX_LINUX_PERF_EVENT_STUB_H_ */
