/*
 * drmioc_tbl.c -- the DRM ioctl numbers of OpenBSD's own uapi headers
 * (include/uapi/drm/drm.h, i915_drm.h), compiled three times with three
 * encodings, for test_drmioc.c:
 *   -DTBL_LINUX    the Linux _IOC macros solnix libdrm/Mesa are built with
 *                  (../../anv/linux-ioctl-compat.h, unmodified)
 *   -DTBL_OBSD     OpenBSD sys/ioccom.h's (13-bit size), what drm_do_ioctl
 *                  is written against
 *   -DTBL_ILLUMOS  illumos <sys/ioccom.h> (8-bit size), what the i915
 *                  module's drm_ioctls[] table is actually compiled with,
 *                  because obsd_prelude.h includes it
 * The list of names is ioc_list.h, generated from the same headers
 * (Makefile test-ioc). Every row is an M(name) under #ifdef name.
 */
#include <stdint.h>
#include <stddef.h>
#if defined(TBL_LINUX)
#define _SYS_IOCCOM_H		/* keep illumos's out */
#include "linux-ioctl-compat.h"
#define TBL(n)	tbl_linux_##n
#elif defined(TBL_OBSD)
#define _SYS_IOCCOM_H
#define IOCPARM_MASK	0x1fff
#define IOC_VOID	0x20000000UL
#define IOC_OUT		0x40000000UL
#define IOC_IN		0x80000000UL
#define IOC_INOUT	(IOC_IN|IOC_OUT)
#define _IOC(inout, group, num, len) ((inout) | (((len) & IOCPARM_MASK) << 16) | \
	((group) << 8) | (num))
#define _IO(g, n)	_IOC(IOC_VOID, (g), (n), 0)
#define _IOR(g, n, t)	_IOC(IOC_OUT, (g), (n), sizeof (t))
#define _IOW(g, n, t)	_IOC(IOC_IN, (g), (n), sizeof (t))
#define _IOWR(g, n, t)	_IOC(IOC_INOUT, (g), (n), sizeof (t))
#define TBL(n)	tbl_obsd_##n
#elif defined(TBL_ILLUMOS)
#include <sys/ioccom.h>
#define TBL(n)	tbl_illumos_##n
#else
#error "one of TBL_LINUX TBL_OBSD TBL_ILLUMOS"
#endif
#include <sys/types.h>
#include "drm.h"
#include "i915_drm.h"

#define M(x)	(uint32_t)(x),
const uint32_t TBL(cmd)[] = {
#include "ioc_list.h"
};
#undef M
#define M(x)	#x,
const char *TBL(name)[] = {
#include "ioc_list.h"
};
const size_t TBL(n) = sizeof (TBL(cmd)) / sizeof (TBL(cmd)[0]);
