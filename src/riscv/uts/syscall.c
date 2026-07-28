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
 */

#include "sbi.h"
#include "riscv_regs.h"
#include "regs.h"

/* uart.c: polled console input. */
extern int uart_getc(void);

/* uproc.c: the R-P8 process model backing the syscalls. */
extern void proc_exit(int status) __attribute__((noreturn));
extern int proc_getpid(void);
extern long proc_open(const char *path);
extern long proc_fread(int fd, char *ubuf, unsigned long n);
extern long proc_close(int fd);
extern int proc_fork(struct regs *tf);
extern int proc_execve(const char *path);
extern int proc_waitpid(int pid, int *statusp);
extern long proc_brk(unsigned long newbrk);

/* Riscv Linux-ABI subset numbers our userland stub uses. */
#define	SYS_openat	56
#define	SYS_close	57
#define	SYS_read	63
#define	SYS_write	64
#define	SYS_exit	93
#define	SYS_getpid	172
#define	SYS_brk		214
#define	SYS_fork	220
#define	SYS_execve	221
#define	SYS_wait4	260

/*
 * sys_write — write `n` bytes of the user buffer to the console (fd 1 = stdout,
 * 2 = stderr). SUM=1 lets us read the user buffer directly. Uses the SBI
 * console path. Returns bytes written.
 */
static long
sys_write(int fd, const char *ubuf, unsigned long n)
{
	unsigned long i;

	if (fd != 1 && fd != 2)
		return (-1);
	if (ubuf == 0)
		return (-1);
	for (i = 0; i < n; i++)
		sbi_console_putchar((unsigned char)ubuf[i]);
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
		return (-1);

	if (fd >= 3)
		return (proc_fread(fd, ubuf, n));	/* vfs file */

	if (fd != 0)
		return (-1);

	/* Console: blocking, cooked-lite (echo, \r -> \n, stop at newline). */
	while (i < n) {
		int c = uart_getc();

		if (c == '\r')
			c = '\n';
		sbi_console_putchar(c);		/* echo */
		ubuf[i++] = (char)c;
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
		/* a0=dirfd (ignored), a1=path, a2=flags (ignored). */
		ret = proc_open((const char *)tf->r_a1);
		break;
	case SYS_close:
		ret = proc_close((int)tf->r_a0);
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
		/* On success proc_execve does NOT return (new image runs). */
		ret = proc_execve((const char *)tf->r_a0);
		break;
	case SYS_wait4: {
		int status = 0;
		int rpid = proc_waitpid((int)tf->r_a0, &status);
		int *usp = (int *)tf->r_a1;
		if (usp != 0 && rpid > 0)
			*usp = status;
		ret = rpid;
		break;
	}
	case SYS_exit:
		proc_exit((int)tf->r_a0);	/* does not return */
		/* NOTREACHED */
		ret = 0;
		break;
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
}
