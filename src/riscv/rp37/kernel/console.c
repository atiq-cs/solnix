/*
 * console.c -- R-P37.1/.2: a console tty driver + canonical line discipline over
 * the qemu-virt ns16550 UART (0x10000000), feeding read(2) on fd 0 so the shell
 * reads interactively.  The R-P36 shell read its stdin from a ramfs script
 * (/etc/rc dup2'd onto fd 0); R-P37 makes fd-0 reads come from the LIVE console.
 *
 * TWO entry points drain the UART:
 *   - console_poll(), called from the timer tick (a polled stand-in for an RX
 *     interrupt): drains every ready UART byte into a small input ring, and acts
 *     on control chars IMMEDIATELY -- ^C raises SIGINT and ^Z raises SIGTSTP on
 *     the tty foreground process group EVEN WHEN NO read(2) IS PENDING (the
 *     running fg command is spinning, the shell is blocked in wait()).  This is
 *     the tty driver's l_rint / ttyinput path running off the RX interrupt.
 *   - console_read(), the fd-0 read(2) backend: assembles ONE canonical line
 *     from the ring (echo, backspace erase, CR->NL, ^D EOF), blocking (yielding
 *     the hart) until a whole line is available.
 *
 * qemu -nographic wires the same UART OpenSBI uses to its stdio; OpenSBI owns
 * the UART and drains the RX itself, so we read input via the SBI legacy console
 * getchar (sbi_console_getchar, EID 0x02) rather than the ns16550 RBR directly.
 *
 * CRIB PROVENANCE: the canonical line discipline (echo, erase, ^C->intr,
 * ^D->EOF, line-buffer until NL) + a raw input ring drained by the RX interrupt
 * is the xv6 console.c consoleintr()/consoleread() + BSD tty.c ttyinput()/ttread()
 * cooked mode + illumos ldterm STREAMS module (ldterm_rmsg / ldterm_dosig raising
 * SIGINT/SIGTSTP on the tty t_pgrp).  Console input via the SBI legacy getchar
 * (EID 0x02) is the RISC-V SBI spec + the OpenSBI sbi_getc console path.
 * Signalling the tty foreground process group on ^C/^Z is the illumos/BSD
 * t_pgrp job-control model.
 */

#include "sbi.h"
#include "mmu_riscv.h"

/* ns16550 UART0 on qemu-virt (unused for RX: OpenSBI owns it; kept for ref). */
#define	UART0_PHYS	0x10000000UL

/* raw input ring: control chars are consumed by the poll; the rest queue here. */
#define	CBUF	256
static volatile unsigned char cq[CBUF];
static volatile unsigned int cq_r, cq_w;	/* read / write cursors */

static void
cq_push(unsigned char c)
{
	unsigned int nw = (cq_w + 1) % CBUF;
	if (nw == cq_r)
		return;			/* ring full: drop (line too long) */
	cq[cq_w] = c;
	cq_w = nw;
}
static int
cq_pop(void)
{
	unsigned char c;
	if (cq_r == cq_w)
		return (-1);
	c = cq[cq_r];
	cq_r = (cq_r + 1) % CBUF;
	return ((int)c);
}

/* proc.c hooks: yield the hart while waiting; signal the tty fg pgrp. */
extern void proc_yield(void);
extern int proc_tty_signal_fg(int sig);	/* SIGINT/SIGTSTP -> fg pgrp; count sent */

/* SunOS signal numbers used by the line discipline. */
#define	SIGINT		2
#define	SIGTSTP		24

static void console_echo(int c);	/* fwd: used by console_poll */

/*
 * console_poll -- drain the UART (called from the timer tick).  Control chars
 * (^C/^Z) act on the tty foreground process group immediately; ^D and printable
 * bytes queue in the ring for console_read to cook.  Returns nothing.
 */
void
console_poll(void)
{
	static volatile int poll_lock;
	int ci, prev;
	/*
	 * Single-drainer: the timer tick (either hart) and console_read both call
	 * this; a test-and-set keeps two harts from racing on the ring cursor /
	 * double-reading the SBI console.  Non-blocking -- if another hart is
	 * draining, just skip (it will get the bytes).
	 */
	__asm__ __volatile__("amoswap.w.aq %0, %2, %1"
	    : "=r"(prev), "+A"(poll_lock) : "r"(1) : "memory");
	if (prev != 0)
		return;
	while ((ci = sbi_console_getchar()) >= 0) {
		unsigned char c = (unsigned char)ci;
		if (c == 0x03) {		/* ^C: interrupt the fg pgrp NOW */
			console_echo('^'); console_echo('C'); console_echo('\n');
			(void) proc_tty_signal_fg(SIGINT);
			continue;
		}
		if (c == 0x1a) {		/* ^Z: stop the fg pgrp NOW */
			console_echo('^'); console_echo('Z'); console_echo('\n');
			(void) proc_tty_signal_fg(SIGTSTP);
			continue;
		}
		cq_push(c);
	}
	__asm__ __volatile__("amoswap.w.rl zero, zero, %0"
	    : "+A"(poll_lock) :: "memory");
}

/* echo one byte back to the console (lock-free: safe from the tick). */
static void
console_echo(int c)
{
	if (c == '\n') {
		sbi_console_putchar('\r');
		sbi_console_putchar('\n');
	} else {
		sbi_console_putchar((int)(unsigned char)c);
	}
}

/*
 * console_read -- the fd-0 read(2) backend (canonical mode).  Assemble one line
 * (up to `n` bytes) from the input ring, blocking (cooperatively yielding the
 * hart) until a line-terminating NL or EOF.  Returns the byte count (0 = EOF via
 * ^D at line start), including the terminating '\n' (canonical-tty read(2)).
 */
long
console_read(char *ubuf, unsigned long n)
{
	unsigned long len = 0;

	if (n == 0)
		return (0);
	for (;;) {
		int c = cq_pop();
		if (c < 0) {
			/*
			 * ring empty.  Drain the console ourselves (console_poll):
			 * the read loop spins IN THE KERNEL, where the timer
			 * interrupt that would otherwise run console_poll is masked,
			 * so we must poll the SBI console directly here.  Then yield
			 * the hart so the peer hart / other procs run.
			 */
			console_poll();
			if (cq_r == cq_w) {	/* still nothing queued */
				proc_yield();
				continue;
			}
			continue;		/* something arrived: pop it */
		}
		if (c == '\r')
			c = '\n';		/* icrnl */

		if (c == 0x7f || c == 0x08) {	/* DEL / backspace: erase */
			if (len > 0) {
				len--;
				sbi_console_putchar('\b');
				sbi_console_putchar(' ');
				sbi_console_putchar('\b');
			}
			continue;
		}
		if (c == 0x04) {		/* ^D: EOF (line-start) / flush */
			return ((long)len);	/* 0 at line start = EOF */
		}

		console_echo(c);
		if (len < n)
			ubuf[len++] = (char)c;
		if (c == '\n')
			return ((long)len);	/* canonical line complete */
		if (len >= n)
			return ((long)len);	/* buffer full: short line */
	}
}
