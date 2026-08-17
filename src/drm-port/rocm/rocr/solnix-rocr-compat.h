/*
 * solnix-rocr-compat.h -- force-included shim for building ROCR-Runtime
 * (libhsa-runtime64) on illumos x86_64.
 *
 * ROCr's Linux backend (core/util/lnx/os_linux.cpp) assumes a few glibc/Linux
 * spellings that illumos names differently. This header (compiled in with
 * -include) supplies the missing spellings so the .cpp stays byte-identical to
 * upstream except for the two substantive edits documented in ROCM-STATUS.md.
 *
 * Everything here is a portability spelling, not a behavior change: the clock
 * maps to illumos's high-resolution monotonic clock; the rest are typedefs the
 * compiler otherwise rejects.
 */
#ifndef SOLNIX_ROCR_COMPAT_H
#define SOLNIX_ROCR_COMPAT_H

#ifdef __sun

/*
 * alloca(3) lives in <alloca.h> on illumos (glibc drags it in via <stdlib.h>).
 * Several ROCr sources call alloca without including it (they rely on the
 * glibc convenience). Pull it in unconditionally -- same fix libhsakmt used.
 */
#include <alloca.h>

/*
 * <linux/limits.h> is the Linux spelling of the PATH_MAX/NAME_MAX header;
 * illumos ships those in <limits.h>. amd_hsa_loader.cpp includes the Linux
 * path. The stub header (rocr/linux/limits.h on the include path) just pulls
 * in <limits.h>; nothing else in that Linux header is used.
 */

/*
 * CLOCK_MONOTONIC_RAW is Linux-only (a monotonic clock unaffected by NTP slew).
 * illumos's CLOCK_HIGHRES is the equivalent high-resolution monotonic clock
 * (gethrtime backend). ReadAccurateClock/AccurateClockFrequency only need a
 * monotonic, high-resolution source; CLOCK_HIGHRES satisfies both.
 */
#ifndef CLOCK_MONOTONIC_RAW
#include <time.h>
#ifdef CLOCK_HIGHRES
#define CLOCK_MONOTONIC_RAW CLOCK_HIGHRES
#else
#define CLOCK_MONOTONIC_RAW CLOCK_MONOTONIC
#endif
#endif

#endif /* __sun */
#endif /* SOLNIX_ROCR_COMPAT_H */
