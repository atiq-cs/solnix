/*
 * syscall.c — illumos riscv64 U-mode syscall path (R-P7).
 *
 * The crux of R-P7: when a userland process executes `ecall` in U-mode the
 * hardware traps to S-mode with scause=8 (EXC_ECALL_U). trap() routes that to
 * syscall_trap() here with the saved user frame. The RISC-V syscall ABI we use
 * (the standard Linux/BSD riscv convention, which our hand-built userland
 * follows):
 *
 *   a7 = syscall number
 *   a0..a5 = arguments
 *   ecall
 *   a0 = return value (negative = -errno)
 *   sepc must be advanced past the 4-byte ecall so we return to the next insn.
 *
 * Because usermode_entry set sstatus.SUM=1, the kernel may dereference user
 * pointers directly while the process address space is loaded (it still is:
 * we trapped from U-mode, satp is the process root, the kernel gigapages are
 * mapped in it). No copyin/copyout bounce buffer yet — that (with fault-safe
 * access) is the R-P8 hardening.
 *
 * Syscalls implemented (a minimal illumos-flavored set):
 *   SYS_exit  (1)  a0=status         -> terminate the process
 *   SYS_read  (3)  a0=fd,a1=buf,a2=n -> read from console (fd 0), blocking
 *   SYS_write (4)  a0=fd,a1=buf,a2=n -> write to console (fd 1/2)
 *
 * NOTE: no per-process fd table (fd is hardcoded 0=console-in, 1/2=console-
 * out), no copyin/copyout fault handling, no signal delivery. These are the
 * three syscalls a first interactive init/shell needs; open/close/fork/exec as
 * syscalls are R-P8. The syscall NUMBERS match the riscv Linux ABI subset so a
 * standard freestanding userland stub links unchanged.
 */

#include "sbi.h"
#include "riscv_regs.h"
#include "regs.h"

/* uart.c: polled console input. */
extern int uart_getc(void);

/* proc.c: terminate the current userland process (does not return). */
extern void proc_exit(int status) __attribute__((noreturn));

/* Riscv Linux-ABI subset numbers our userland stub uses. */
#define	SYS_exit	93
#define	SYS_read	63
#define	SYS_write	64

/*
 * sys_write — write `n` bytes of the user buffer to the console (fd 1 = stdout,
 * 2 = stderr; anything else is rejected). SUM=1 lets us read the user buffer
 * directly. Uses the SBI console path (proven from any address space). Returns
 * bytes written.
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
 * sys_read — read up to `n` bytes from the console (fd 0 = stdin) into the user
 * buffer, blocking for at least one byte. Line discipline is raw with a light
 * cooked touch: we echo each byte (so the user sees what they type) and stop at
 * a newline (\n or \r, translated to \n). Returns bytes read.
 */
static long
sys_read(int fd, char *ubuf, unsigned long n)
{
	unsigned long i = 0;

	if (fd != 0)
		return (-1);
	if (ubuf == 0 || n == 0)
		return (-1);

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
 * the instruction after it.
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
