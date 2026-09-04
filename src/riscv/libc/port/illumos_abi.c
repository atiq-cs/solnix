/*
 * illumos_abi.c -- solnix riscv64 libc: the illumos-specific ABI entry points
 * Rust std references that a generic libc does not have.
 *
 * WHY THIS FILE EXISTS: rustc's illumos targets reference a set of
 * illumos-libc-only symbols. `nm --undefined-only` on the riscv64 std/libc
 * rlibs (target riscv64gc-unknown-illumos) names sixteen; the audit and the
 * per-symbol reasoning are in docs/riscv64-libc-rust-abi-gap.md. This TU
 * implements the subset that can be implemented REALLY on the kernel we
 * actually have, and refuses -- loudly and with ENOSYS -- to fake the rest.
 *
 * ============================ HONESTY CONTRACT ============================
 * Every entry point below is tagged with exactly one of:
 *
 *   [REAL]   Genuine working behaviour. Does what illumos does, within the
 *            documented limits of this kernel.
 *   [REAL/1THREAD]
 *            Genuine and correct for a single-threaded process, which is what
 *            this kernel supports today. Becomes WRONG when LWPs land; each
 *            such site says exactly what must change.
 *   [ENOSYS] NOT IMPLEMENTED. Returns an error (never a plausible-looking
 *            fake value). Present only so a link completes and so the failure
 *            is diagnosable at runtime instead of mysterious at link time.
 *
 * There are deliberately NO silent stubs in this file. A stub that returns a
 * believable value is worse than a missing symbol, because it converts a link
 * error into a wrong answer somewhere far away.
 * ==========================================================================
 *
 * CRIB PROVENANCE: behaviour matched against the illumos gate --
 *   ___errno            usr/src/lib/libc/port/gen/errno.c
 *   stack_getbounds     usr/src/lib/libc/port/gen/stack.c
 *   getexecname         usr/src/lib/libc/port/gen/getexecname.c
 *   pset_info           usr/src/lib/libc/port/sys/psetsys.c
 *   __posix_getpwuid_r  usr/src/lib/libc/port/gen/getpwnam_r.c
 *   __major/__minor/__makedev
 *                       usr/src/lib/libc/port/gen/mkdev.c
 *   __xnet_*            usr/src/lib/libsocket/socket/weaks.c (libSOCKET, not libc)
 * Reimplemented in illumos idiom from the observable contract; no CDDL source
 * copied.
 */

#include <sys/types.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <pwd.h>

/*
 * errno lives in the syscall TU (port/syscall.c) as a single process-wide int.
 * That is the whole thread model this kernel has today.
 */
extern int errno;

/* Error numbers we return directly. Keep in step with the kernel's list. */
#define	ENOENT		2
#define	ESRCH		3
#define	ENOMEM		12
#define	EFAULT		14
#define	EINVAL		22
#define	ERANGE		34
#define	ENOSYS		89
#define	EAFNOSUPPORT	124

/*
 * ---------------------------------------------------------------------------
 * [REAL/1THREAD] ___errno -- the address of the calling thread's errno.
 *
 * illumos: `return (curthread->ul_errnop)`, i.e. errno is per-LWP and every
 * <errno.h> reference expands to *___errno(). Rust std and the libc crate call
 * this for EVERY errno read, so it must be right.
 *
 * Here: this kernel runs one thread per process (no LWPs, no
 * thr_create/pthread), so the process-wide `errno` IS the calling thread's
 * errno and returning its address is genuinely correct -- not an approximation.
 *
 * WHEN THREADS LAND THIS MUST CHANGE: give each LWP an errno slot (illumos
 * hangs it off the ulwp_t reached via the thread pointer, tp/x4 on RISC-V, which
 * uts/swtch.S already saves and restores per thread) and return that. Leaving
 * this as-is under threads produces cross-thread errno corruption, which is
 * both a real bug and a very hard one to see.
 * ---------------------------------------------------------------------------
 */
int *
___errno(void)
{
	return (&errno);
}

/*
 * ---------------------------------------------------------------------------
 * [REAL] stack_getbounds -- report the calling thread's stack extent.
 *
 * illumos: `*sp = curthread->ul_ustack`, a stack_t recorded when the stack was
 * created.
 *
 * WHY IT MUST BE REAL (not a stub): Rust std calls this inside
 * `assert_eq!(libc::stack_getbounds(&mut s), 0)` in
 * library/std/src/sys/pal/unix/stack_overflow.rs (get_stack_start). A stub
 * returning -1 therefore ABORTS EVERY RUST PROGRAM during runtime init, before
 * main. This is the single symbol in this file that a stub would most obviously
 * break, and it is why the value below comes from the kernel's real numbers.
 *
 * The numbers: the kernel maps the initial user stack in uts/uproc.c as
 * [USTACK_TOP - USTACK_SIZE, USTACK_TOP) with USTACK_TOP == 0xfffff000 and
 * USTACK_PAGES == 16 (64 KiB). ss_sp is the LOW address (stack base) -- illumos
 * stack_t semantics, matching what std then uses as the guard-page anchor.
 *
 * LIMITATION, stated plainly: these are compile-time constants that mirror the
 * kernel's compile-time constants. They are correct as long as both agree. The
 * moment the kernel grows a variable-size or grow-down-on-fault stack, or LWPs
 * with individually allocated stacks, this must read the real per-thread record
 * (ideally via an auxv entry or a small syscall) instead of assuming.
 * ---------------------------------------------------------------------------
 */
#define	SOLNIX_USTACK_TOP	0xfffff000UL	/* uts/uproc.c USTACK_TOP */
#define	SOLNIX_USTACK_SIZE	(16UL * 4096UL)	/* USTACK_PAGES * PAGESIZE */

/* illumos <sys/stack.h> stack_t. Declared here because the reduced libc has no
 * <ucontext.h> yet; when one lands, include it and drop this. */
typedef struct solnix_stack {
	void		*ss_sp;
	size_t		ss_size;
	int		ss_flags;
} solnix_stack_t;

int
stack_getbounds(void *sp)
{
	solnix_stack_t *s = (solnix_stack_t *)sp;

	if (s == 0) {
		errno = EFAULT;
		return (-1);
	}
	s->ss_sp = (void *)(SOLNIX_USTACK_TOP - SOLNIX_USTACK_SIZE);
	s->ss_size = SOLNIX_USTACK_SIZE;
	s->ss_flags = 0;
	return (0);
}

/*
 * ---------------------------------------------------------------------------
 * [REAL] getexecname -- the path of the running executable.
 *
 * illumos: `return ___getauxptr(AT_SUN_EXECNAME)` -- purely a read of the
 * AT_SUN_EXECNAME (2014) auxv entry the kernel planted at exec.
 *
 * Here: __solnix_auxv_execname is set by the libc startup code
 * (port/libc_start.c) when it walks the auxv the kernel left on the initial
 * stack. If the kernel did not supply AT_SUN_EXECNAME the pointer stays NULL
 * and we return NULL -- which is exactly what illumos does for an exec that
 * had no execname, and what Rust's std::env::current_exe treats as a
 * recoverable Err.
 *
 * KERNEL DEPENDENCY, stated honestly: as of this writing uts/uproc.c's
 * build_user_stack plants only AT_PAGESZ/AT_ENTRY/AT_UID/AT_EUID/AT_GID/
 * AT_EGID -- there is NO AT_SUN_EXECNAME. So this function is real code that
 * currently has nothing to read, and returns NULL until the kernel adds that
 * one auxv entry. It is NOT a stub: it will start working the moment the
 * kernel supplies the data, with no change here.
 * ---------------------------------------------------------------------------
 */
const char *__solnix_auxv_execname;	/* set by libc startup from auxv */

const char *
getexecname(void)
{
	return (__solnix_auxv_execname);
}

/*
 * ---------------------------------------------------------------------------
 * [REAL, subcode-limited] pset_info -- processor-set information.
 *
 * illumos: `_pset(PSET_INFO, pset, type, numcpus, cpulist)` over SYS_pset(207).
 *
 * Rust uses exactly one shape of this call, in
 * library/std/src/sys/thread/unix.rs (available_parallelism):
 *     pset_info(PS_MYID, NULL, &cpus, NULL)
 * i.e. "how many CPUs are in my processor set". We answer that from the
 * kernel's real online-CPU count (__sys_ncpu -> SYS_ncpu, which the kernel
 * already implements and rp48's libc already wraps), so the number returned is
 * measured, not invented.
 *
 * SCOPE, stated plainly: only PS_MYID with a NULL cpulist is supported, because
 * this kernel has no processor sets -- every CPU is in the one implicit set.
 * Any other pset id, or a request for the cpulist, gets EINVAL rather than a
 * fabricated answer. Real processor sets need SYS_pset (absent) and a kernel
 * pset abstraction (absent).
 * ---------------------------------------------------------------------------
 */
#define	PS_NONE		(-1)
#define	PS_QUERY	(-2)
#define	PS_MYID		(-3)
#define	PS_SYSTEM	1		/* <sys/pset.h> pset type */

extern long __sys_ncpu(void);		/* rp48 libc: SYS_ncpu */

int
pset_info(int pset, int *type, unsigned int *numcpus, int *cpulist)
{
	long n;

	/*
	 * Only "my set" is answerable. PS_QUERY/explicit ids would require real
	 * processor sets; say EINVAL instead of pretending.
	 */
	if (pset != PS_MYID) {
		errno = EINVAL;
		return (-1);
	}
	/* We cannot enumerate per-CPU ids, so a cpulist request is refused. */
	if (cpulist != 0) {
		errno = EINVAL;
		return (-1);
	}

	n = __sys_ncpu();
	if (n <= 0) {
		errno = EINVAL;
		return (-1);
	}
	if (type != 0)
		*type = PS_SYSTEM;
	if (numcpus != 0)
		*numcpus = (unsigned int)n;
	return (0);
}

/*
 * ---------------------------------------------------------------------------
 * [REAL] __posix_getpwuid_r -- POSIX-flavoured reentrant passwd-by-uid.
 *
 * illumos (port/gen/getpwnam_r.c): call getpwuid_r, and RETURN the errno rather
 * than setting it, leaving the caller's errno untouched. That errno-discipline
 * inversion is the entire reason the __posix_ variant exists, so it is
 * reproduced exactly: save errno, clear it, call, restore, return what the call
 * set.
 *
 * The lookup itself is real: it packs a struct passwd into the CALLER's buffer
 * from the same /etc/passwd scan rp41's getpwuid already performs (the illumos
 * "files" nsswitch backend reduced to one file). No global statics are handed
 * back, so this is genuinely reentrant with respect to the caller's storage.
 *
 * Rust uses it for std::env::home_dir; a failure is a recoverable None.
 * ---------------------------------------------------------------------------
 */
int
__posix_getpwuid_r(uid_t uid, struct passwd *pwd, char *buffer, size_t bufsize,
    struct passwd **result)
{
	int oerrno = errno;
	int nerrno = 0;
	struct passwd *p;
	size_t need;
	char *b = buffer;

	if (pwd == 0 || result == 0 || buffer == 0)
		return (EINVAL);

	*result = 0;
	errno = 0;

	/*
	 * rp41's getpwuid returns a pointer to libc statics; copy every string
	 * into the caller's buffer so the result is independent of them.
	 */
	p = getpwuid(uid);
	if (p == 0) {
		nerrno = (errno != 0) ? errno : ENOENT;
		errno = oerrno;
		return (nerrno);
	}

	need = strlen(p->pw_name) + 1 + strlen(p->pw_passwd) + 1 +
	    strlen(p->pw_gecos) + 1 + strlen(p->pw_dir) + 1 +
	    strlen(p->pw_shell) + 1;
	if (need > bufsize) {
		errno = oerrno;
		return (ERANGE);
	}

#define	COPYSTR(dst, src)	do {					\
		size_t _n = strlen(src) + 1;				\
		memcpy(b, (src), _n);					\
		(dst) = b;						\
		b += _n;						\
	} while (0)

	pwd->pw_uid = p->pw_uid;
	pwd->pw_gid = p->pw_gid;
	COPYSTR(pwd->pw_name, p->pw_name);
	COPYSTR(pwd->pw_passwd, p->pw_passwd);
	COPYSTR(pwd->pw_gecos, p->pw_gecos);
	COPYSTR(pwd->pw_dir, p->pw_dir);
	COPYSTR(pwd->pw_shell, p->pw_shell);
#undef	COPYSTR

	errno = oerrno;
	*result = pwd;
	return (0);
}

/*
 * ---------------------------------------------------------------------------
 * [REAL] __major / __minor / __makedev -- versioned dev_t encode/decode.
 *
 * illumos port/gen/mkdev.c. Two encodings exist, selected by a version arg:
 *   OLDDEV (0): 8-bit major : 8-bit minor  (o_dev_t, 16 bit)
 *   NEWDEV (1): 14-bit major : 18-bit minor within a 32-bit dev_t
 * These are exact bit operations with no kernel dependency, so they are simply
 * correct. They are referenced by the libc CRATE (not std) -- and were missing
 * from the twelve-symbol list in docs/cosmic-riscv64-feasibility.md §1.4.
 * ---------------------------------------------------------------------------
 */
#define	OLDDEV		0
#define	NEWDEV		1
#define	O_BITSMAJOR	8
#define	O_BITSMINOR	8
#define	O_MAXMAJ	0xff
#define	O_MAXMIN	0xff
#define	L_BITSMAJOR	14
#define	L_BITSMINOR	18
#define	L_MAXMAJ	0x3fff
#define	L_MAXMIN	0x3ffff

major_t
__major(int version, dev_t devnum)
{
	major_t maj = (major_t)-1;

	switch (version) {
	case OLDDEV:
		maj = ((unsigned long)devnum >> O_BITSMINOR) & O_MAXMAJ;
		break;
	case NEWDEV:
		maj = ((unsigned long)devnum >> L_BITSMINOR) & L_MAXMAJ;
		break;
	default:
		errno = EINVAL;
		break;
	}
	return (maj);
}

minor_t
__minor(int version, dev_t devnum)
{
	minor_t min = (minor_t)-1;

	switch (version) {
	case OLDDEV:
		min = (minor_t)((unsigned long)devnum & O_MAXMIN);
		break;
	case NEWDEV:
		min = (minor_t)((unsigned long)devnum & L_MAXMIN);
		break;
	default:
		errno = EINVAL;
		break;
	}
	return (min);
}

dev_t
__makedev(int version, major_t majdev, minor_t mindev)
{
	dev_t dev = (dev_t)-1;

	switch (version) {
	case OLDDEV:
		if (majdev > O_MAXMAJ || mindev > O_MAXMIN) {
			errno = EINVAL;
			break;
		}
		dev = (dev_t)(((majdev & O_MAXMAJ) << O_BITSMINOR) |
		    (mindev & O_MAXMIN));
		break;
	case NEWDEV:
		if (majdev > L_MAXMAJ || mindev > L_MAXMIN) {
			errno = EINVAL;
			break;
		}
		dev = (dev_t)(((unsigned long)(majdev & L_MAXMAJ) <<
		    L_BITSMINOR) | (mindev & L_MAXMIN));
		break;
	default:
		errno = EINVAL;
		break;
	}
	return (dev);
}

/*
 * ===========================================================================
 * [ENOSYS] The socket surface. NOT IMPLEMENTED -- and deliberately not faked.
 * ===========================================================================
 *
 * On illumos these seven live in LIBSOCKET (usr/src/lib/libsocket/socket/
 * weaks.c, socket.c, socketpair.c), NOT in libc -- they are thin XPG4.2-flavour
 * shims over the _so_* libc syscall wrappers, e.g.
 *     __xnet_bind(s, a, l) => _so_bind(s, a, l, SOV_XPG4_2)
 * They are collected here only so that a riscv64 link can complete and so that
 * calling one FAILS VISIBLY.
 *
 * WHY NOT IMPLEMENTED: there is no socket layer in this kernel, and no IP
 * stack. Verified by grep over src/riscv/uts/ and the riscv-port kernel trees:
 * no sockaddr, no struct socket, no so_state, no tcp_, no ip_output. The
 * syscall dispatcher (uts/syscall.c) implements 21 calls and none of illumos's
 * socket syscalls (SYS_so_socket 230, so_socketpair 231, bind 232, listen 233,
 * accept 234, connect 235, recvfrom 238, sendto 242, getsockopt 245). The only
 * networking that exists is one raw-frame path: uts/vionet.c transmits a single
 * hand-built ARP frame, and rp63/kernel/emac.c drives the K1 MAC registers.
 * That is NIC bring-up, not a network stack.
 *
 * Therefore every one of these returns -1/ENOSYS. Any "implementation" of them
 * ahead of a socket layer could only be a fake, and a fake here would turn a
 * clear link-time gap into a mystifying runtime failure inside Rust's net code.
 *
 * NEAREST-TERM EXCEPTION worth recording: __xnet_socketpair for AF_UNIX needs
 * no IP stack at all -- an AF_UNIX socketpair is a bidirectional pipe, and this
 * kernel ALREADY has pipes (proc_pipe / SYS_pipe2). That makes it the one entry
 * here reachable without the multi-month networking work, and it is the one
 * Rust's process plumbing reaches for first. See
 * docs/riscv64-libc-rust-abi-gap.md §5 item 5.
 */

static int
solnix_no_socket(void)
{
	errno = ENOSYS;
	return (-1);
}

int
__xnet_socket(int family, int type, int protocol)
{
	(void) family; (void) type; (void) protocol;
	return (solnix_no_socket());	/* [ENOSYS] no socket layer */
}

int
__xnet_socketpair(int family, int type, int protocol, int sv[2])
{
	(void) family; (void) type; (void) protocol; (void) sv;
	/*
	 * [ENOSYS] -- but see the note above: AF_UNIX is implementable on the
	 * existing pipe machinery and should be the first of these to become
	 * real.
	 */
	return (solnix_no_socket());
}

int
__xnet_bind(int s, const void *addr, unsigned int addrlen)
{
	(void) s; (void) addr; (void) addrlen;
	return (solnix_no_socket());	/* [ENOSYS] */
}

int
__xnet_connect(int s, const void *addr, unsigned int addrlen)
{
	(void) s; (void) addr; (void) addrlen;
	return (solnix_no_socket());	/* [ENOSYS] */
}

ssize_t
__xnet_sendto(int s, const void *buf, size_t len, int flags, const void *addr,
    unsigned int addrlen)
{
	(void) s; (void) buf; (void) len; (void) flags;
	(void) addr; (void) addrlen;
	return ((ssize_t)solnix_no_socket());	/* [ENOSYS] */
}

int
__xnet_getsockopt(int s, int level, int optname, void *optval,
    unsigned int *optlenp)
{
	(void) s; (void) level; (void) optname; (void) optval; (void) optlenp;
	return (solnix_no_socket());	/* [ENOSYS] */
}

/*
 * [ENOSYS] __xnet_getaddrinfo -- name resolution. Sits ABOVE the socket layer
 * (needs a resolver, /etc/hosts, and DNS), so it is gated by everything above
 * plus libnsl/libresolv. EAI_FAIL (non-recoverable failure) is the correct
 * getaddrinfo-family error; it does NOT use errno.
 */
#define	EAI_FAIL	4

int
__xnet_getaddrinfo(const char *node, const char *service, const void *hints,
    void **res)
{
	(void) node; (void) service; (void) hints;
	if (res != 0)
		*res = 0;
	return (EAI_FAIL);
}

/*
 * ---------------------------------------------------------------------------
 * [ENOSYS] __tls_get_addr -- dynamic-TLS address resolver.
 *
 * NOT in the twelve-symbol list of docs/cosmic-riscv64-feasibility.md §1.4;
 * found by nm on the riscv64 std/proc_macro rlibs. It stayed hidden because on
 * a Linux cross host glibc's ld-linux-riscv64-lp64d.so.1 supplies it, so the
 * study's link resolved it silently. On illumos OUR ld.so.1 must.
 *
 * This one ABORTS rather than returning a value, on purpose. Every other entry
 * in this file can fail into a caller that checks a return code; a TLS resolver
 * cannot. Returning any address at all -- NULL included -- hands out storage
 * that thread-local reads and writes will then use, corrupting state silently
 * and arbitrarily far from here. An immediate, loud stop is the only honest
 * behaviour until ld.so.1 grows a DTV and TLS relocation support.
 * ---------------------------------------------------------------------------
 */
extern void _exit(int);

void *
__tls_get_addr(void *ti)
{
	static const char msg[] =
	    "libc: __tls_get_addr called but dynamic TLS is not implemented "
	    "(ld.so.1 has no DTV); see docs/riscv64-libc-rust-abi-gap.md\n";

	(void) ti;
	(void) write(2, msg, sizeof (msg) - 1);
	_exit(127);
	/* NOTREACHED */
	return (0);
}
