/*
 * fptest.c -- does a HARD-FLOAT process keep its FP registers across a context
 * switch? Standalone (own _start, inline-asm syscalls, no libc) because the
 * solnix userland libc is built soft-float (-march=rv64imac) and linking a
 * hard-float object against it would be an ABI mix.
 *
 * WHY THIS MATTERS: the Rust riscv64 illumos target is lp64d -- hard float. So
 * is llvmpipe, which is nothing but float. If the kernel does not save/restore
 * f0-f31 across a switch, two concurrent hard-float processes silently corrupt
 * each other's FP state, and a software rasterizer produces garbage rather than
 * an error.
 *
 * Two processes each stamp distinct values into f-registers, spin long enough
 * for the 100 Hz clock to preempt them repeatedly (so the other process runs in
 * between), then read the registers back. If the values survive, the kernel
 * preserves FP state; if they come back as the OTHER process's values (or zero),
 * it does not.
 *
 * RESULT WHEN WRITTEN: FAIL, reproducibly (3/3 boots). The parent reads back
 * xor=0x2222222266666666, which is exactly PAT_PARENT ^ PAT_CHILD -- so the
 * parent found the CHILD's values in its own FP registers. Confirmed by
 * inspection: no fsd/fld instructions anywhere in swtch.S/trap.S and no TF_F*
 * slots in asm_frame.h, while every trap log shows sstatus FS=3 (Dirty) -- the
 * FPU is enabled and accumulating state that nothing preserves. uts/fpu.c exists
 * (imported from n-hys/illumos-gate) but is in no build script. This test is the
 * regression gate for fixing that.
 *
 * HOW TO RUN IT. Deliberately NOT one of build-user.sh's PROGS: the userland libc
 * slice is built soft-float (-march=rv64imac), and the linker correctly refuses
 * to mix double-float and soft-float objects. Build it standalone and drop it
 * into the ustar rootfs as /bin/fptest:
 *   riscv64-none-elf-gcc -march=rv64imafdc_zicsr -mabi=lp64d -mcmodel=medany \
 *       -ffreestanding -nostdlib -fno-stack-protector -fno-pic -O2 \
 *       -c fptest.c -o fptest.o
 *   riscv64-none-elf-ld -T init.ld -o fptest.elf fptest.o
 */

#define	SYS_write	64
#define	SYS_exit	93
#define	SYS_fork	220
#define	SYS_wait4	260
#define	SYS_getpid	172

static long
sys(long n, long a0, long a1, long a2)
{
	register long r_a0 __asm__("a0") = a0;
	register long r_a1 __asm__("a1") = a1;
	register long r_a2 __asm__("a2") = a2;
	register long r_a7 __asm__("a7") = n;

	__asm__ __volatile__("ecall"
	    : "+r"(r_a0) : "r"(r_a1), "r"(r_a2), "r"(r_a7) : "memory");
	return (r_a0);
}

static void
puts_(const char *s)
{
	long n = 0;
	while (s[n] != 0)
		n++;
	(void) sys(SYS_write, 1, (long)s, n);
}

static void
puthex16(unsigned long v)
{
	static const char hx[] = "0123456789abcdef";
	char b[19];
	int i;

	b[0] = '0'; b[1] = 'x';
	for (i = 0; i < 16; i++)
		b[2 + i] = hx[(v >> (60 - 4 * i)) & 0xf];
	b[18] = 0;
	puts_(b);
}

/* Stamp `pat` into f0..f7 as raw bit patterns (fmv.d.x moves integer -> float). */
static void
fp_stamp(unsigned long pat)
{
	__asm__ __volatile__(
	    "fmv.d.x f0, %0\n fmv.d.x f1, %0\n fmv.d.x f2, %0\n fmv.d.x f3, %0\n"
	    "fmv.d.x f4, %0\n fmv.d.x f5, %0\n fmv.d.x f6, %0\n fmv.d.x f7, %0\n"
	    :: "r"(pat) : "f0","f1","f2","f3","f4","f5","f6","f7");
}

/* Read f0..f7 back and OR-in any bit that differs from `pat`: 0 == all intact. */
static unsigned long
fp_diff(unsigned long pat)
{
	unsigned long g0, g1, g2, g3, g4, g5, g6, g7;

	__asm__ __volatile__(
	    "fmv.x.d %0, f0\n fmv.x.d %1, f1\n fmv.x.d %2, f2\n fmv.x.d %3, f3\n"
	    "fmv.x.d %4, f4\n fmv.x.d %5, f5\n fmv.x.d %6, f6\n fmv.x.d %7, f7\n"
	    : "=r"(g0), "=r"(g1), "=r"(g2), "=r"(g3),
	      "=r"(g4), "=r"(g5), "=r"(g6), "=r"(g7));
	return ((g0 ^ pat) | (g1 ^ pat) | (g2 ^ pat) | (g3 ^ pat) |
	    (g4 ^ pat) | (g5 ^ pat) | (g6 ^ pat) | (g7 ^ pat));
}

static void
burn(unsigned long n)
{
	volatile unsigned long i;
	for (i = 0; i < n; i++)
		;
}

#define	PAT_PARENT	0x1111111122222222UL
#define	PAT_CHILD	0x3333333344444444UL

static int
run(unsigned long pat, const char *who)
{
	unsigned long d;
	int round;
	int bad = 0;

	for (round = 0; round < 4; round++) {
		fp_stamp(pat);
		burn(2000000);		/* long enough for several clock ticks */
		d = fp_diff(pat);
		if (d != 0) {
			puts_("  [FAIL] ");
			puts_(who);
			puts_(" FP registers CLOBBERED across a switch, xor=");
			puthex16(d);
			puts_("\n");
			bad++;
			break;
		}
	}
	if (!bad) {
		puts_("  [ok] ");
		puts_(who);
		puts_(" FP registers survived 4 rounds of preemption\n");
	}
	return (bad);
}

void
_start(void)
{
	int pid, bad = 0, st = 0;

	puts_("FPTEST: does hard-float state survive a context switch?\n");

	pid = (int)sys(SYS_fork, 0, 0, 0);
	if (pid == 0) {
		int cbad = run(PAT_CHILD, "child");
		sys(SYS_exit, cbad, 0, 0);
	}

	bad += run(PAT_PARENT, "parent");
	if (pid > 0)
		(void) sys(SYS_wait4, pid, (long)&st, 0);
	if (st != 0)
		bad++;

	if (bad == 0)
		puts_("FPTEST PASS: the kernel preserves f0-f31 per process\n");
	else
		puts_("FPTEST FAIL: hard-float state is NOT preserved -- a "
		    "Rust/lp64d or llvmpipe process would silently corrupt\n");
	sys(SYS_exit, bad == 0 ? 0 : 1, 0, 0);
	for (;;)
		;
}
