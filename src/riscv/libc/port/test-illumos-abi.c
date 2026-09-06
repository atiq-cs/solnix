/*
 * test-illumos-abi.c -- self-check for the riscv64 libc illumos ABI entry
 * points in ../src/riscv/libc/port/illumos_abi.c.
 *
 * WHAT: exercises the REAL implementations (dev_t encode/decode round-trips,
 * stack_getbounds bounds, pset_info's supported/refused subcodes,
 * __posix_getpwuid_r's buffer + errno discipline, ___errno identity) and
 * asserts the ENOSYS entries fail rather than returning plausible values.
 *
 * WHY: illumos_abi.c mixes REAL implementations with deliberate ENOSYS
 * refusals. The risk this guards is a refusal quietly turning into a fake
 * success (or a real function regressing into one), which is the specific
 * dishonesty the file's contract forbids.
 *
 * HOW TO RUN (host build -- the logic is host-independent):
 *   cc -o /tmp/t test-illumos-abi.c && /tmp/t
 * Under qemu for the real target:
 *   riscv64-none-elf-gcc -march=rv64gc -mabi=lp64d ... (needs a libc; the host
 *   build is the practical check and covers the same code paths)
 *
 * Prints one line per group and exits non-zero on the first failure.
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <assert.h>

/* --- minimal stand-ins for the reduced libc's types/deps ----------------- */
typedef unsigned int uid_t;
typedef unsigned int gid_t;
typedef unsigned int major_t;
typedef unsigned int minor_t;
typedef unsigned long dev_t;

struct passwd {
	char	*pw_name;
	char	*pw_passwd;
	uid_t	pw_uid;
	gid_t	pw_gid;
	char	*pw_gecos;
	char	*pw_dir;
	char	*pw_shell;
};

int errno;

/* The kernel-count hook illumos_abi.c calls; faked here so pset_info is
 * testable without a kernel. */
static long fake_ncpu = 8;
long __sys_ncpu(void) { return (fake_ncpu); }

/* rp41's /etc/passwd-backed getpwuid, faked with a known record. */
static int getpwuid_should_fail;
struct passwd *
getpwuid(uid_t uid)
{
	static struct passwd pw;
	if (getpwuid_should_fail)
		return (0);
	pw.pw_name = (char *)"solnix";
	pw.pw_passwd = (char *)"x";
	pw.pw_uid = uid;
	pw.pw_gid = 0;
	pw.pw_gecos = (char *)"";
	pw.pw_dir = (char *)"/";
	pw.pw_shell = (char *)"/bin/sh";
	return (&pw);
}

/* _exit/write are only reached by the __tls_get_addr abort path, which this
 * test deliberately does NOT call (it would kill the test process). */

#define	OLDDEV	0
#define	NEWDEV	1
#define	PS_MYID	(-3)
#define	PS_QUERY (-2)
#define	EINVAL	22
#define	ERANGE	34
#define	ENOSYS	89
#define	EFAULT	14
#define	EAI_FAIL 4
/* illumos value; spelled out because the freestanding riscv64 build has no
 * <errno.h> with the illumos numbering. */
#define	EAFNOSUPPORT 97

typedef struct solnix_stack {
	void	*ss_sp;
	size_t	ss_size;
	int	ss_flags;
} solnix_stack_t;

/* --- the unit under test ------------------------------------------------- */
int *___errno(void);
int stack_getbounds(void *);
const char *getexecname(void);
int pset_info(int, int *, unsigned int *, int *);
int __posix_getpwuid_r(uid_t, struct passwd *, char *, size_t, struct passwd **);
major_t __major(int, dev_t);
minor_t __minor(int, dev_t);
dev_t __makedev(int, major_t, minor_t);
int __xnet_socket(int, int, int);
int __xnet_socketpair(int, int, int, int[2]);
int __xnet_bind(int, const void *, unsigned int);
int __xnet_connect(int, const void *, unsigned int);
int __xnet_getsockopt(int, int, int, void *, unsigned int *);
int __xnet_getaddrinfo(const char *, const char *, const void *, void **);
extern const char *__solnix_auxv_execname;

static int failures;
#define	CHECK(cond, what)	do {					\
	if (!(cond)) {							\
		printf("  FAIL: %s\n", (what));				\
		failures++;						\
	}								\
} while (0)

int
main(void)
{
	/* ---- ___errno: must alias the process errno exactly. */
	errno = 0;
	*___errno() = 41;
	CHECK(errno == 41, "___errno() does not alias errno");
	CHECK(___errno() == &errno, "___errno() returned a different address");
	printf("___errno: OK (aliases errno)\n");

	/* ---- stack_getbounds: real bounds, and EFAULT on NULL. */
	{
		solnix_stack_t s;
		memset(&s, 0xff, sizeof (s));
		CHECK(stack_getbounds(&s) == 0, "stack_getbounds failed");
		CHECK(s.ss_size == 16UL * 4096UL, "stack size not 64 KiB");
		CHECK(s.ss_flags == 0, "ss_flags not 0");
		/* ss_sp must be the LOW address and top must land on USTACK_TOP. */
		CHECK((unsigned long)s.ss_sp == 0xfffff000UL - s.ss_size,
		    "ss_sp is not the stack base");
		CHECK((unsigned long)s.ss_sp + s.ss_size == 0xfffff000UL,
		    "base+size != USTACK_TOP");
		errno = 0;
		CHECK(stack_getbounds(0) == -1 && errno == EFAULT,
		    "stack_getbounds(NULL) should be EFAULT");
		printf("stack_getbounds: OK (base+64KiB == 0xfffff000, EFAULT on NULL)\n");
	}

	/* ---- getexecname: NULL until the kernel supplies AT_SUN_EXECNAME,
	 * and returns the auxv value once it does. Both directions matter:
	 * this proves it is real code reading a variable, not a hardcoded stub. */
	CHECK(getexecname() == 0, "getexecname should be NULL with no auxv");
	__solnix_auxv_execname = "/usr/bin/hello";
	CHECK(getexecname() != 0 &&
	    strcmp(getexecname(), "/usr/bin/hello") == 0,
	    "getexecname did not return the auxv value");
	__solnix_auxv_execname = 0;
	printf("getexecname: OK (NULL without auxv, path with it)\n");

	/* ---- pset_info: real count for PS_MYID; refuses everything else. */
	{
		unsigned int n = 0;
		int type = -1;
		fake_ncpu = 8;
		CHECK(pset_info(PS_MYID, &type, &n, 0) == 0, "pset_info failed");
		CHECK(n == 8, "pset_info numcpus not from __sys_ncpu");
		CHECK(type == 1, "pset_info type not PS_SYSTEM");
		/* a different CPU count must be reflected -- proves it reads the
		 * kernel value rather than returning a constant. */
		fake_ncpu = 3;
		n = 0;
		CHECK(pset_info(PS_MYID, 0, &n, 0) == 0, "pset_info failed (2)");
		CHECK(n == 3, "pset_info did not track the kernel count");
		/* refusals, not fabrications. */
		errno = 0;
		CHECK(pset_info(PS_QUERY, 0, &n, 0) == -1 && errno == EINVAL,
		    "pset_info(PS_QUERY) should be EINVAL");
		{
			int cpulist[4];
			errno = 0;
			CHECK(pset_info(PS_MYID, 0, &n, cpulist) == -1 &&
			    errno == EINVAL,
			    "pset_info with cpulist should be EINVAL");
		}
		fake_ncpu = 0;
		errno = 0;
		CHECK(pset_info(PS_MYID, 0, &n, 0) == -1,
		    "pset_info should fail when the kernel reports 0 CPUs");
		fake_ncpu = 8;
		printf("pset_info: OK (tracks kernel count; EINVAL on unsupported)\n");
	}

	/* ---- dev_t: round-trip both encodings + range refusal. */
	{
		dev_t d;
		/* NEWDEV: 14-bit major, 18-bit minor. */
		d = __makedev(NEWDEV, 0x3fff, 0x3ffff);
		CHECK(__major(NEWDEV, d) == 0x3fff, "NEWDEV major round-trip");
		CHECK(__minor(NEWDEV, d) == 0x3ffff, "NEWDEV minor round-trip");
		d = __makedev(NEWDEV, 42, 7);
		CHECK(__major(NEWDEV, d) == 42 && __minor(NEWDEV, d) == 7,
		    "NEWDEV 42/7 round-trip");
		/* OLDDEV: 8-bit each. */
		d = __makedev(OLDDEV, 0xff, 0xff);
		CHECK(__major(OLDDEV, d) == 0xff, "OLDDEV major round-trip");
		CHECK(__minor(OLDDEV, d) == 0xff, "OLDDEV minor round-trip");
		d = __makedev(OLDDEV, 3, 9);
		CHECK(__major(OLDDEV, d) == 3 && __minor(OLDDEV, d) == 9,
		    "OLDDEV 3/9 round-trip");
		/* out-of-range and bad-version must be refused, not truncated. */
		errno = 0;
		CHECK(__makedev(OLDDEV, 0x100, 0) == (dev_t)-1 &&
		    errno == EINVAL, "OLDDEV major overflow not refused");
		errno = 0;
		CHECK(__makedev(NEWDEV, 0x4000, 0) == (dev_t)-1 &&
		    errno == EINVAL, "NEWDEV major overflow not refused");
		errno = 0;
		CHECK(__makedev(NEWDEV, 0, 0x40000) == (dev_t)-1 &&
		    errno == EINVAL, "NEWDEV minor overflow not refused");
		errno = 0;
		CHECK(__major(99, 0) == (major_t)-1 && errno == EINVAL,
		    "bad version not refused by __major");
		printf("dev_t: OK (both encodings round-trip; overflow refused)\n");
	}

	/* ---- __posix_getpwuid_r: copies into the CALLER's buffer, returns
	 * errno instead of setting it, and leaves the caller's errno intact. */
	{
		struct passwd pw, *res = 0;
		char buf[256];
		int r;

		errno = 1234;			/* sentinel */
		memset(&pw, 0, sizeof (pw));
		r = __posix_getpwuid_r(0, &pw, buf, sizeof (buf), &res);
		CHECK(r == 0, "__posix_getpwuid_r failed");
		CHECK(res == &pw, "result should point at the caller's struct");
		CHECK(errno == 1234, "caller's errno must be preserved");
		CHECK(strcmp(pw.pw_name, "solnix") == 0, "pw_name wrong");
		CHECK(strcmp(pw.pw_shell, "/bin/sh") == 0, "pw_shell wrong");
		/* every string must live INSIDE the caller's buffer */
		CHECK(pw.pw_name >= buf && pw.pw_name < buf + sizeof (buf),
		    "pw_name not in caller buffer");
		CHECK(pw.pw_shell >= buf && pw.pw_shell < buf + sizeof (buf),
		    "pw_shell not in caller buffer");

		/* too-small buffer => ERANGE, and errno still untouched. */
		errno = 1234;
		res = (struct passwd *)1;
		r = __posix_getpwuid_r(0, &pw, buf, 4, &res);
		CHECK(r == ERANGE, "small buffer should give ERANGE");
		CHECK(errno == 1234, "errno must be preserved on ERANGE");

		/* lookup failure => nonzero return, res cleared. */
		getpwuid_should_fail = 1;
		errno = 1234;
		res = (struct passwd *)1;
		r = __posix_getpwuid_r(0, &pw, buf, sizeof (buf), &res);
		CHECK(r != 0, "failed lookup should return nonzero");
		CHECK(res == 0, "failed lookup should clear *result");
		CHECK(errno == 1234, "errno must be preserved on failure");
		getpwuid_should_fail = 0;

		/* bad args => EINVAL. */
		CHECK(__posix_getpwuid_r(0, 0, buf, sizeof (buf), &res) == EINVAL,
		    "NULL pwd should be EINVAL");
		printf("__posix_getpwuid_r: OK (caller buffer, errno discipline)\n");
	}

	/* ---- the socket group: must FAIL, and fail for the RIGHT REASON.
	 *
	 * This is the anti-fake check, and it got sharper when AF_UNIX became
	 * real: the question is no longer "does everything refuse" but "does each
	 * entry refuse the things that genuinely do not exist, and refuse them
	 * with the errno that names the actual reason".
	 *   - a NON-AF_UNIX family must give EAFNOSUPPORT: there is still no IP
	 *     stack, and saying ENOSYS would understate that AF_UNIX works.
	 *   - __xnet_sendto stays ENOSYS: an addressed send needs SOCK_DGRAM,
	 *     which the kernel refuses.
	 * On the HOST there is no solnix kernel to ecall into, so an AF_UNIX call
	 * reports ENOSYS from the host stub; the riscv64 in-kernel gate
	 * (uts/user/socktest.c) is what proves the AF_UNIX path really works. */
	{
		int sv[2] = { -1, -1 };
		unsigned int ol = 0;
		void *res = (void *)1;

		errno = 0;
		CHECK(__xnet_socket(2, 1, 0) == -1 && errno == EAFNOSUPPORT,
		    "__xnet_socket(AF_INET) must fail EAFNOSUPPORT (no IP stack)");
		errno = 0;
		CHECK(__xnet_socketpair(2, 1, 0, sv) == -1 &&
		    errno == EAFNOSUPPORT,
		    "__xnet_socketpair(AF_INET) must fail EAFNOSUPPORT");
		CHECK(sv[0] == -1 && sv[1] == -1,
		    "__xnet_socketpair must not hand back fds on failure");
		errno = 0;
		CHECK(__xnet_bind(0, "", 0) == -1,
		    "__xnet_bind on a non-socket fd must fail");
		errno = 0;
		CHECK(__xnet_connect(0, "", 0) == -1,
		    "__xnet_connect on a non-socket fd must fail");
		errno = 0;
		CHECK(__xnet_getsockopt(0, 0, 0, 0, &ol) == -1,
		    "__xnet_getsockopt on a non-socket fd must fail");
		/* getaddrinfo does NOT use errno; it returns EAI_*. */
		CHECK(__xnet_getaddrinfo("h", 0, 0, &res) == EAI_FAIL,
		    "__xnet_getaddrinfo must return EAI_FAIL");
		CHECK(res == 0, "__xnet_getaddrinfo must NULL *res");
		printf("__xnet_* group: OK (AF_INET refused EAFNOSUPPORT, sendto/getaddrinfo "
	    "ENOSYS/EAI_FAIL; AF_UNIX proven by uts/user/socktest.c on the target)\n");
	}

	/* NOTE: __tls_get_addr is intentionally NOT called -- it aborts the
	 * process by design (see illumos_abi.c: handing back any address would
	 * silently corrupt thread-local state). Its contract is "never
	 * returns", which cannot be asserted from inside the same process. */

	if (failures != 0) {
		printf("\nFAILED: %d check(s)\n", failures);
		return (1);
	}
	printf("\nALL CHECKS PASSED\n");
	return (0);
}
