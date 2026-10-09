/*
 * obsd_kern.c -- bodies for the DECL entries of obsd_kern.h / obsd_vm.h /
 * obsd_bus.h: the OpenBSD kernel primitives the drm core and i915 call,
 * implemented on the illumos DDI.
 *
 * Built as a kernel ET_REL object against the gate proto (obsd-compat
 * Makefile). Not loaded anywhere yet. Every entry here is REAL or MAP (see
 * the tag in the header); anything still PLANNED is left as an undefined
 * symbol so a link fails by name instead of returning a fake success.
 */
#include <sys/types.h>
#include <sys/x86_archext.h>
#include <sys/firmload.h>
#include <sys/callo.h>		/* CALLOUT_FLAG_ABSOLUTE */
#include <obsd_prelude.h>
/* This file implements the OpenBSD names ON the illumos ones, so the
 * prelude's call-site redirections must not apply inside it. */
#undef rw_init
#undef rw_enter
#undef rw_exit
#undef rw_destroy
#undef vprintf
#undef taskq_create
#undef delay
#undef uiomove

/* ---------------------------------------------------------------- malloc */
/*
 * OpenBSD free(p, type, size) may pass size 0. kmem_free needs the size, so
 * every allocation carries a 16-byte header holding it (16 keeps the
 * returned pointer 16-aligned, as kmem_alloc's is).
 */
#define OBSD_MHDR	16

void *
malloc(size_t size, int type, int flags)
{
	size_t total;
	uint8_t *p;
	int km = (flags & M_NOWAIT) ? KM_NOSLEEP : KM_SLEEP;

	(void) type;
	if (size > SIZE_MAX - OBSD_MHDR)
		return (NULL);
	total = size + OBSD_MHDR;
	p = (flags & M_ZERO) ? kmem_zalloc(total, km) : kmem_alloc(total, km);
	if (p == NULL)
		return (NULL);
	*(size_t *)p = total;
	return (p + OBSD_MHDR);
}

void *
mallocarray(size_t n, size_t size, int type, int flags)
{
	if (size != 0 && n > SIZE_MAX / size) {
		if (flags & M_CANFAIL)
			return (NULL);
		panic("mallocarray: overflow %lu * %lu", (ulong_t)n,
		    (ulong_t)size);
	}
	return (malloc(n * size, type, flags));
}

void
free(void *addr, int type, size_t size)
{
	uint8_t *p;

	(void) type;
	(void) size;
	if (addr == NULL)
		return;
	p = (uint8_t *)addr - OBSD_MHDR;
	kmem_free(p, *(size_t *)p);
}

/* ---------------------------------------------------------------- rwlock */
void
obsd_rw_init_flags(struct rwlock *rwl, const char *name, int flags)
{
	(void) flags;
	rw_init(&rwl->rwl_lock, NULL, RW_DRIVER, NULL);
	rwl->rwl_name = name;
}

/*
 * OpenBSD rw_enter returns 0, EBUSY (RW_NOSLEEP and contended) or EINTR
 * (RW_INTR and a signal). illumos rw_enter cannot be interrupted, so
 * RW_INTR waits uninterruptibly (MAP: a signal delays rather than aborts
 * the caller; i915 retries on -EINTR anyway).
 */
int
obsd_rw_enter(struct rwlock *rwl, int flags)
{
	krw_t how = ((flags & RW_OPMASK) == RW_READ) ? RW_READER : RW_WRITER;

	if (flags & RW_NOSLEEP)
		return (rw_tryenter(&rwl->rwl_lock, how) ? 0 : EBUSY);
	rw_enter(&rwl->rwl_lock, how);
	return (0);
}

void
obsd_rw_exit(struct rwlock *rwl)
{
	rw_exit(&rwl->rwl_lock);
}

/* RW_WRITE if held for writing by the caller, RW_WRITE_OTHER if by
 * another thread, RW_READ if read-held, 0 if free. */
int
obsd_rw_status(struct rwlock *rwl)
{
	if (rw_write_held(&rwl->rwl_lock))
		return (rw_owner(&rwl->rwl_lock) == curthread ?
		    RW_WRITE : RW_WRITE_OTHER);
	if (rw_read_held(&rwl->rwl_lock))
		return (RW_READ);
	return (0);
}

/* sleep/wakeup: obsd_time.c */

/* ------------------------------------------------------------------ time */
void
nanotime(struct timespec *ts)
{
	gethrestime((timespec_t *)ts);
}

void
getnanotime(struct timespec *ts)
{
	gethrestime((timespec_t *)ts);
}

void
nanouptime(struct timespec *ts)
{
	hrt2ts(gethrtime(), (timespec_t *)ts);
}

void
getnanouptime(struct timespec *ts)
{
	hrt2ts(gethrtime(), (timespec_t *)ts);
}

void
microtime(struct timeval *tv)
{
	timespec_t ts;

	gethrestime(&ts);
	tv->tv_sec = ts.tv_sec;
	tv->tv_usec = ts.tv_nsec / 1000;
}

void
microuptime(struct timeval *tv)
{
	hrtime_t t = gethrtime();

	tv->tv_sec = t / NANOSEC;
	tv->tv_usec = (t % NANOSEC) / 1000;
}

void
getmicrouptime(struct timeval *tv)
{
	microuptime(tv);
}

time_t
gettime(void)
{
	return (gethrestime_sec());
}

time_t
getuptime(void)
{
	return (gethrtime() / NANOSEC);
}

uint64_t
nsecuptime(void)
{
	return ((uint64_t)gethrtime());
}

uint64_t
getnsecuptime(void)
{
	return ((uint64_t)gethrtime());
}

/* --------------------------------------------------------------- timeout */
/*
 * OpenBSD timeouts are re-armable objects; illumos timeout(9F) returns a
 * one-shot id. to_id holds the live id. timeout_del untimeout()s it, which
 * waits for a running handler, so timeout_del is also timeout_del_barrier
 * (MAP: OpenBSD's plain timeout_del does not wait; waiting is the safe
 * direction, but a caller must not hold a lock its handler takes).
 */
static void
obsd_timeout_fire(void *arg)
{
	struct timeout *to = arg;

	atomic_and_uint((volatile uint_t *)&to->to_flags, ~TIMEOUT_ONQUEUE);
	atomic_or_uint((volatile uint_t *)&to->to_flags, TIMEOUT_TRIGGERED);
	to->to_func(to->to_arg);
}

void
timeout_set(struct timeout *to, void (*fn)(void *), void *arg)
{
	timeout_set_flags(to, fn, arg, KCLOCK_NONE, 0);
}

void
timeout_set_proc(struct timeout *to, void (*fn)(void *), void *arg)
{
	timeout_set_flags(to, fn, arg, KCLOCK_NONE, TIMEOUT_PROC);
}

void
timeout_set_flags(struct timeout *to, void (*fn)(void *), void *arg,
    int kclock, int flags)
{
	to->to_id = 0;
	to->to_func = fn;
	to->to_arg = arg;
	to->to_kclock = kclock;
	to->to_flags = flags | TIMEOUT_INITIALIZED;
	to->to_time = 0;
}

/* Arm (or re-arm) to fire after nsecs. Returns 1 if newly queued, 0 if it
 * was already queued (OpenBSD semantics: re-arming moves the deadline). */
static int
obsd_timeout_arm(struct timeout *to, uint64_t nsecs)
{
	int was = (to->to_flags & TIMEOUT_ONQUEUE) != 0;
	clock_t t;

	if (was)
		(void) untimeout(to->to_id);
	t = (clock_t)(nsecs / (uint64_t)nsec_per_tick);
	if (t < 1)
		t = 1;
	to->to_time = (int)(ddi_get_lbolt() + t);
	atomic_and_uint((volatile uint_t *)&to->to_flags, ~TIMEOUT_TRIGGERED);
	atomic_or_uint((volatile uint_t *)&to->to_flags, TIMEOUT_ONQUEUE);
	to->to_id = timeout(obsd_timeout_fire, to, t);
	return (!was);
}

int
timeout_add(struct timeout *to, int ticks_)
{
	return (obsd_timeout_arm(to,
	    (uint64_t)MAX(ticks_, 0) * (uint64_t)nsec_per_tick));
}

int
timeout_add_sec(struct timeout *to, int s)
{
	return (obsd_timeout_arm(to, SEC_TO_NSEC(MAX(s, 0))));
}

int
timeout_add_msec(struct timeout *to, uint64_t ms)
{
	return (obsd_timeout_arm(to, MSEC_TO_NSEC(ms)));
}

int
timeout_add_usec(struct timeout *to, uint64_t us)
{
	return (obsd_timeout_arm(to, USEC_TO_NSEC(us)));
}

int
timeout_add_nsec(struct timeout *to, uint64_t ns)
{
	return (obsd_timeout_arm(to, ns));
}

int
timeout_abs_ts(struct timeout *to, const struct timespec *abs)
{
	struct timespec now;
	uint64_t a, n;

	nanouptime(&now);
	a = TIMESPEC_TO_NSEC(abs);
	n = TIMESPEC_TO_NSEC(&now);
	return (obsd_timeout_arm(to, a > n ? a - n : 0));
}

int
timeout_del(struct timeout *to)
{
	if (!(to->to_flags & TIMEOUT_ONQUEUE))
		return (0);
	(void) untimeout(to->to_id);
	atomic_and_uint((volatile uint_t *)&to->to_flags, ~TIMEOUT_ONQUEUE);
	return (1);
}

int
timeout_del_barrier(struct timeout *to)
{
	return (timeout_del(to));
}

void
timeout_barrier(struct timeout *to)
{
	(void) to;		/* untimeout already waited for the handler */
}

/* ------------------------------------------------------------------ task */
/*
 * A task embeds a taskq_ent_t, so task_add uses taskq_dispatch_ent (no
 * allocation, cannot fail) and a task is queued at most once, as on
 * OpenBSD. The trampoline clears TASK_ONQUEUE before calling the function,
 * so the function may re-add itself.
 */
/* systq/systqmp are NULL handles that obsd_tq() resolves to one shared
 * taskq created in obsd_compat_init(). */
static taskq_t *obsd_systq;
struct taskq *const systq = NULL;
struct taskq *const systqmp = NULL;

static taskq_t *
obsd_tq(struct taskq *tq)
{
	if (tq != NULL)
		return ((taskq_t *)tq);
	return (obsd_systq);
}

static void
obsd_task_run(void *arg)
{
	struct task *t = arg;

	atomic_and_uint(&t->t_flags, ~TASK_ONQUEUE);
	t->t_func(t->t_arg);
}

struct taskq *
obsd_taskq_create(const char *name, unsigned int nthreads, int ipl,
    unsigned int flags)
{
	(void) ipl;
	(void) flags;
	return ((struct taskq *)taskq_create(name, (int)MAX(nthreads, 1),
	    minclsyspri, 1, 8, TASKQ_PREPOPULATE));
}

void
taskq_barrier(struct taskq *tq)
{
	taskq_wait(obsd_tq(tq));
}

void
taskq_del_barrier(struct taskq *tq, struct task *t)
{
	(void) t;
	taskq_wait(obsd_tq(tq));
}

void
task_set(struct task *t, void (*fn)(void *), void *arg)
{
	bzero(&t->t_ent, sizeof (t->t_ent));
	t->t_func = fn;
	t->t_arg = arg;
	t->t_flags = 0;
}

/* Returns 1 if queued, 0 if it was already queued (OpenBSD semantics). */
int
task_add(struct taskq *tq, struct task *t)
{
	uint_t old;

	do {
		old = t->t_flags;
		if (old & TASK_ONQUEUE)
			return (0);
	} while (atomic_cas_uint(&t->t_flags, old, old | TASK_ONQUEUE) != old);
	taskq_dispatch_ent(obsd_tq(tq), obsd_task_run, t, TQ_SLEEP,
	    &t->t_ent);
	return (1);
}

/*
 * MAP: taskq_dispatch_ent has no cancel, so a queued task cannot be
 * removed; task_del reports 0 ("was not removed") and leaves TASK_ONQUEUE
 * set until the trampoline runs. Clearing it here would let a later
 * task_add dispatch the same taskq_ent_t while it is still linked, which
 * corrupts the taskq. drm's cancel_work_sync follows task_del with a
 * barrier, so it still waits for the task to finish.
 */
int
task_del(struct taskq *tq, struct task *t)
{
	(void) tq;
	(void) t;
	return (0);
}

/* ---------------------------------------------------------- curproc/cpu */
/*
 * OpenBSD code reads curproc->p_p->ps_pid / ps_comm and compares curproc
 * pointers (lock owners, wait queues). A shadow struct proc per illumos
 * thread lives in TSD and is freed with the thread.
 */
static uint_t obsd_proc_key;

struct obsd_proc_shadow {
	struct proc	ps_proc;
	struct process	ps_process;
};

static void
obsd_proc_free(void *p)
{
	struct obsd_proc_shadow *s = p;

	cv_destroy(&s->ps_proc.p_cv);
	kmem_free(s, sizeof (*s));
}

struct proc *
obsd_curproc(void)
{
	struct obsd_proc_shadow *s = tsd_get(obsd_proc_key);
	proc_t *ip = ttoproc(curthread);

	if (s == NULL) {
		s = kmem_zalloc(sizeof (*s), KM_SLEEP);
		s->ps_proc.p_p = &s->ps_process;
		s->ps_proc.p_thread = curthread;
		s->ps_proc.p_stat = SONPROC;
		cv_init(&s->ps_proc.p_cv, NULL, CV_DRIVER, NULL);
		(void) tsd_set(obsd_proc_key, s);
	}
	s->ps_process.ps_pid = ip->p_pidp->pid_id;
	(void) strlcpy(s->ps_process.ps_comm, PTOU(ip)->u_comm,
	    sizeof (s->ps_process.ps_comm));
	return (&s->ps_proc);
}

/* One cpu_info per illumos CPU sequence id, filled at init. */
static struct cpu_info *obsd_cpus;
static int obsd_ncpus;
uint32_t cpu_ecxfeature;

struct cpu_info *
obsd_curcpu(void)
{
	return (&obsd_cpus[CPU->cpu_seqid % obsd_ncpus]);
}

static void
obsd_cpu_init(void)
{
	int i;
	uint32_t ff = 0, sef = 0;

	if (is_x86_feature(x86_featureset, X86FSET_SSE4_1))
		cpu_ecxfeature |= CPUIDECX_SSE41;
	if (is_x86_feature(x86_featureset, X86FSET_PAT))
		ff |= CPUID_PAT;
	if (is_x86_feature(x86_featureset, X86FSET_CLFSH))
		ff |= CPUID_CFLUSH;
	tsd_create(&obsd_proc_key, obsd_proc_free);
	obsd_ncpus = max_ncpus;
	obsd_cpus = kmem_zalloc(sizeof (struct cpu_info) * obsd_ncpus,
	    KM_SLEEP);
	for (i = 0; i < obsd_ncpus; i++) {
		obsd_cpus[i].ci_cpuid = i;
		obsd_cpus[i].ci_feature_flags = ff;
		obsd_cpus[i].ci_feature_sefflags_ebx = sef;
		obsd_cpus[i].ci_cflushsz = (ff & CPUID_CFLUSH) ? 64 : 0;
		obsd_cpus[i].ci_family = 6;
	}
}

/* Called once from the driver's _init before any other entry point. */
void
obsd_compat_init(void)
{
	obsd_sleepq_init();
	obsd_vm_init();
	obsd_glue_init();
	obsd_cpu_init();
	obsd_systq = taskq_create("obsd_systq", 1, minclsyspri, 1, 64,
	    TASKQ_PREPOPULATE);
}

/* Called once from the driver's _fini, after every other entry point. */
void
obsd_compat_fini(void)
{
	obsd_sleepq_fini();
	if (obsd_systq != NULL)
		taskq_destroy(obsd_systq);
	obsd_systq = NULL;
}

int
obsd_suser(struct proc *p)
{
	(void) p;
	return (drv_priv(CRED()));
}

int
obsd_vprintf(const char *fmt, va_list ap)
{
	vprintf(fmt, ap);
	return (0);
}

/* ------------------------------------------------------------- firmware */
/* loadfirmware(name) -> firmware(9F) "obsd-drm/<name>". The buffer comes
 * from malloc(M_DEVBUF) because drm frees it with free(). */
int
loadfirmware(const char *name, u_char **bufp, size_t *lenp)
{
	firmware_handle_t fh;
	off_t sz;
	u_char *buf;
	int err;

	if ((err = firmware_open("drm", name, &fh)) != 0)
		return (err);
	sz = firmware_get_size(fh);
	if (sz <= 0 || (buf = malloc(sz, M_DEVBUF, M_NOWAIT)) == NULL) {
		(void) firmware_close(fh);
		return (ENOMEM);
	}
	if ((err = firmware_read(fh, 0, buf, sz)) != 0) {
		free(buf, M_DEVBUF, sz);
		(void) firmware_close(fh);
		return (err);
	}
	(void) firmware_close(fh);
	*bufp = buf;
	*lenp = sz;
	return (0);
}

/* ------------------------------------------------------------------ pool */
void
pool_init(struct pool *pp, size_t size, u_int align, int ipl, int flags,
    const char *wchan, void *palloc)
{
	(void) ipl;
	(void) flags;
	(void) palloc;
	pp->pr_size = size;
	pp->pr_wchan = wchan;
	pp->pr_cache = kmem_cache_create((char *)wchan, size,
	    align ? align : 8, NULL, NULL, NULL, NULL, NULL, 0);
}

void
pool_destroy(struct pool *pp)
{
	kmem_cache_destroy(pp->pr_cache);
}

void *
pool_get(struct pool *pp, int flags)
{
	void *p = kmem_cache_alloc(pp->pr_cache,
	    (flags & PR_NOWAIT) ? KM_NOSLEEP : KM_SLEEP);

	if (p != NULL && (flags & PR_ZERO))
		bzero(p, pp->pr_size);
	return (p);
}

void
pool_put(struct pool *pp, void *p)
{
	kmem_cache_free(pp->pr_cache, p);
}

void
pool_setipl(struct pool *pp, int ipl)
{
	(void) pp;
	(void) ipl;
}

/* km_alloc/km_free: obsd_vm.c */

/* ------------------------------------------------------------------- PCI */
/*
 * pcitag_t is bus<<16 | dev<<11 | fn<<8, as OpenBSD amd64 packs it. A read
 * of the attached device goes through its pci_config_setup handle; i915's
 * other reads (host bridge 0:0.0 for MCHBAR, the ISA bridge for the PCH id)
 * use the PCI nexus's mechanism-1 accessors that every illumos x86 kernel
 * exports. MAP: those bypass the DDI's per-device access checks, which is
 * what OpenBSD's pci_conf_read does too.
 */
extern uint32_t (*pci_getl_func)(int, int, int, int);
extern void (*pci_putl_func)(int, int, int, int, uint32_t);

pcitag_t
pci_make_tag(pci_chipset_tag_t pc, int bus, int dev, int fn)
{
	(void) pc;
	return ((pcitag_t)((bus << 16) | (dev << 11) | (fn << 8)));
}

void
pci_decompose_tag(pci_chipset_tag_t pc, pcitag_t tag, int *bp, int *dp,
    int *fp)
{
	(void) pc;
	if (bp != NULL)
		*bp = (tag >> 16) & 0xff;
	if (dp != NULL)
		*dp = (tag >> 11) & 0x1f;
	if (fp != NULL)
		*fp = (tag >> 8) & 0x7;
}

pcireg_t
pci_conf_read(pci_chipset_tag_t pc, pcitag_t tag, int reg)
{
	if (pc != NULL && pc->pc_cfg != NULL && tag == pc->pc_self)
		return (pci_config_get32(pc->pc_cfg, reg));
	return ((*pci_getl_func)((tag >> 16) & 0xff, (tag >> 11) & 0x1f,
	    (tag >> 8) & 0x7, reg));
}

void
pci_conf_write(pci_chipset_tag_t pc, pcitag_t tag, int reg, pcireg_t val)
{
	if (pc != NULL && pc->pc_cfg != NULL && tag == pc->pc_self) {
		pci_config_put32(pc->pc_cfg, reg, val);
		return;
	}
	(*pci_putl_func)((tag >> 16) & 0xff, (tag >> 11) & 0x1f,
	    (tag >> 8) & 0x7, reg, val);
}

/* Walk the standard capability list. Returns 1 and the offset/value of the
 * first capability with this id, 0 if absent. */
int
pci_get_capability(pci_chipset_tag_t pc, pcitag_t tag, int capid,
    int *offset, pcireg_t *value)
{
	pcireg_t reg;
	int off, n;

	if (!(pci_conf_read(pc, tag, PCI_COMMAND_STATUS_REG) & (1 << 20)))
		return (0);		/* no capability list */
	off = pci_conf_read(pc, tag, PCI_CAPLISTPTR_REG) & 0xfc;
	for (n = 0; off != 0 && n < 48; n++) {
		reg = pci_conf_read(pc, tag, off);
		if ((reg & 0xff) == (pcireg_t)capid) {
			if (offset != NULL)
				*offset = off;
			if (value != NULL)
				*value = reg;
			return (1);
		}
		off = (reg >> 8) & 0xfc;
	}
	return (0);
}

/* BAR type, as OpenBSD decodes it from the low bits. */
pcireg_t
pci_mapreg_type(pci_chipset_tag_t pc, pcitag_t tag, int reg)
{
	pcireg_t v = pci_conf_read(pc, tag, reg);

	/* IO: the type bit; memory: type bit + the 32/64-bit field (0x7). */
	return (PCI_MAPREG_TYPE(v) == PCI_MAPREG_TYPE_IO ? (v & 0x1) :
	    (v & 0x7));
}

/*
 * BAR base and size by the standard all-ones probe. Run before the BAR is
 * mapped (i915 calls it from attach); the original value is restored.
 */
int
pci_mapreg_info(pci_chipset_tag_t pc, pcitag_t tag, int reg, pcireg_t type,
    bus_addr_t *basep, bus_size_t *sizep, int *flagsp)
{
	pcireg_t lo, mlo, hi = 0, mhi = 0;
	uint64_t base, mask;
	int is64 = PCI_MAPREG_TYPE(type) == PCI_MAPREG_TYPE_MEM &&
	    PCI_MAPREG_MEM_TYPE(type) == PCI_MAPREG_MEM_TYPE_64BIT;

	/*
	 * The attached device: read the BAR from the DDI's assigned-addresses
	 * property. The all-ones probe below would point a live BAR at
	 * garbage while it decodes, and on dixi BAR2 (GMADR) is the console
	 * framebuffer gfxp_bitmap is drawing into.
	 */
	if (pc != NULL && pc->pc_dip != NULL && tag == pc->pc_self)
		return (obsd_pci_bar(pc->pc_dip, reg, basep, sizep, flagsp));
	lo = pci_conf_read(pc, tag, reg);
	pci_conf_write(pc, tag, reg, 0xffffffff);
	mlo = pci_conf_read(pc, tag, reg);
	pci_conf_write(pc, tag, reg, lo);
	if (is64) {
		hi = pci_conf_read(pc, tag, reg + 4);
		pci_conf_write(pc, tag, reg + 4, 0xffffffff);
		mhi = pci_conf_read(pc, tag, reg + 4);
		pci_conf_write(pc, tag, reg + 4, hi);
	}
	if (PCI_MAPREG_TYPE(type) == PCI_MAPREG_TYPE_IO) {
		base = lo & ~0x3u;
		mask = (mlo & ~0x3u) | 0xffff0000u;
		mask |= 0xffffffff00000000ull;
	} else {
		base = ((uint64_t)hi << 32) | (lo & PCI_MAPREG_MEM_ADDR_MASK);
		mask = ((uint64_t)(is64 ? mhi : 0xffffffff) << 32) |
		    (mlo & PCI_MAPREG_MEM_ADDR_MASK);
	}
	if (mask == 0 || mask == 0xffffffffffffffffull)
		return (EINVAL);
	if (basep != NULL)
		*basep = base;
	if (sizep != NULL)
		*sizep = (~mask) + 1;
	if (flagsp != NULL)
		*flagsp = PCI_MAPREG_MEM_PREFETCHABLE(lo) ?
		    BUS_SPACE_MAP_PREFETCHABLE : 0;
	return (0);
}
