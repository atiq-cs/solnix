/*
 * obsd_kern.h -- the OpenBSD kernel API (non-VM, non-bus part) on illumos.
 * Included by obsd_prelude.h after every illumos header it maps onto.
 *
 * Tags:  REAL    same semantics via an illumos primitive
 *        MAP     illumos primitive with a stated semantic difference
 *        DECL    declared here, implemented in obsd_kern.c
 *        PLANNED declared only; unresolved at link time until written
 */
#ifndef _OBSD_KERN_H
#define _OBSD_KERN_H

/* Called once from the driver's _init (obsd_kern.c). */
extern void obsd_compat_init(void);
extern void obsd_sleepq_init(void);	/* obsd_time.c */
extern void obsd_sleepq_fini(void);
extern void obsd_compat_fini(void);
extern void obsd_glue_init(void);	/* obsd_glue.c */
struct device;
extern void obsd_config_free(struct device *);

/* ---- scalar types (REAL: the same widths on both systems) ---- */
typedef uint8_t		u_int8_t;
typedef uint16_t	u_int16_t;
typedef uint32_t	u_int32_t;
typedef uint64_t	u_int64_t;
typedef long		__ptrdiff_t;	/* illumos LP64 ptrdiff_t is long */
typedef uintptr_t	__uintptr_t;
typedef uint64_t	__uint64_t;
typedef uint32_t	__uint32_t;
typedef int		__register_t;

#ifndef __BEGIN_DECLS
#define __BEGIN_DECLS
#define __END_DECLS
#endif
#ifndef __CONCAT
#define __CONCAT(x, y)	x ## y
#define __STRING(x)	#x
#endif
#define __predict_true(x)	__builtin_expect(!!(x), 1)
#define __predict_false(x)	__builtin_expect(!!(x), 0)
#define __dead		__attribute__((__noreturn__))
#define __bounded(x)
#define __pure

/* ---- errno (REAL) ---- */
#define ELAST		151		/* ESTALE, the largest illumos errno */
#define EIPSEC		74		/* OpenBSD-only; the value of EMULTIHOP */
#define EJUSTRETURN	(-2)
#ifndef TRUE
#define TRUE	1
#define FALSE	0
#endif
#ifndef SEEK_SET
#define SEEK_SET	0
#define SEEK_CUR	1
#define SEEK_END	2
#endif

/* ---- byte order (REAL) ---- */
#define LITTLE_ENDIAN	1234
#define BIG_ENDIAN	4321
#define BYTE_ORDER	LITTLE_ENDIAN
#define _BYTE_ORDER	BYTE_ORDER
#define swap16(x)	__builtin_bswap16(x)
#define swap32(x)	__builtin_bswap32(x)
#define swap64(x)	__builtin_bswap64(x)
#define htole16(x)	((uint16_t)(x))
#define htole32(x)	((uint32_t)(x))
#define htole64(x)	((uint64_t)(x))
#define letoh16(x)	((uint16_t)(x))
#define letoh32(x)	((uint32_t)(x))
#define letoh64(x)	((uint64_t)(x))
#define le16toh(x)	letoh16(x)
#define le32toh(x)	letoh32(x)
#define le64toh(x)	letoh64(x)
#define htobe16(x)	swap16(x)
#define htobe32(x)	swap32(x)
#define htobe64(x)	swap64(x)
#define betoh16(x)	swap16(x)
#define betoh32(x)	swap32(x)
#define betoh64(x)	swap64(x)
#define be16toh(x)	betoh16(x)
#define be32toh(x)	betoh32(x)
#define be64toh(x)	betoh64(x)
#define lemtoh16(p)	(*(const volatile uint16_t *)(p))
#define lemtoh32(p)	(*(const volatile uint32_t *)(p))
#define lemtoh64(p)	(*(const volatile uint64_t *)(p))
#define bemtoh16(p)	swap16(lemtoh16(p))
#define bemtoh32(p)	swap32(lemtoh32(p))
#define bemtoh64(p)	swap64(lemtoh64(p))
#define htolem16(p, v)	(*(volatile uint16_t *)(p) = (uint16_t)(v))
#define htolem32(p, v)	(*(volatile uint32_t *)(p) = (uint32_t)(v))
#define htolem64(p, v)	(*(volatile uint64_t *)(p) = (uint64_t)(v))
#define htobem16(p, v)	htolem16((p), swap16(v))
#define htobem32(p, v)	htolem32((p), swap32(v))
#define htobem64(p, v)	htolem64((p), swap64(v))

/* ---- assertions, panic, printf (REAL: illumos cmn_err.h declares
 * printf/vprintf/snprintf/vsnprintf/panic with the same arguments; the
 * snprintf family returns size_t there, int on OpenBSD) ---- */
/* CTASSERT: OpenBSD's is a declaration, so drm's BUILD_BUG_ON(x) may test an
 * expression clang folds but gcc does not treat as an integer constant
 * (i915_drv.h __platform_mask_index). A block-scope typedef of an array
 * whose size is negative when x is false keeps the check wherever x IS
 * constant and is a no-op VLA typedef where it is not. */
#undef CTASSERT
#define __OBSD_CT2(a, b)	a ## b
#define __OBSD_CT1(a, b)	__OBSD_CT2(a, b)
#define CTASSERT(x)	typedef char __OBSD_CT1(__obsd_ctassert_, __COUNTER__)[(x) ? 1 : -1] __attribute__((__unused__))
#define KASSERT(x)		ASSERT(x)
#define KDASSERT(x)		ASSERT(x)
#define KASSERTMSG(x, ...)	ASSERT(x)
#define assertwaitok()		ASSERT(!servicing_interrupt())	/* MAP */
/* panicstr: declared by illumos sys/systm.h. */
#define db_active		0
/* vprintf: illumos returns void, OpenBSD int (drm_linux.c uses the value). */
extern int obsd_vprintf(const char *, va_list);
#define vprintf(f, ap)		obsd_vprintf((f), (ap))

/* ---- small arithmetic vocabulary (REAL) ---- */
#ifndef nitems
#define nitems(_a)	(sizeof((_a)) / sizeof((_a)[0]))
#endif
#define powerof2(x)	((((x) - 1) & (x)) == 0)
#define ISSET(t, f)	((t) & (f))
#define SET(t, f)	((t) |= (f))
#define CLR(t, f)	((t) &= ~(f))
#define setbit(a, i)	((a)[(i) / NBBY] |= 1 << ((i) % NBBY))
#define clrbit(a, i)	((a)[(i) / NBBY] &= ~(1 << ((i) % NBBY)))
#define isset(a, i)	((a)[(i) / NBBY] & (1 << ((i) % NBBY)))
#define isclr(a, i)	(((a)[(i) / NBBY] & (1 << ((i) % NBBY))) == 0)
static inline int imax(int a, int b) { return (a > b ? a : b); }
static inline int imin(int a, int b) { return (a < b ? a : b); }
static inline long lmax(long a, long b) { return (a > b ? a : b); }
static inline long lmin(long a, long b) { return (a < b ? a : b); }
static inline u_long ulmax(u_long a, u_long b) { return (a > b ? a : b); }
static inline u_long ulmin(u_long a, u_long b) { return (a < b ? a : b); }
static inline int fls(int x) { return (x ? 32 - __builtin_clz((u_int)x) : 0); }
static inline int flsl(long x)
{ return (x ? 64 - __builtin_clzl((u_long)x) : 0); }
#define abs(x)	({ __typeof__(x) _obsd_a = (x); _obsd_a < 0 ? -_obsd_a : _obsd_a; })

/* ---- malloc(9) (DECL: obsd_kern.c, kmem_alloc with a size header so that
 * free(p, type, 0) works; OpenBSD callers may pass size 0). Real functions,
 * not macros: drm calls ->free(obj) through ops tables, which a
 * function-like free(p, type, sz) macro would break. The illumos kernel
 * exports no malloc/free/mallocarray, so the names are free to use. ---- */
#define M_DEVBUF	2
#define M_TEMP		127
#define M_DRM		145
#define M_WAITOK	0x0001
#define M_NOWAIT	0x0002
#define M_CANFAIL	0x0004
#define M_ZERO		0x0008
extern void *malloc(size_t, int, int);
extern void *mallocarray(size_t, size_t, int, int);
extern void free(void *, int, size_t);

/* ---- spl / IPL (MAP: no-ops. illumos excludes an interrupt handler by
 * taking the mutex the handler takes, initialised at its priority; see
 * src/wifi-port/iwx/compat/sys/iwx_kernel.h for the same argument) ---- */
#define IPL_NONE	0
#define IPL_SOFTCLOCK	1
#define IPL_SOFTNET	2
#define IPL_BIO		3
#define IPL_NET		4
#define IPL_SOFTTTY	5
#define IPL_TTY		6
#define IPL_VM		7
#define IPL_AUDIO	8
#define IPL_CLOCK	9
#define IPL_STATCLOCK	10
#define IPL_SCHED	11
#define IPL_HIGH	12
#define IPL_IPI		13
#define IPL_MPSAFE	0x100
#define IPL_WAKEUP	0x200
#define splhigh()	(0)
#define spltty()	(0)
#define splvm()		(0)
#define splbio()	(0)
#define splnet()	(0)
#define splsched()	(0)
#define splx(s)		((void)(s))
#define splassert(l)	((void)0)
#define splsoftassert(l) ((void)0)

/* ---- interrupts (REAL: illumos intr_clear/intr_restore have OpenBSD's
 * intr_disable/intr_restore semantics on the current CPU) ---- */
#define intr_disable()	intr_clear()
#define intr_enable()	intr_restore(PS_IE)
#ifndef PS_IE
#define PS_IE		0x0200
#endif

/* ---- struct mutex (REAL: OpenBSD's struct mutex IS illumos kmutex_t here.
 * A zeroed kmutex_t is a valid adaptive mutex, so the static initializer is
 * zero. MAP: every IPL maps to an adaptive MUTEX_DRIVER mutex, which is
 * correct for low-level (thread) interrupts, the only kind the DDI hands an
 * MSI or INTx GPU handler; a high-level handler would need a spin mutex) ---- */
#define MUTEX_INITIALIZER(ipl)		{ { 0 } }
#define MUTEX_INITIALIZER_FLAGS(ipl, name, flags) { { 0 } }
#define mtx_init(m, ipl)		mutex_init((m), NULL, MUTEX_DRIVER, NULL)
#define mtx_init_flags(m, ipl, name, fl) mutex_init((m), NULL, MUTEX_DRIVER, NULL)
#define mtx_enter(m)			mutex_enter(m)
#define mtx_enter_try(m)		mutex_tryenter(m)
#define mtx_leave(m)			mutex_exit(m)
#define mtx_owned(m)			mutex_owned(m)
#define MUTEX_ASSERT_LOCKED(m)		ASSERT(mutex_owned(m))
#define MUTEX_ASSERT_UNLOCKED(m)	ASSERT(!mutex_owned(m))
#define MTX_NOWITNESS			0x01
#define MTX_DUPOK			0x02

/* ---- struct rwlock (DECL: krwlock_t underneath; OpenBSD rw_enter returns
 * an error and takes RW_NOSLEEP/RW_INTR flags, illumos rw_enter does not) ---- */
struct rwlock {
	krwlock_t	rwl_lock;
	const char	*rwl_name;
};
#define RWLOCK_INITIALIZER(name)	{ { { 0 } }, (name) }
#define RW_WRITE		0x0001UL
#define RW_READ			0x0002UL
#define RW_DOWNGRADE		0x0004UL
#define RW_OPMASK		0x0007UL
#define RW_INTR			0x0010UL
#define RW_SLEEPFAIL		0x0020UL
#define RW_NOSLEEP		0x0040UL
#define RW_RECURSEFAIL		0x0080UL
#define RW_DUPOK		0x0100UL
#define RW_WRITE_OTHER		0x0100UL
#define RWL_DUPOK		0x01
#define RWL_NOWITNESS		0x02
extern void obsd_rw_init_flags(struct rwlock *, const char *, int);
extern int obsd_rw_enter(struct rwlock *, int);
extern void obsd_rw_exit(struct rwlock *);
extern int obsd_rw_status(struct rwlock *);
#define rw_init_flags(l, n, f)	obsd_rw_init_flags((l), (n), (f))
#define rw_enter_write(l)	((void)obsd_rw_enter((l), RW_WRITE))
#define rw_enter_read(l)	((void)obsd_rw_enter((l), RW_READ))
#define rw_exit_write(l)	obsd_rw_exit(l)
#define rw_exit_read(l)		obsd_rw_exit(l)
#define rw_status(l)		obsd_rw_status(l)
#define rw_assert_wrlock(l)	ASSERT(RW_WRITE_HELD(&(l)->rwl_lock))
#define rw_assert_rdlock(l)	ASSERT(RW_READ_HELD(&(l)->rwl_lock))
#define rw_assert_anylock(l)	ASSERT(RW_LOCK_HELD(&(l)->rwl_lock))
#define rw_assert_unlocked(l)	ASSERT(!RW_LOCK_HELD(&(l)->rwl_lock))

/* ---- the kernel big lock (MAP: no-op; illumos has no giant lock and the
 * drm code's own locks are what serialise it on OpenBSD MP too) ---- */
#define KERNEL_LOCK()		((void)0)
#define KERNEL_UNLOCK()		((void)0)
#define KERNEL_ASSERT_LOCKED()	((void)0)
/* SCHED_LOCK (REAL): the one lock of the sleep queue in obsd_time.c, as on
 * OpenBSD. drm_linux.c holds it around unsleep() and wakeup_proc(). */
extern kmutex_t obsd_sched_lock;
#define SCHED_LOCK()		mutex_enter(&obsd_sched_lock)
#define SCHED_UNLOCK()		mutex_exit(&obsd_sched_lock)

/* ---- processes (DECL: obsd_curproc() returns a per-kthread shadow object
 * kept in TSD; OpenBSD code reads p_p->ps_pid/ps_comm and compares owners) ---- */
struct filedesc;
struct vmspace;
struct process {
	pid_t		ps_pid;
	char		ps_comm[MAXCOMLEN + 1];
	int		ps_flags;
	int		ps_xsig;
};
struct proc {			/* struct obsd_proc, see obsd_prelude.h */
	struct process	*p_p;
	struct filedesc	*p_fd;
	struct vmspace	*p_vmspace;
	const volatile void *p_wchan;	/* sleep channel; NULL = awake */
	int		p_flag;
	char		p_stat;		/* SONPROC or SSLEEP (illumos values) */
	kthread_t	*p_thread;	/* the illumos thread it shadows */
	/* obsd_time.c sleep queue, all under obsd_sched_lock */
	TAILQ_ENTRY(proc) p_runq;
	kcondvar_t	p_cv;
	const char	*p_wmesg;
};
extern struct proc *obsd_curproc(void);
#define curproc		obsd_curproc()
#define P_SINTR		0x00000080
#define P_INSCHED	0x00000400
/* SONPROC: illumos sys/proc.h has its own (6); drm only compares p_stat
 * against it, and p_stat is never set from an illumos state. */
#define SIGPENDING(p)	(issig(JUSTLOOKING) != 0)	/* MAP: current thread only */
extern int obsd_suser(struct proc *);	/* DECL: drv_priv(CRED()) */

/* ---- per-CPU (MAP: OpenBSD's kernel is not preemptive, so a per-CPU
 * ci_inatomic is per-thread there; on illumos obsd_curcpu() returns the
 * running CPU's slot, and pagefault_disable users must also disable
 * preemption, which the linux shim's callers do via kpreempt) ---- */
struct schedstate_percpu {
	volatile int	spc_schedflags;
};
struct cpu_info {
	u_int		ci_cpuid;
	int		ci_inatomic;
	int		ci_idepth;
	u_int		ci_cflushsz;
	u_int32_t	ci_family;	/* CPUID family (ttm_module.c) */
	u_int32_t	ci_model;
	uint32_t	ci_feature_flags;
	uint32_t	ci_feature_sefflags_ebx;
	struct schedstate_percpu ci_schedstate;
};
extern struct cpu_info *obsd_curcpu(void);
#define curcpu()		obsd_curcpu()
#define cpu_number()		(CPU->cpu_seqid)
#define CPU_BUSY_CYCLE()	__asm volatile("pause" ::: "memory")
#define SPCF_SHOULDYIELD	0x0002
#define sched_pause(func)	do { } while (0)	/* MAP: illumos preempts */
extern void yield(void);	/* REAL: illumos kernel export, same signature */

/* ---- atomics (REAL: illumos sys/atomic.h) ---- */
#define atomic_setbits_int(p, m)	atomic_or_uint((volatile uint_t *)(p), (m))
#define atomic_clearbits_int(p, m)	atomic_and_uint((volatile uint_t *)(p), ~(uint_t)(m))
#define atomic_inc_int(p)		atomic_inc_uint((volatile uint_t *)(p))
#define atomic_dec_int(p)		atomic_dec_uint((volatile uint_t *)(p))
#define atomic_inc_int_nv(p)		atomic_inc_uint_nv((volatile uint_t *)(p))
#define atomic_dec_int_nv(p)		atomic_dec_uint_nv((volatile uint_t *)(p))
#define atomic_inc_long(p)		atomic_inc_ulong((volatile ulong_t *)(p))
#define atomic_dec_long(p)		atomic_dec_ulong((volatile ulong_t *)(p))
#define __membar(_f)	do { __asm volatile(_f ::: "memory"); } while (0)
#define membar_sync()	__membar("mfence")
#define membar_enter_after_atomic()	__membar("")
#define membar_exit_before_atomic()	__membar("")
#define membar_datadep_consumer()	__membar("")
#define READ_ONCE(x) ({							\
	__typeof(x) __tmp = *(volatile __typeof(x) *)&(x);		\
	__tmp;								\
})
#define WRITE_ONCE(x, val) ({						\
	__typeof(x) __tmp = (val);					\
	*(volatile __typeof(x) *)&(x) = __tmp;				\
	__tmp;								\
})

/* ---- time (REAL via gethrestime/gethrtime; DECL bodies in obsd_kern.c) ---- */
#define nsecs_per_sec	1000000000ULL
extern void nanotime(struct timespec *);
extern void nanouptime(struct timespec *);
extern void getnanotime(struct timespec *);
extern void getnanouptime(struct timespec *);
extern void microtime(struct timeval *);
extern void microuptime(struct timeval *);
extern void getmicrouptime(struct timeval *);
extern time_t gettime(void);
extern time_t getuptime(void);
extern uint64_t nsecuptime(void);
extern uint64_t getnsecuptime(void);
static inline uint64_t
TIMESPEC_TO_NSEC(const struct timespec *ts)
{
	if (ts->tv_sec > (int64_t)((UINT64_MAX - ts->tv_nsec) / 1000000000ULL))
		return (UINT64_MAX);
	return (ts->tv_sec * 1000000000ULL + ts->tv_nsec);
}
static inline void
NSEC_TO_TIMESPEC(uint64_t ns, struct timespec *ts)
{
	ts->tv_sec = ns / 1000000000ULL;
	ts->tv_nsec = ns % 1000000000ULL;
}
static inline void
USEC_TO_TIMEVAL(uint64_t us, struct timeval *tv)
{
	tv->tv_sec = us / 1000000;
	tv->tv_usec = us % 1000000;
}
#define SEC_TO_NSEC(s)		((uint64_t)(s) * 1000000000ULL)
#define MSEC_TO_NSEC(m)		((uint64_t)(m) * 1000000ULL)
#define USEC_TO_NSEC(u)		((uint64_t)(u) * 1000ULL)
#define timespecadd(tsp, usp, vsp) do {					\
	(vsp)->tv_sec = (tsp)->tv_sec + (usp)->tv_sec;			\
	(vsp)->tv_nsec = (tsp)->tv_nsec + (usp)->tv_nsec;		\
	if ((vsp)->tv_nsec >= 1000000000L) {				\
		(vsp)->tv_sec++;					\
		(vsp)->tv_nsec -= 1000000000L;				\
	}								\
} while (0)
#define timespecsub(tsp, usp, vsp) do {					\
	(vsp)->tv_sec = (tsp)->tv_sec - (usp)->tv_sec;			\
	(vsp)->tv_nsec = (tsp)->tv_nsec - (usp)->tv_nsec;		\
	if ((vsp)->tv_nsec < 0) {					\
		(vsp)->tv_sec--;					\
		(vsp)->tv_nsec += 1000000000L;				\
	}								\
} while (0)
#define timespecisset(tsp)	((tsp)->tv_sec || (tsp)->tv_nsec)
#define timespeccmp(tsp, usp, cmp)					\
	(((tsp)->tv_sec == (usp)->tv_sec) ?				\
	    ((tsp)->tv_nsec cmp (usp)->tv_nsec) :			\
	    ((tsp)->tv_sec cmp (usp)->tv_sec))
/* OpenBSD tick = microseconds per hardclock tick; ticks = tick counter. */
#define tick		usec_per_tick
#define ticks		((int)ddi_get_lbolt())
/* jiffies (REAL): linux/jiffies.h declares "extern volatile unsigned long
 * jiffies", an OpenBSD kernel variable that hardclock() increments hz times
 * a second. obsd_time.c defines it and a ddi_periodic at the tick rate
 * copies illumos lbolt (the same counter at the same rate) into it. It has
 * to be a variable, not a macro over ddi_get_lbolt(): linux/processor.h
 * does jiffies++ and inline helpers use "jiffies" as a parameter name
 * (measured: a macro broke 379/391 files). */
/* OpenBSD cold is 1 until the scheduler runs; a DDI driver never attaches
 * that early (MAP, the iwx port makes the same choice). */
#define cold		0

/* ---- sleep / wakeup (DECL: a hashed table of condvars keyed on the wait
 * channel; tsleep/msleep re-check their predicate, as OpenBSD callers do) ---- */
#define PSWP		0
#define PVM		4
#define PINOD		8
#define PRIBIO		16
#define PZERO		22
#define PSOCK		24
#define PWAIT		32
#define PLOCK		36
#define PPAUSE		40
#define PUSER		50
#define PRIMASK		0x0ff
#define PCATCH		0x100
#define PNORELOCK	0x200
#define INFSLP		UINT64_MAX
#define MAXTSLP		(UINT64_MAX - 1)
extern int tsleep(const volatile void *, int, const char *, int);
extern int tsleep_nsec(const volatile void *, int, const char *, uint64_t);
extern int msleep(const volatile void *, struct mutex *, int, const char *, int);
extern int msleep_nsec(const volatile void *, struct mutex *, int,
    const char *, uint64_t);
extern int rwsleep_nsec(const volatile void *, struct rwlock *, int,
    const char *, uint64_t);
extern void wakeup_n(const volatile void *, int);
extern int nowake;		/* a wait channel nobody wakes: pure timed sleep */
extern int wakeup_proc(struct proc *);
extern void sleep_setup(const volatile void *, int, const char *);
extern int sleep_finish(uint64_t, int);
extern void unsleep(struct proc *);
#define wakeup(c)	wakeup_n((c), -1)
#define wakeup_one(c)	wakeup_n((c), 1)

/* ---- timeout(9) (DECL: illumos timeout(9F)/untimeout underneath).
 * The tag struct timeout does not collide with the illumos function
 * timeout(): C keeps tags and ordinary identifiers apart. ---- */
struct timeout {
	timeout_id_t	to_id;
	void		(*to_func)(void *);
	void		*to_arg;
	int		to_flags;
	int		to_kclock;
	int		to_time;	/* ticks at which it fires */
};
#define TIMEOUT_PROC		0x01
#define TIMEOUT_ONQUEUE		0x02
#define TIMEOUT_INITIALIZED	0x04
#define TIMEOUT_TRIGGERED	0x08
#define KCLOCK_NONE		(-1)
#define KCLOCK_UPTIME		0
#define TIMEOUT_INITIALIZER_FLAGS(fn, arg, kclock, flags) \
	{ 0, (fn), (arg), (flags) | TIMEOUT_INITIALIZED, (kclock), 0 }
#define TIMEOUT_INITIALIZER(fn, arg) \
	TIMEOUT_INITIALIZER_FLAGS(fn, arg, KCLOCK_NONE, 0)
extern void timeout_set(struct timeout *, void (*)(void *), void *);
extern void timeout_set_proc(struct timeout *, void (*)(void *), void *);
extern void timeout_set_flags(struct timeout *, void (*)(void *), void *,
    int, int);
extern int timeout_add(struct timeout *, int);
extern int timeout_add_sec(struct timeout *, int);
extern int timeout_add_msec(struct timeout *, uint64_t);
extern int timeout_add_usec(struct timeout *, uint64_t);
extern int timeout_add_nsec(struct timeout *, uint64_t);
extern int timeout_abs_ts(struct timeout *, const struct timespec *);
extern int timeout_del(struct timeout *);
extern int timeout_del_barrier(struct timeout *);
extern void timeout_barrier(struct timeout *);
#define timeout_pending(to)	((to)->to_flags & TIMEOUT_ONQUEUE)
#define timeout_initialized(to)	((to)->to_flags & TIMEOUT_INITIALIZED)
#define timeout_triggered(to)	((to)->to_flags & TIMEOUT_TRIGGERED)

/* ---- task / taskq (DECL: struct taskq is illumos taskq_t; a task carries a
 * taskq_ent_t so task_add can use taskq_dispatch_ent without allocating) ---- */
struct task {			/* struct obsd_task, see obsd_prelude.h */
	taskq_ent_t	t_ent;
	void		(*t_func)(void *);
	void		*t_arg;
	volatile u_int	t_flags;
};
#define TASK_ONQUEUE		0x1
#define TASK_BARRIER		0x2
#define TASK_INITIALIZER(_f, _a) { .t_func = (_f), .t_arg = (_a) }
#define TASKQ_MPSAFE		(1 << 0)
extern struct taskq *const systq;
extern struct taskq *const systqmp;
extern struct taskq *obsd_taskq_create(const char *, unsigned int, int,
    unsigned int);
/* taskq_destroy: the illumos export has the same signature and semantics
 * (struct taskq is taskq_t). taskq_barrier: no illumos export; DECL. */
extern void taskq_barrier(struct taskq *);
extern void taskq_del_barrier(struct taskq *, struct task *);
extern void task_set(struct task *, void (*)(void *), void *);
extern int task_add(struct taskq *, struct task *);
extern int task_del(struct taskq *, struct task *);
#define task_pending(t)		((t)->t_flags & TASK_ONQUEUE)

/* ---- kthread (DECL: thread_create) ---- */
extern int kthread_create(void (*)(void *), void *, struct proc **,
    const char *);
extern void kthread_exit(int) __attribute__((__noreturn__));

/* ---- random (REAL: random_get_pseudo_bytes) ---- */
static inline uint32_t
arc4random(void)
{
	uint32_t r;
	(void) random_get_pseudo_bytes((uint8_t *)&r, sizeof (r));
	return (r);
}
static inline void
arc4random_buf(void *buf, size_t n)
{
	(void) random_get_pseudo_bytes((uint8_t *)buf, n);
}
static inline uint32_t
arc4random_uniform(uint32_t upper)
{
	uint32_t r, min;
	if (upper < 2)
		return (0);
	min = -upper % upper;		/* reject the biased low range */
	do {
		r = arc4random();
	} while (r < min);
	return (r % upper);
}

/* ---- autoconf (types only: attach is an illumos dev_ops attach) ---- */
struct cfdriver {
	void		**cd_devs;
	char		*cd_name;
	int		cd_class;
	int		cd_mode;
	int		cd_ndevs;
};
struct cfdata {
	struct cfattach	*cf_attach;
	struct cfdriver	*cf_driver;
	int		cf_unit;
	long		*cf_loc;	/* locators, drm_drv.c reads primary */
};
struct device {
	int		dv_class;
	int		dv_unit;
	char		dv_xname[16];
	struct device	*dv_parent;
	struct cfdata	*dv_cfdata;
	int		dv_flags;
	int		dv_ref;
	void		*dv_private;	/* NOTE: illumos: the dev_info_t * */
};
typedef int (*cfmatch_t)(struct device *, void *, void *);
typedef int (*cfprint_t)(void *, const char *);
typedef int (*cfscan_t)(struct device *, void *);
struct cfattach {
	size_t		ca_devsize;
	cfmatch_t	ca_match;
	void		(*ca_attach)(struct device *, struct device *, void *);
	int		(*ca_detach)(struct device *, int);
	int		(*ca_activate)(struct device *, int);
};
#define DV_DULL		0
#define DVACT_DEACTIVATE 1
#define DVACT_QUIESCE	2
#define DVACT_SUSPEND	3
#define DVACT_RESUME	4
#define DVACT_WAKEUP	5
#define DVACT_POWERDOWN	6
#define DETACH_FORCE	0x01
#define DETACH_QUIET	0x02
#define UNCONF		1
#define QUIET		0
#define device_unit(dv)	((dv)->dv_unit)
extern struct device *config_found_sm(struct device *, void *, cfprint_t,
    cfmatch_t);
#define config_found(d, a, p)	config_found_sm((d), (a), (p), NULL)
extern int config_detach(struct device *, int);
extern int config_activate_children(struct device *, int);
extern void *device_lookup(struct cfdriver *, int);
extern void device_unref(struct device *);
extern int config_suspend(struct device *, int);
/* ACPI sleep state, read by inteldrm_activate. DECL: acpi_softc is NULL on
 * illumos (suspend/resume goes through DDI_SUSPEND/DDI_RESUME instead). */
struct acpi_fadt;
struct acpi_q;
struct acpi_softc {
	int			sc_state;
	struct acpi_fadt	*sc_fadt;
	SIMPLEQ_HEAD(, acpi_q)	sc_tables;
};
extern struct acpi_softc *acpi_softc;
#define ACPI_STATE_S0	0
#define ACPI_STATE_S3	3
#define ACPI_STATE_S4	4
/* cdevsw: drm_gem.c checks that a dev_t is a drm node by comparing its
 * cdevsw d_mmap entry with drmmmap. PLANNED: on illumos the check becomes
 * getmajor(dev) == the drm driver's major; this table is that hook. */
struct obsd_cdevsw {
	paddr_t	(*d_mmap)(dev_t, off_t, int);
};
extern struct obsd_cdevsw obsd_cdevsw[];
#define cdevsw	obsd_cdevsw
extern paddr_t drmmmap(dev_t, off_t, int);
extern void intr_barrier(void *);
extern void config_mountroot(struct device *, void (*)(struct device *));

/* ---- select / kqueue (MAP: selinfo wraps an illumos pollhead; knote is
 * declared for the dma-buf/sync_file poll paths, PLANNED) ---- */
struct knote;
struct klist {
	SLIST_HEAD(, knote)	kl_list;
	const void		*kl_ops;
	void			*kl_arg;
};
struct filterops {
	int	f_flags;
	int	(*f_attach)(struct knote *);
	void	(*f_detach)(struct knote *);
	int	(*f_event)(struct knote *, long);
	int	(*f_modify)(void *, struct knote *);
	int	(*f_process)(struct knote *, void *);
};
struct knote {
	SLIST_ENTRY(knote)	kn_selnext;
	const struct filterops	*kn_fop;
	void			*kn_hook;
	short			kn_filter;
	u_int			kn_sfflags;
	u_int			kn_fflags;
	long			kn_data;
};
struct selinfo {
	struct pollhead	si_ph;
	struct klist	si_note;
};
#define FILTEROP_ISFD	0x01
#define FILTEROP_MPSAFE	0x02
#define EVFILT_READ	(-1)
#define EVFILT_WRITE	(-2)
#define EVFILT_DEVICE	(-8)
#define NOTE_CHANGE	0x00000001
#define NOTE_SUBMIT	0x01000000
#define EV_EOF		0x8000
extern void selwakeup(struct selinfo *);
extern void selrecord(struct proc *, struct selinfo *);
extern void knote_locked(struct klist *, long);
extern void knote(struct klist *, long);
extern void klist_init_mutex(struct klist *, struct mutex *);
extern void klist_insert_locked(struct klist *, struct knote *);
extern void klist_remove_locked(struct klist *, struct knote *);
extern void klist_free(struct klist *);

/* ---- file descriptors. struct file here is OpenBSD's (the token is
 * renamed to obsd_file in obsd_prelude.h; illumos file_t stays intact).
 * drm_linux.c builds dma-buf and sync_file descriptors out of it with
 * fnew/fdinsert. Bodies PLANNED: the solnix C1c falloc + spec-vnode
 * mechanism (src/drm-port/src/drm_prime.c) is the illumos side. ---- */
/* declared before fileops: a tag first named inside a prototype would have
 * prototype scope and never match the real struct file */
struct file;
struct uio;
struct stat;
struct fileops {
	int	(*fo_read)(struct file *, struct uio *, int);
	int	(*fo_write)(struct file *, struct uio *, int);
	int	(*fo_ioctl)(struct file *, u_long, caddr_t, struct proc *);
	int	(*fo_kqfilter)(struct file *, struct knote *);
	int	(*fo_stat)(struct file *, struct stat *, struct proc *);
	int	(*fo_close)(struct file *, struct proc *);
	int	(*fo_seek)(struct file *, off_t *, int, struct proc *);
};
struct file {			/* struct obsd_file, see obsd_prelude.h */
	struct mutex		f_mtx;
	u_int			f_flag;
	u_int			f_iflags;
	int			f_type;
	u_int			f_count;
	const struct fileops	*f_ops;
	off_t			f_offset;
	void			*f_data;
	file_t			*f_illumos;	/* the illumos file it backs */
};
#define DTYPE_VNODE	1
#define DTYPE_DMABUF	8
#define DTYPE_SYNC	9
#define UF_EXCLOSE	0x01
extern int fdalloc(struct proc *, int, int *);
extern void fdremove(struct filedesc *, int);
extern void fdinsert(struct filedesc *, int, int, struct file *);
extern void fdexpand(struct proc *);
extern void fdplock(struct filedesc *);
extern void fdpunlock(struct filedesc *);
extern struct file *fd_getfile(struct filedesc *, int);
extern struct file *fnew(struct proc *);
#define FREF(fp)	atomic_inc_uint(&(fp)->f_count)
extern int obsd_frele(struct file *, struct proc *);
#define FRELE(fp, p)	obsd_frele((fp), (p))

/* ---- sysctl / misc ---- */
extern char osrelease[];
extern int hw_ver_unused;
extern char *hw_vendor, *hw_prod, *hw_ver;
extern int cpuspeed;
/* clone devices: drm_drv.c splits minor(dev) into unit and clone index.
 * On illumos the per-open minor comes from i915_illumos.c's open(9E),
 * which allocates the clone index and returns the new dev_t (the minor
 * layout is i915_drmioc.h's). */
#define CLONE_SHIFT	8
#define CLONE_MAPSZ	128
#define IO_NDELAY	0x10
/* uiomove: OpenBSD takes (buf, n, uio) and reads the direction from the
 * uio; illumos uio_t carries no direction and takes (buf, n, rw, uio). The
 * only caller (drm_drv.c drmread, event delivery) copies OUT to the user,
 * which is UIO_READ. MAP: a future caller that copies in must not use this. */
#define uiomove(b, n, uio)	uiomove((b), (n), UIO_READ, (uio))
#define IOCPARM_LEN(x)	(((x) >> 16) & IOCPARM_MASK)
/*
 * minor()/major(): OpenBSD's minor() keeps the clone index above
 * CLONE_SHIFT, and drm_drv.c uses the whole value as the per-open
 * drm_file key (fminor = minor(kdev)). illumos's _KERNEL minor() is the
 * SVR3 one, x & O_MAXMIN (0xff): it cuts the clone index, so every open of
 * one node would share a key. The OpenBSD code gets the full illumos
 * minor instead.
 */
#undef minor
#undef major
#define minor(x)	((int)getminor(x))
#define major(x)	((int)getmajor(x))

/* ---- firmware (DECL: firmware(9F), as the C3 amdgpu port does) ---- */
extern int loadfirmware(const char *, u_char **, size_t *);

/* ---- FPU for i915_memcpy (DECL: kernel_fpu_begin/end) ---- */
extern void fpu_kernel_enter(void);
extern void fpu_kernel_exit(void);

/* ---- extent(9), used by the aperture allocator (PLANNED) ---- */
struct extent;
#define EX_NOWAIT	0x0000
#define EX_WAITOK	0x0001
#define EX_MALLOCOK	0x0002
#define EX_CONFLICTOK	0x0080
extern int extent_alloc_subregion(struct extent *, u_long, u_long, u_long,
    u_long, u_long, u_long, int, u_long *);
extern int extent_alloc(struct extent *, u_long, u_long, u_long, u_long,
    int, u_long *);
extern int extent_free(struct extent *, u_long, u_long, int);

/* ---- pool(9) (DECL: kmem_cache underneath) ---- */
struct pool {
	kmem_cache_t	*pr_cache;
	size_t		pr_size;
	const char	*pr_wchan;
};
#define PR_WAITOK	0x0001
#define PR_NOWAIT	0x0002
#define PR_LIMITFAIL	0x0004
#define PR_ZERO		0x0008
extern void pool_init(struct pool *, size_t, u_int, int, int, const char *,
    void *);
extern void pool_destroy(struct pool *);
extern void *pool_get(struct pool *, int);
extern void pool_put(struct pool *, void *);
extern void pool_setipl(struct pool *, int);

#endif /* _OBSD_KERN_H */
