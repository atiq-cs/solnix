/*
 * test_sleep.c -- userland test of obsd_time.c's OpenBSD sleep queue (built
 * with -DOBSD_USERTEST against obsd_ushim.h). Exit 0 = all PASS.
 *
 * What inteldrm relies on (OpenBSD linux/wait.h, drm_linux.c, measured):
 *   wait_event*: prepare_to_wait -> sleep_setup, test the condition, then
 *     sleep_finish(nsecs, !cond); a wakeup between the two must not be lost.
 *   *_timeout: EWOULDBLOCK when the time runs out.
 *   *_interruptible: PCATCH -> EINTR on a signal (-ERESTARTSYS upstream).
 *   msleep: the interlock is dropped only once the thread is queued.
 *   wakeup_one / wakeup_n: wakes at most n sleepers on that channel.
 * Negative controls (Makefile): -DOBSD_SLEEP_SABOTAGE=1 drops the early-
 * wakeup check, =2 makes wakeup() wake the whole hash bucket; each must FAIL.
 */
#include "../obsd_time.c"
#include <stdio.h>
#include <unistd.h>

__thread volatile int *ushim_sigp;
static __thread struct proc *ushim_self;
static int fails;

struct proc *
ushim_curproc(void)
{
	if (ushim_self == NULL) {
		ushim_self = calloc(1, sizeof (*ushim_self));
		cv_init(&ushim_self->p_cv, NULL, 0, NULL);
		ushim_self->p_stat = SONPROC;
	}
	return (ushim_self);
}

#define MS	1000000LL
static void
check(int ok, const char *what, long long ms, int r)
{
	printf("%s %-58s %4lld ms ret=%d\n", ok ? "PASS" : "FAIL", what, ms, r);
	if (!ok)
		fails++;
}

/* Two channels in the same hash bucket (OBSD_LOOKUP = (x >> 8) & 127). */
static char chans[2 * OBSD_SLPQ_SIZE * 256];
#define CHAN_A	((void *)&chans[0])
#define CHAN_B	((void *)&chans[OBSD_SLPQ_SIZE * 256])

struct sleeper {
	void		*chan;
	int		prio;
	uint64_t	nsecs;
	volatile int	sig;
	volatile int	done, ret;
	long long	ms;
};

static void *
sleeper_main(void *arg)
{
	struct sleeper *s = arg;
	hrtime_t t0;

	ushim_sigp = &s->sig;
	t0 = gethrtime();
	s->ret = tsleep_nsec(s->chan, s->prio, "test", s->nsecs);
	s->ms = (gethrtime() - t0) / MS;
	s->done = 1;
	return (NULL);
}

static void
spawn(pthread_t *t, struct sleeper *s, void *chan, int prio, long long ms)
{
	s->chan = chan;
	s->prio = prio;
	s->nsecs = ms * MS;
	s->done = s->sig = 0;
	pthread_create(t, NULL, sleeper_main, s);
	usleep(30000);		/* let it reach the sleep queue */
}

static pthread_mutex_t ilk = PTHREAD_MUTEX_INITIALIZER;
static volatile int cond;
static volatile int iter, timeouts;

static void *
msleep_waiter(void *arg)
{
	int n;

	(void) arg;
	for (n = 0; n < 2000; n++) {
		pthread_mutex_lock(&ilk);
		while (cond == 0)
			if (msleep_nsec((void *)&cond, (struct mutex *)&ilk, 0,
			    "ilk", 200 * MS) == EWOULDBLOCK)
				timeouts++;
		cond = 0;
		iter = n + 1;
		pthread_mutex_unlock(&ilk);
	}
	return (NULL);
}

int
main(void)
{
	struct sleeper s1, s2;
	pthread_t t1, t2;
	hrtime_t t0;
	int r, n;

	obsd_sleepq_init();

	/* 1. wakeup between sleep_setup and sleep_finish is not lost */
	t0 = gethrtime();
	sleep_setup(CHAN_A, 0, "early");
	wakeup(CHAN_A);
	r = sleep_finish(500 * MS, 1);
	n = (gethrtime() - t0) / MS;
	check(r == 0 && n < 100, "early wakeup (wait_event race) not lost", n, r);

	/* 2. timeout */
	t0 = gethrtime();
	r = tsleep_nsec(&nowake, 0, "to", 50 * MS);
	n = (gethrtime() - t0) / MS;
	check(r == EWOULDBLOCK && n >= 50 && n < 400, "timeout -> EWOULDBLOCK",
	    n, r);

	/* 3. a wakeup from another thread */
	spawn(&t1, &s1, CHAN_A, 0, 2000);
	wakeup(CHAN_A);
	pthread_join(t1, NULL);
	check(s1.ret == 0 && s1.ms < 1000, "cross-thread wakeup", s1.ms, s1.ret);

	/* 4. a wakeup of another channel in the same bucket does not wake */
	spawn(&t1, &s1, CHAN_A, 0, 300);
	wakeup(CHAN_B);
	pthread_join(t1, NULL);
	check(s1.ret == EWOULDBLOCK && s1.ms >= 300,
	    "same-bucket other-channel wakeup ignored", s1.ms, s1.ret);

	/* 5. wakeup_one wakes exactly one of two sleepers */
	spawn(&t1, &s1, CHAN_A, 0, 400);
	spawn(&t2, &s2, CHAN_A, 0, 400);
	wakeup_one(CHAN_A);
	usleep(100000);
	n = s1.done + s2.done;
	pthread_join(t1, NULL);
	pthread_join(t2, NULL);
	check(n == 1 && (s1.ret == 0) + (s2.ret == 0) == 1,
	    "wakeup_one wakes exactly one", (long long)n, s1.ret + s2.ret);

	/* 6. PCATCH: a signal during the sleep -> EINTR */
	spawn(&t1, &s1, CHAN_A, PCATCH, 2000);
	s1.sig = 1;
	pthread_join(t1, NULL);
	check(s1.ret == EINTR && s1.ms < 1000, "PCATCH + signal -> EINTR",
	    s1.ms, s1.ret);

	/* 7. no PCATCH: the same signal does not interrupt (kernel sleep) */
	spawn(&t1, &s1, CHAN_A, 0, 200);
	s1.sig = 1;
	pthread_join(t1, NULL);
	check(s1.ret == EWOULDBLOCK, "no PCATCH: signal ignored until timeout",
	    s1.ms, s1.ret);

	/* 8. msleep interlock: 2000 hand-offs, none may hit the timeout */
	pthread_create(&t1, NULL, msleep_waiter, NULL);
	t0 = gethrtime();
	for (n = 0; n < 2000; n++) {
		pthread_mutex_lock(&ilk);
		cond = 1;
		wakeup((void *)&cond);
		pthread_mutex_unlock(&ilk);
		while (iter <= n && (gethrtime() - t0) < 60000 * MS)
			sched_yield();
	}
	pthread_join(t1, NULL);
	n = (gethrtime() - t0) / MS;
	check(iter == 2000 && timeouts == 0, "msleep interlock: 2000 hand-offs, 0 lost",
	    n, timeouts);

	printf("%s: %d failure(s)\n", fails ? "FAIL" : "PASS", fails);
	return (fails != 0);
}
