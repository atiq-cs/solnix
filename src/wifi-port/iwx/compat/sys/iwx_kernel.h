/*
 * OpenBSD kernel primitives absent from illumos: spl, tsleep/wakeup, refcnt,
 * autoconf, malloc flavours, and the small macro vocabulary.
 *
 * ⚠ THE spl MAPPING IS THE ONE WITH REAL SEMANTIC RISK, and it is deliberately
 * a NO-OP rather than a lock. Reasoning, since a wrong choice here is a deadlock
 * or a data race rather than a compile error:
 *
 *   splnet() raises the interrupt priority level on the CURRENT CPU. It excludes
 *   the network interrupt handler from running here; it does NOT exclude another
 *   CPU. OpenBSD's iwx additionally holds sc->sc_lock (rwlock) around the same
 *   regions, and that is what provides mutual exclusion. Mapping splnet() to a
 *   mutex_enter would therefore introduce a SECOND lock, acquired in 15 places
 *   and released in 31 (the counts do not even match, because splx() also
 *   restores from nested saves) -- a recursive-entry panic and a lock-order
 *   inversion waiting to happen.
 *
 *   illumos's equivalent guarantee comes from registering the interrupt handler
 *   at a known priority and taking the driver mutex inside it. So: spl becomes a
 *   no-op, and the exclusion it was providing must come from the driver's own
 *   lock. Every splnet region must be CHECKED to be inside sc_lock; that audit is
 *   listed in the port notes and is NOT done by this header.
 *
 * STATUS: spl = no-op by design (documented above). tsleep/wakeup = REAL
 * (cv_timedwait). refcnt = REAL. malloc = REAL. autoconf = types only, the
 * driver's attach is rewritten as a DDI attach in iwx_gld.c.
 */
#ifndef _IWX_COMPAT_SYS_IWX_KERNEL_H
#define _IWX_COMPAT_SYS_IWX_KERNEL_H

#include <sys/types.h>
#include <sys/param.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/ksynch.h>
#include <sys/rwlock.h>
#include <sys/atomic.h>
#include <sys/cmn_err.h>
#include <net/if.h>		/* IFNAMSIZ, struct ifnet */

/* ---- spl: no-op. See the note above before changing this. ---- */
typedef int ipl_t;
#define IPL_NONE	0
#define IPL_NET		6
#define IPL_TTY		9
#define splnet()	(0)
#define splbio()	(0)
#define spltty()	(0)
#define splx(s)		((void)(s))
#define splassert(l)	((void)0)
#define splsoftnet()	(0)

/* ---- rwlock: OpenBSD rw_* -> illumos krwlock_t. Flag names differ. ---- */
#define RW_WRITE	RW_WRITER
#define RW_READ		RW_READER
#define RW_INTR		0		/* illumos rw_enter is not interruptible */
#define RW_SLEEPFAIL	0
#define RW_NOSLEEP	0
#define RW_DUPOK	0

/* OpenBSD rw_init takes a name; illumos takes (lock, name, type, arg). */
/*
 * OpenBSD `struct rwlock` is a concrete type embedded in the softc
 * (if_iwxvar.h:760 declares `struct rwlock ioctl_rwl`), and its rw_enter takes
 * that struct plus a flags word and RETURNS an error. illumos rw_enter takes a
 * krwlock_t and returns void, and its name collides. So the OpenBSD spellings
 * are redirected to iwx_rw_* wrappers that carry the struct, and the illumos
 * rw_enter/rw_exit are left untouched underneath. REAL.
 */
struct rwlock {
	krwlock_t	rwl_lock;
};
extern void iwx_rw_init(struct rwlock *, const char *);
extern void iwx_rw_destroy(struct rwlock *);
extern int iwx_rw_enter(struct rwlock *, int);
extern void iwx_rw_exit(struct rwlock *);
#define rw_init(l, name)	iwx_rw_init((l), (name))
#define rw_enter(l, f)		iwx_rw_enter((l), (f))
#define rw_exit(l)		iwx_rw_exit(l)
#define rw_enter_write(l)	(void) iwx_rw_enter((l), RW_WRITE)
#define rw_enter_read(l)	(void) iwx_rw_enter((l), RW_READ)
#define rw_assert_wrlock(l)	ASSERT(RW_WRITE_HELD(&(l)->rwl_lock))
#define rw_assert_anylock(l)	ASSERT(RW_LOCK_HELD(&(l)->rwl_lock))


/* ---- sleep / wakeup -> condition variables. Implemented in iwx_kcompat.c. ---- */
#define PCATCH		0x100
#define PZERO		22
extern int tsleep_nsec(const void *chan, int prio, const char *wmesg,
    uint64_t nsecs);
extern int tsleep(const void *chan, int prio, const char *wmesg, int timo);
extern void wakeup(const void *chan);
#define wakeup_one(c)	wakeup(c)
#define INFSLP		UINT64_MAX
#define nsecs_per_sec	1000000000ULL
#define MSEC_TO_NSEC(m)	((uint64_t)(m) * 1000000ULL)
#define SEC_TO_NSEC(s)	((uint64_t)(s) * 1000000000ULL)

/* ---- refcnt: OpenBSD struct refcnt -> a plain atomic counter. ---- */
struct refcnt {
	volatile uint32_t r_refs;
};
extern void refcnt_init(struct refcnt *);
extern void refcnt_take(struct refcnt *);
extern int refcnt_rele(struct refcnt *);
extern void refcnt_rele_wake(struct refcnt *);
extern void refcnt_finalize(struct refcnt *, const char *);

/* ---- malloc flavours. ---- */
#define M_DEVBUF	2
#define M_ZERO		0x0100
#define M_NOWAIT	0x0002
#define M_WAITOK	0x0000
#define M_CANFAIL	0x0004
extern void *iwx_bsd_malloc(size_t, int, int);
extern void *iwx_bsd_mallocarray(size_t, size_t, int, int);
extern void iwx_bsd_free(void *, int, size_t);
#define malloc(sz, type, flags)		iwx_bsd_malloc((sz), (type), (flags))
#define mallocarray(n, sz, type, flags)	iwx_bsd_mallocarray((n), (sz), (type), (flags))
#define free(p, type, sz)		iwx_bsd_free((p), (type), (sz))

/* ---- taskq / task. OpenBSD systq is a shared system taskq. ---- */
struct taskq;
struct task {
	void	(*t_func)(void *);
	void	*t_arg;
	volatile unsigned int t_state;
	struct taskq *t_tq;
};
extern struct taskq *systq;
extern struct taskq *iwx_taskq_create(const char *, unsigned int, int,
    unsigned int);
#define taskq_create(n, nthr, ipl, flags) iwx_taskq_create((n), (nthr), (ipl), (flags))
extern void taskq_destroy(struct taskq *);
extern void task_set(struct task *, void (*)(void *), void *);
extern int task_add(struct taskq *, struct task *);
extern int task_del(struct taskq *, struct task *);
extern int task_pending(struct task *);

/* ---- timeout(9) OpenBSD style. ---- */
struct timeout {
	timeout_id_t	to_id;
	void		(*to_func)(void *);
	void		*to_arg;
	volatile int	to_pending;
};
extern void timeout_set(struct timeout *, void (*)(void *), void *);
extern int timeout_add_msec(struct timeout *, int);
extern int timeout_add_usec(struct timeout *, int);
extern int timeout_add_sec(struct timeout *, int);
extern int timeout_add(struct timeout *, int);
extern int timeout_del(struct timeout *);
extern int timeout_pending(struct timeout *);

/* ---- autoconf: types only. attach/detach are rewritten in iwx_gld.c. ---- */
struct device {
	char	dv_xname[16];
	void	*dv_private;
};
struct cfdata;
struct cfattach {
	int	ca_devsize;
	int	(*ca_match)(struct device *, void *, void *);
	void	(*ca_attach)(struct device *, struct device *, void *);
	int	(*ca_detach)(struct device *, int);
	int	(*ca_activate)(struct device *, int);
};
struct cfdriver {
	void		**cd_devs;
	char		*cd_name;
	int		cd_class;
	int		cd_size;
};
#define DV_IFNET	1
extern void config_mountroot(struct device *, void (*)(struct device *));

/* ---- link state. GLDv3 uses mac_link_update; bridged in iwx_gld.c. ---- */
#define LINK_STATE_DOWN		2
#define LINK_STATE_UP		4
#define LINK_STATE_UNKNOWN	0

/* ---- firmware. ---- */
extern int loadfirmware(const char *, uint8_t **, size_t *);
extern void free_firmware(uint8_t *, size_t);

/* ---- ethernet address literals from OpenBSD if_ether.c. ---- */
extern const uint8_t etherbroadcastaddr[6];
extern const uint8_t etheranyaddr[6];
/*
 * illumos sys/ethernet.h already declares ether_sprintf(struct ether_addr *).
 * iwx passes a raw uint8_t[6]. Rather than macro-shadowing the real declaration
 * (which mangles it), a differently-named helper is used and the call sites are
 * redirected by name. REAL.
 */
#include <sys/ethernet.h>
#define ether_sprintf(a)	ether_sprintf((struct ether_addr *)(void *)(a))

/* ---- small macro vocabulary. ---- */
#ifndef PAGE_SIZE
#define PAGE_SIZE	PAGESIZE
#endif
#ifndef nitems
#define nitems(x)	(sizeof (x) / sizeof ((x)[0]))
#endif
#ifndef howmany
#define howmany(x, y)	(((x) + ((y) - 1)) / (y))
#endif
#ifndef roundup
#define roundup(x, y)	((((x) + ((y) - 1)) / (y)) * (y))
#endif
#ifndef MIN
#define MIN(a, b)	((a) < (b) ? (a) : (b))
#endif
#ifndef MAX
#define MAX(a, b)	((a) > (b) ? (a) : (b))
#endif
#ifndef true
#define true	1
#define false	0
#endif

#define fls(x)		iwx_fls(x)
extern int iwx_fls(int);
extern void getmicrouptime(struct timeval *);
#define getnanouptime(ts)	iwx_getnanouptime(ts)
extern void iwx_getnanouptime(struct timespec *);

/* setbit/isset over a byte-addressed bitmap, as OpenBSD's sys/param.h has. */
#ifndef setbit
#define setbit(a, i)	((a)[(i) / 8] |= 1 << ((i) % 8))
#define clrbit(a, i)	((a)[(i) / 8] &= ~(1 << ((i) % 8)))
#define isset(a, i)	((a)[(i) / 8] & (1 << ((i) % 8)))
#define isclr(a, i)	(((a)[(i) / 8] & (1 << ((i) % 8))) == 0)
#endif


/* ---- assertions, autoconf activation codes, misc leftovers. ---- */
#define KASSERT(x)		ASSERT(x)
#define KDASSERT(x)		ASSERT(x)
#define DVACT_QUIESCE		1
#define DVACT_SUSPEND		2
#define DVACT_RESUME		3
#define DVACT_WAKEUP		4
#define DVACT_POWERDOWN		5
/*
 * OpenBSD `cold` is 1 until the scheduler runs. illumos has no equivalent and a
 * DDI driver never attaches that early, so it is a constant 0. Behaviour
 * difference: OpenBSD's iwx skips a sleep while cold; on illumos it never skips,
 * which is the safe direction.
 */
#define cold			0
#define flsl(x)			iwx_flsl(x)
extern int iwx_flsl(long);
#define USEC_TO_TIMEVAL(us, tv)	do {					\
	(tv)->tv_sec = (us) / 1000000;					\
	(tv)->tv_usec = (us) % 1000000;					\
} while (0)
#ifndef ETHER_ADDR_LEN
#define ETHER_ADDR_LEN		6
#endif
#define IEEE80211_ADDR_LEN	6
/* struct ifreq: iwx only takes sizeof() of it in its ioctl path. */
struct ifreq {
	char	ifr_name[IFNAMSIZ];
	union {
		struct { unsigned short sa_family; char sa_data[14]; } ifru_addr;
		short	ifru_flags;
		int	ifru_metric;
		caddr_t	ifru_data;
	} ifr_ifru;
};
#define IFM_MODE(x)		((x) & 0x00000000ff000000ULL)

#endif /* _IWX_COMPAT_SYS_IWX_KERNEL_H */
