/*
 * syscall.c — illumos riscv64 U-mode syscall path (R-P8).
 *
 * When a userland process executes `ecall` in U-mode the hardware traps to
 * S-mode with scause=8 (EXC_ECALL_U). trap() routes that to syscall_trap()
 * here with the saved user frame. The RISC-V syscall ABI (the standard
 * Linux/BSD riscv convention our hand-built userland stub, user/libu.h,
 * follows):
 *
 *   a7 = syscall number
 *   a0..a5 = arguments
 *   ecall
 *   a0 = return value (negative = -errno)
 *   sepc must be advanced past the 4-byte ecall so we return to the next insn.
 *
 * usermode_entry set sstatus.SUM=1, so while the process address space is
 * loaded (it still is: we trapped from U-mode, satp is the process root, the
 * kernel gigapages are mapped in it) the kernel may dereference user pointers
 * directly. No copyin/copyout bounce buffer yet.
 *
 * R-P8 syscall set (a minimal illumos-flavored subset, numbers = riscv Linux
 * ABI so a freestanding stub links unchanged):
 *   getpid (172)   -> current pid
 *   close  (57)    -> close an fd (console fds 0/1/2 are no-ops)
 *   read   (63)    -> fd 0: console (blocking, echo); fd>=3: vfs file
 *   write  (64)    -> fd 1/2: console
 *   exit   (93)    -> terminate the process (proc_exit)
 *   openat (56)    -> open a vfs file by path (dirfd/mode ignored)
 *   getpid (172)   -> current process id\n *   brk    (214)   -> set/query the program break (heap)\n *   fork   (220)   -> duplicate the process (a0=childpid parent / 0 child)\n *   execve (221)   -> replace the AS with a new ELF by path\n *   wait4  (260)   -> reap a ZOMBIE child, return pid + status\n *
 * NOTE: no copyin/copyout fault handling, no signals, argv/envp not plumbed
 * across execve, fd table is 8 slots. These are the syscalls a shell + a couple
 * utils need to be genuinely interactive + multi-process. Upgrade path (R-P9):
 * copyin/out with fault trap, signals, argv/env/auxv, a real vnode fd layer.
 *
 * The compositor set added on top of that: AF_UNIX sockets with SCM_RIGHTS, the
 * /dev/fb scanout ioctl+mmap, poll(2) (73, with poll's flat millisecond timeout
 * rather than ppoll's timespec) and anonymous mmap (MAP_ANON = 0x100, the
 * illumos value).
 */

#include "sbi.h"
#include "riscv_regs.h"
#include "regs.h"

/* uart.c: polled console input. */
extern int uart_getc(void);

/* uproc.c: the R-P8 process model backing the syscalls. */
extern void proc_exit(int status) __attribute__((noreturn));
extern int proc_getpid(void);
extern int proc_signal(int pid, int sig);
extern long proc_open(const char *path);
extern long proc_fread(int fd, char *ubuf, unsigned long n);
extern long proc_close(int fd);
extern int proc_fork(struct regs *tf);
extern int proc_execve(const char *path, char *const argv[],
    char *const envp[]);
extern int proc_waitpid(int pid, int *statusp);
extern long proc_brk(unsigned long newbrk);
extern unsigned long proc_cow_shared(void);
extern unsigned long proc_cow_copied(void);
/* R-P11 signals + creds + writable FS. */
extern long sys_kill(int pid, int sig);
extern long sys_sigaction(int sig, unsigned long handler, unsigned long restorer);
extern long sys_setuid(unsigned int uid);
extern long sys_setgid(unsigned int gid);
extern long sys_getuid(void);
extern void proc_sigreturn(struct regs *tf);
extern void proc_deliver_signals(struct regs *tf);
extern long proc_openat_w(const char *path, int flags);
extern long proc_fwrite(int fd, const char *ubuf, unsigned long n);
extern long proc_lseek(int fd, long off, int whence);
/* R-P12: pipes, dup2, on-disk FS sync/remount. */
extern long proc_pipe(int *ufds);
extern long proc_dup2(int oldfd, int newfd);
extern long sys_sync(void);
extern long sys_remount(void);
/* AF_UNIX sockets (uproc.c: the fd-table half; unixsock.c: the protocol). */
extern long sys_socket(int domain, int type, int protocol);
extern long sys_socketpair(int domain, int type, int protocol, int *ufds);
extern long sys_bind(int fd, unsigned long uaddr, unsigned int ulen);
extern long sys_listen(int fd, int backlog);
extern long sys_accept(int fd, unsigned long uaddr, unsigned long ulenp);
extern long sys_connect(int fd, unsigned long uaddr, unsigned int ulen);
extern long sys_getsockopt(int fd, int level, int name, unsigned long uval,
    unsigned long ulenp);
extern long sys_setsockopt(int fd, int level, int name, unsigned long uval,
    unsigned int ulen);
extern long sys_sendmsg_fds(int fd, const char *ubuf, unsigned long n,
    unsigned long ufds, int nfds);
extern long sys_recvmsg_fds(int fd, char *ubuf, unsigned long n,
    unsigned long ufds, int maxfds, unsigned long unfds_out);
/*
 * The scanout seam (docs/riscv64-scanout-seam.md): ioctl carries the
 * FBIOGMODE/FBIOFLUSH contract and mmap hands the compositor the framebuffer.
 */
extern long proc_ioctl(int fd, int cmd, unsigned long arg);
extern long proc_mmap(int fd, unsigned long len);
extern long proc_mmap_anon(unsigned long len);
/*
 * poll(2) -- what a compositor's main loop is built on (and what calloop, which
 * smithay/smallvil use, sits directly on). uproc.c owns it because readiness is
 * an fd-table question.
 */
extern long proc_poll(unsigned long ufds, int nfds, int timeout);

/* trap.c: clock-tick preemption count (R-P9 gate 5). */
extern volatile unsigned long preempt_count;

/* copy.S: fault-safe user-memory access. Return 0 ok, -1 fault (EFAULT). */
extern long copyin(const void *uaddr, void *kaddr, unsigned long n);
extern long copyout(const void *kaddr, void *uaddr, unsigned long n);

#define	EFAULT	14

/* Riscv Linux-ABI subset numbers our userland stub uses. */
#define	SYS_openat	56
#define	SYS_close	57
#define	SYS_pipe2	59
#define	SYS_dup3	24
#define	SYS_sync	81
#define	SYS_lseek	62
#define	SYS_read	63
#define	SYS_write	64
#define	SYS_ioctl	29
#define	SYS_mmap	222
/*
 * poll(2). The riscv Linux ABI has no plain `poll` slot -- only ppoll (73) --
 * so we take 73 with poll(2)'s ARGUMENT SHAPE (a2 = timeout in milliseconds,
 * negative = block forever) rather than ppoll's timespec + sigmask. That is the
 * same trade already made for sendmsg/recvmsg: keep the kernel entry point the
 * simple flat one and leave the richer POSIX shape to libc, which is where
 * illumos puts it.
 */
#define	SYS_poll	73
/*
 * clock_gettime(2). Needed by anything that measures time in userland -- and a
 * poll timeout is untestable without it: a test that cannot read a clock cannot
 * tell "blocked for 200 ms" from "returned instantly". Only CLOCK_MONOTONIC and
 * CLOCK_REALTIME are answered, both from the same `time` CSR (there is no
 * time-of-day source on this platform yet, so REALTIME is monotonic-since-boot
 * and says so rather than inventing an epoch).
 */
#define	SYS_clock_gettime	113
#define	SYS_exit	93
#define	SYS_kill	129
#define	SYS_rt_sigaction 134
#define	SYS_rt_sigreturn 139
#define	SYS_setgid	144
#define	SYS_setuid	146
#define	SYS_getuid	174
#define	SYS_getpid	172
#define	SYS_brk		214
#define	SYS_fork	220
#define	SYS_execve	221
#define	SYS_wait4	260
/* solnix-private diagnostic: print the kernel COW-fork stats line (R-P9). */
#define	SYS_cowreport	500
/* solnix-private diagnostic: print the clock-preemption count (R-P9 gate 5). */
#define	SYS_preemptreport 501
/* solnix-private: invalidate the block cache + re-mount the on-disk FS. */
#define	SYS_remount	502
/*
 * Event ports. Numbered in the solnix-private range because Linux has no
 * equivalent syscalls to borrow numbers from -- these are illumos-specific, and
 * they are what calloop actually calls on this platform (see uts/port.c).
 */
extern long proc_port_create(void);
extern long proc_port_associate(int pfd, int source, int object, int events,
    unsigned long user);
extern long proc_port_dissociate(int pfd, int source, int object);
extern long proc_port_getn(int pfd, unsigned long ulist, int max,
    unsigned long unp, int timeout);
extern long proc_port_send(int pfd, unsigned long user);

#define	SYS_port_create		510
#define	SYS_port_associate	511
#define	SYS_port_dissociate	512
#define	SYS_port_getn		513
#define	SYS_port_send		514
/*
 * AF_UNIX sockets. The numbers follow the riscv Linux ABI (as every other
 * syscall here does) so a freestanding userland stub links unchanged.
 * sendmsg/recvmsg deliberately take a FLAT fd array rather than a struct msghdr
 * + cmsghdr chain: the cmsghdr walk belongs in libsocket's __xnet_sendmsg, which
 * is where illumos puts it, and keeping it out of the kernel keeps this path
 * small and total. See the sys_sendmsg_fds comment in uproc.c.
 */
#define	SYS_socket	198
#define	SYS_socketpair	199
#define	SYS_bind	200
#define	SYS_listen	201
#define	SYS_accept	202
#define	SYS_connect	203
#define	SYS_getsockopt	209
#define	SYS_setsockopt	208
#define	SYS_sendmsg	211
#define	SYS_recvmsg	212

/*
 * sys_write — write `n` bytes of the user buffer to the console (fd 1 = stdout,
 * 2 = stderr). SUM=1 lets us read the user buffer directly. Uses the SBI
 * console path. Returns bytes written.
 */
static long
sys_write(int fd, const char *ubuf, unsigned long n)
{
	char kb[256];
	unsigned long off = 0;

	if (ubuf == 0)
		return (-EFAULT);
	if (fd >= 3)
		return (proc_fwrite(fd, ubuf, n));	/* writable file (R-P11) */
	if (fd != 1 && fd != 2)
		return (-1);
	/* Bounce the user buffer through the kernel in chunks via fault-safe
	 * copyin. A bad user pointer returns EFAULT instead of panicking. */
	while (off < n) {
		unsigned long chunk = n - off;
		unsigned long i;

		if (chunk > sizeof (kb))
			chunk = sizeof (kb);
		if (copyin(ubuf + off, kb, chunk) != 0)
			return (off > 0 ? (long)off : -EFAULT);
		for (i = 0; i < chunk; i++)
			sbi_console_putchar((unsigned char)kb[i]);
		off += chunk;
	}
	return ((long)n);
}

/*
 * sys_read — fd 0: read from the console (blocking, echo, stop at newline).
 * fd >= 3: read from an open vfs file (proc_fread). Returns bytes read.
 */
static long
sys_read(int fd, char *ubuf, unsigned long n)
{
	unsigned long i = 0;

	if (ubuf == 0 || n == 0)
		return (-EFAULT);

	if (fd >= 3)
		return (proc_fread(fd, ubuf, n));	/* vfs file (copyout inside) */

	if (fd != 0)
		return (-1);

	/* Console: blocking, cooked-lite. Copy each byte out fault-safely so a
	 * bad user buffer returns EFAULT rather than panicking. */
	while (i < n) {
		int c = uart_getc();
		char ch;

		if (c == '\r')
			c = '\n';
		/* R-P11: ^C on the console posts SIGINT to the foreground
		 * (current) process, then returns what we have. */
		if (c == 0x03) {
			sbi_console_puts("^C\n");
			proc_signal(proc_getpid(), 2 /* SIGINT */);
			return (i > 0 ? (long)i : -4 /* EINTR */);
		}
		sbi_console_putchar(c);		/* echo */
		ch = (char)c;
		if (copyout(&ch, ubuf + i, 1) != 0)
			return (i > 0 ? (long)i : -EFAULT);
		i++;
		if (c == '\n')
			break;
	}
	return ((long)i);
}

/*
 * syscall_trap — the ecall-from-U dispatcher. Decode a7, run the syscall, put
 * the result in a0, and advance sepc past the 4-byte ecall so sret returns to
 * the instruction after it. proc_exit / proc_execve do not return here (they
 * enter a new/exited context); fork returns the child pid to the parent here.
 */
void
syscall_trap(struct regs *tf)
{
	unsigned long num = tf->r_a7;
	long ret;

	switch (num) {
	case SYS_write:
		ret = sys_write((int)tf->r_a0, (const char *)tf->r_a1,
		    tf->r_a2);
		break;
	case SYS_read:
		ret = sys_read((int)tf->r_a0, (char *)tf->r_a1, tf->r_a2);
		break;
	case SYS_openat:
		/* a0=dirfd (ignored), a1=path, a2=flags. R-P11: honor write/
		 * create flags against the writable ramfs. */
		ret = proc_openat_w((const char *)tf->r_a1, (int)tf->r_a2);
		break;
	case SYS_lseek:
		ret = proc_lseek((int)tf->r_a0, (long)tf->r_a1, (int)tf->r_a2);
		break;
	case SYS_close:
		ret = proc_close((int)tf->r_a0);
		break;
	case SYS_pipe2:
		/* a0 = int[2] fds; a1 = flags (ignored). */
		ret = proc_pipe((int *)tf->r_a0);
		break;
	case SYS_dup3:
		/* a0 = oldfd, a1 = newfd, a2 = flags (ignored). dup2 semantics. */
		ret = proc_dup2((int)tf->r_a0, (int)tf->r_a1);
		break;
	case SYS_sync:
		ret = sys_sync();
		break;
	case SYS_ioctl:
		/* a0=fd, a1=request, a2=arg (a user pointer the driver
		 * copyin/copyouts). The scanout node's FBIOGMODE/FBIOFLUSH. */
		ret = proc_ioctl((int)tf->r_a0, (int)tf->r_a1, tf->r_a2);
		break;
	case SYS_mmap:
		/*
		 * a0=addr (ignored: the kernel picks the VA), a1=len, a2=prot,
		 * a3=flags, a4=fd, a5=offset.
		 *
		 * Two mappings exist. MAP_ANON gives fresh zeroed private pages
		 * (what Rust std and every allocator want); a real fd maps the
		 * /dev/fb scanout buffer.
		 *
		 * MAP_ANON IS 0x100 ON illumos, not Linux's 0x20. Getting that
		 * wrong is not a theoretical risk: a Rust binary built against
		 * Linux's value already tripped over it here. Both directions of
		 * the mistake are caught -- 0x20 is refused with EINVAL rather
		 * than silently treated as a file mapping of fd 0x20 -- so a
		 * mis-built caller gets a diagnosable error instead of a wild
		 * mapping.
		 */
#define	MAP_ANON_ILLUMOS	0x100
#define	MAP_ANON_LINUX		0x020
		if (tf->r_a3 & MAP_ANON_ILLUMOS) {
			ret = proc_mmap_anon(tf->r_a1);
		} else if (tf->r_a3 & MAP_ANON_LINUX) {
			sbi_console_puts("[mmap] MAP_ANON is 0x100 on illumos, "
			    "not Linux's 0x20 -- refusing\n");
			ret = -22 /* EINVAL */;
		} else if (tf->r_a5 != 0) {
			/*
			 * A file/device mapping at a non-zero offset. Only
			 * /dev/fb is mappable and offset 0 must be pixel (0,0)
			 * per the seam contract, so there is nothing else to map.
			 */
			ret = -22 /* EINVAL */;
		} else {
			ret = proc_mmap((int)tf->r_a4, tf->r_a1);
		}
		break;
	case SYS_port_create:
		ret = proc_port_create();
		break;
	case SYS_port_associate:
		/* a0=port fd, a1=source, a2=object fd, a3=events, a4=user cookie. */
		ret = proc_port_associate((int)tf->r_a0, (int)tf->r_a1,
		    (int)tf->r_a2, (int)tf->r_a3, tf->r_a4);
		break;
	case SYS_port_dissociate:
		ret = proc_port_dissociate((int)tf->r_a0, (int)tf->r_a1,
		    (int)tf->r_a2);
		break;
	case SYS_port_getn:
		/* a0=port fd, a1=port_event[], a2=max, a3=&n, a4=timeout ms. */
		ret = proc_port_getn((int)tf->r_a0, tf->r_a1, (int)tf->r_a2,
		    tf->r_a3, (int)tf->r_a4);
		break;
	case SYS_port_send:
		ret = proc_port_send((int)tf->r_a0, tf->r_a1);
		break;
	case SYS_poll:
		/* a0=struct pollfd *, a1=nfds, a2=timeout in ms (-1 = block). */
		ret = proc_poll(tf->r_a0, (int)tf->r_a1, (int)tf->r_a2);
		break;
	case SYS_clock_gettime: {
		/* a0=clockid, a1=struct timespec * { long tv_sec; long tv_nsec; }. */
		extern unsigned long gethrtime(void);
		unsigned long ns = gethrtime();
		long ts[2];

		if (tf->r_a1 == 0) {
			ret = -EFAULT;
			break;
		}
		/*
		 * CLOCK_REALTIME (0) and CLOCK_MONOTONIC (4, the illumos value)
		 * both answer from the `time` CSR. There is no time-of-day source
		 * on this platform, so REALTIME is monotonic-since-boot: stated
		 * here rather than faked into a plausible-looking epoch, because a
		 * wrong wall clock is harder to notice than an obviously small one.
		 * Any other clockid is refused rather than silently aliased.
		 */
		if (tf->r_a0 != 0 && tf->r_a0 != 4) {
			ret = -22 /* EINVAL */;
			break;
		}
		ts[0] = (long)(ns / 1000000000UL);
		ts[1] = (long)(ns % 1000000000UL);
		ret = (copyout(ts, (void *)tf->r_a1, sizeof (ts)) != 0) ?
		    -EFAULT : 0;
		break;
	}
	case SYS_remount:
		ret = sys_remount();
		break;
	case SYS_socket:
		ret = sys_socket((int)tf->r_a0, (int)tf->r_a1, (int)tf->r_a2);
		break;
	case SYS_socketpair:
		/* a0=domain a1=type a2=protocol a3=int[2] out */
		ret = sys_socketpair((int)tf->r_a0, (int)tf->r_a1,
		    (int)tf->r_a2, (int *)tf->r_a3);
		break;
	case SYS_bind:
		ret = sys_bind((int)tf->r_a0, tf->r_a1, (unsigned int)tf->r_a2);
		break;
	case SYS_listen:
		ret = sys_listen((int)tf->r_a0, (int)tf->r_a1);
		break;
	case SYS_accept:
		ret = sys_accept((int)tf->r_a0, tf->r_a1, tf->r_a2);
		break;
	case SYS_connect:
		ret = sys_connect((int)tf->r_a0, tf->r_a1,
		    (unsigned int)tf->r_a2);
		break;
	case SYS_getsockopt:
		ret = sys_getsockopt((int)tf->r_a0, (int)tf->r_a1,
		    (int)tf->r_a2, tf->r_a3, tf->r_a4);
		break;
	case SYS_setsockopt:
		ret = sys_setsockopt((int)tf->r_a0, (int)tf->r_a1,
		    (int)tf->r_a2, tf->r_a3, (unsigned int)tf->r_a4);
		break;
	case SYS_sendmsg:
		/* a0=fd a1=buf a2=len a3=int* fds a4=nfds (see uproc.c) */
		ret = sys_sendmsg_fds((int)tf->r_a0, (const char *)tf->r_a1,
		    tf->r_a2, tf->r_a3, (int)tf->r_a4);
		break;
	case SYS_recvmsg:
		/* a0=fd a1=buf a2=len a3=int* fds a4=maxfds a5=int* nfds_out */
		ret = sys_recvmsg_fds((int)tf->r_a0, (char *)tf->r_a1,
		    tf->r_a2, tf->r_a3, (int)tf->r_a4, tf->r_a5);
		break;
	case SYS_getpid:
		ret = proc_getpid();
		break;
	case SYS_brk:
		ret = proc_brk(tf->r_a0);
		break;
	case SYS_fork:
		ret = proc_fork(tf);
		break;
	case SYS_execve:
		/* On success proc_execve does NOT return (new image runs).
		 * a0=path, a1=argv, a2=envp (RISC-V ELF ABI). */
		ret = proc_execve((const char *)tf->r_a0,
		    (char *const *)tf->r_a1, (char *const *)tf->r_a2);
		break;
	case SYS_wait4: {
		int status = 0;
		int rpid = proc_waitpid((int)tf->r_a0, &status);
		int *usp = (int *)tf->r_a1;
		if (usp != 0 && rpid > 0) {
			if (copyout(&status, usp, sizeof (status)) != 0) {
				ret = -EFAULT;	/* bad status pointer */
				break;
			}
		}
		ret = rpid;
		break;
	}
	case SYS_exit:
		proc_exit((int)tf->r_a0);	/* does not return */
		/* NOTREACHED */
		ret = 0;
		break;
	case SYS_kill:
		ret = sys_kill((int)tf->r_a0, (int)tf->r_a1);
		break;
	case SYS_rt_sigaction:
		/* a0=sig, a1=handler PC (0=DFL,1=IGN), a2=restorer (libc
		 * sigreturn trampoline VA). */
		ret = sys_sigaction((int)tf->r_a0, tf->r_a1, tf->r_a2);
		break;
	case SYS_rt_sigreturn:
		/* Restore the frame saved at signal delivery and return WITHOUT
		 * advancing sepc or delivering another signal (the restored
		 * frame already has the correct sepc). */
		proc_sigreturn(tf);
		return;
	case SYS_setuid:
		ret = sys_setuid((unsigned int)tf->r_a0);
		break;
	case SYS_setgid:
		ret = sys_setgid((unsigned int)tf->r_a0);
		break;
	case SYS_getuid:
		ret = sys_getuid();
		break;	case SYS_cowreport: {
		extern void kputdec(unsigned long v);
		sbi_console_puts("COW fork OK: ");
		kputdec(proc_cow_shared());
		sbi_console_puts(" pages shared, ");
		kputdec(proc_cow_copied());
		sbi_console_puts(" copied on write\n");
		ret = 0;
		break;
	}
	case SYS_preemptreport: {
		extern void kputdec(unsigned long v);
		if (preempt_count > 0) {
			sbi_console_puts("preempt OK: clock-tick preempted a "
			    "user thread ");
			kputdec(preempt_count);
			sbi_console_puts(" times (timer ISR -> reschedule)\n");
		} else {
			sbi_console_puts("preempt: no preemptions recorded yet\n");
		}
		ret = (long)preempt_count;
		break;
	}
	default:
		sbi_console_puts("[syscall] unknown syscall a7=");
		{
			static const char hx[] = "0123456789abcdef";
			int s;
			sbi_console_puts("0x");
			for (s = 60; s >= 0; s -= 4)
				sbi_console_putchar(hx[(num >> s) & 0xf]);
		}
		sbi_console_puts("\n");
		ret = -1;
		break;
	}

	tf->r_a0 = (unsigned long)ret;
	tf->r_sepc += 4;		/* skip the ecall */

	/* R-P11: deliver any pending signal on the way back to U-mode. This may
	 * redirect tf into a handler, or (for a terminating default) not return.
	 * Runs after sepc is advanced so a caught signal saves the post-ecall PC
	 * and sigreturn resumes at the instruction after the syscall. */
	proc_deliver_signals(tf);
}
