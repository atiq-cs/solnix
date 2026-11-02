/*
 * kshim.h: the NetBSD kernel KPI the netbt HCI core uses, for a userland
 * build on illumos (solnix, new code). Force-included (-include) before each
 * vendored upstream/netbt C file, with compat/kern ahead of the system headers so
 * NetBSD-only <sys/...> names resolve to empty shadows.
 *
 * The system headers are pulled in here, BEFORE _KERNEL is defined, so that
 * illumos userland headers are what the core sees. Then _KERNEL is defined for
 * netbt's own headers (hci.h, bluetooth.h: the kernel half of each).
 *
 * Model: one thread. bt_lock and hci_devlock are "held" flags that abort on
 * misuse; cv_timedwait_sig runs the event pump (kshim.c). See STATUS.md.
 */
#ifndef _SOLNIX_NETBT_KSHIM_H
#define	_SOLNIX_NETBT_KSHIM_H

#include <sys/types.h>
#include <sys/param.h>
#include <sys/time.h>
#include <sys/queue.h>
#include <sys/socket.h>
#include <sys/ioccom.h>
#include <sys/ccompile.h>
#include <sys/ioctl.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <endian.h>
#include <unistd.h>	/* every system header before _KERNEL: see above */

#include "mbuf.h"

/*
 * illumos <sys/queue.h> (gate ac45d71fc2) SIMPLEQ_REMOVE_AFTER passes ONE
 * argument to SIMPLEQ_NEXT, so any SIMPLEQ_REMOVE of a non-head element fails
 * to compile (hci_detach_pcb uses it). The NetBSD/OpenBSD definition:
 */
#undef	SIMPLEQ_REMOVE_AFTER
#define	SIMPLEQ_REMOVE_AFTER(head, elm, field) do {			\
	if ((SIMPLEQ_NEXT((elm), field) =				\
	    SIMPLEQ_NEXT(SIMPLEQ_NEXT((elm), field), field)) == NULL)	\
		(head)->sqh_last = &SIMPLEQ_NEXT((elm), field);		\
} while (0)

#ifndef _KERNEL
#define	_KERNEL		/* for netbt's own headers only (see above) */
#endif

#define	__KERNEL_RCSID(n, s)
#define	__arraycount(a)	(sizeof (a) / sizeof ((a)[0]))
#ifndef MIN
#define	MIN(a, b)	((a) < (b) ? (a) : (b))
#endif

#ifndef AF_BLUETOOTH
#define	AF_BLUETOOTH	33	/* bluetooth-phase1-plan.md 2.5; not yet in the gate */
#endif
#define	EPASSTHROUGH	(-4)	/* NetBSD: "not mine", never returned to a caller */

/* ---- devices: a unit is named by a string ("ubt0") ---- */
struct kshim_device {
	char	xname[16];
	void	*priv;		/* the transport's softc */
};
typedef struct kshim_device *device_t;
#define	device_xname(d)		((const char *)(d)->xname)
#define	device_private(d)	((d)->priv)
#define	config_found(d, a, p, c)	((device_t)NULL)	/* no bthub(4) */
#define	config_detach(d, f)		((void)(d))
#define	DETACH_FORCE		0
#define	CFARGS(...)		0

/* ---- printing ---- */
void kshim_aprint_error_dev(device_t, const char *, ...)
    __attribute__((format(printf, 2, 3)));
#define	aprint_error_dev	kshim_aprint_error_dev
#define	uprintf			printf

/* ---- assertions: always on; a failed one is a core bug, not a protocol event ---- */
void kshim_panic(const char *, int, const char *) __attribute__((noreturn));
#define	KASSERT(e)	((e) ? (void)0 : kshim_panic(__FILE__, __LINE__, #e))

/* ---- memory: NetBSD free() has no size; malloc(3) is fine in userland ---- */
#define	M_BLUETOOTH	0
#define	M_WAITOK	0x0
#define	M_NOWAIT	0x1
#define	M_ZERO		0x100
#define	MALLOC_DEFINE(t, s, l)		const int kshim_malloc_type_##t = 0
#define	MALLOC_DECLARE(t)		extern const int kshim_malloc_type_##t
void *kshim_malloc(size_t, int);
#define	malloc(sz, type, flags)	kshim_malloc((sz), (flags))
#define	free(p, type)		free(p)

/* pool(9): only reached through L2CAP PDUs (no links in phase 1) */
struct pool { size_t size; };
#define	PR_NOWAIT	M_NOWAIT
void *kshim_pool_get(struct pool *, int);
void kshim_pool_put(struct pool *, void *);
#define	pool_get	kshim_pool_get
#define	pool_put	kshim_pool_put

#endif	/* _SOLNIX_NETBT_KSHIM_H (continued in kshim2.h) */
#include "kshim2.h"
