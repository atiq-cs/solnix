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

/*
 * Stamp `pat` into ALL of f0..f31 as raw bit patterns (fmv.d.x moves an integer
 * register into a float register without conversion, so the pattern survives
 * bit-for-bit and a corrupted register is unmistakable).
 *
 * All 32 rather than f0-f7: the save/restore path handles the registers in
 * groups, so a bug that drops the upper half -- an off-by-one in the offset
 * arithmetic, or a truncated unrolled sequence -- is invisible if the test only
 * ever writes the low eight.
 */
static void
fp_stamp(unsigned long pat)
{
	__asm__ __volatile__(
	    "fmv.d.x f0, %0\n fmv.d.x f1, %0\n fmv.d.x f2, %0\n fmv.d.x f3, %0\n"
	    "fmv.d.x f4, %0\n fmv.d.x f5, %0\n fmv.d.x f6, %0\n fmv.d.x f7, %0\n"
	    "fmv.d.x f8, %0\n fmv.d.x f9, %0\n fmv.d.x f10,%0\n fmv.d.x f11,%0\n"
	    "fmv.d.x f12,%0\n fmv.d.x f13,%0\n fmv.d.x f14,%0\n fmv.d.x f15,%0\n"
	    "fmv.d.x f16,%0\n fmv.d.x f17,%0\n fmv.d.x f18,%0\n fmv.d.x f19,%0\n"
	    "fmv.d.x f20,%0\n fmv.d.x f21,%0\n fmv.d.x f22,%0\n fmv.d.x f23,%0\n"
	    "fmv.d.x f24,%0\n fmv.d.x f25,%0\n fmv.d.x f26,%0\n fmv.d.x f27,%0\n"
	    "fmv.d.x f28,%0\n fmv.d.x f29,%0\n fmv.d.x f30,%0\n fmv.d.x f31,%0\n"
	    :: "r"(pat) :
	    "f0","f1","f2","f3","f4","f5","f6","f7",
	    "f8","f9","f10","f11","f12","f13","f14","f15",
	    "f16","f17","f18","f19","f20","f21","f22","f23",
	    "f24","f25","f26","f27","f28","f29","f30","f31");
}

/*
 * fcsr is separate state from the register file and is just as capable of
 * leaking between processes, so stamp and check it too. Only the low 8 bits are
 * architecturally defined (5 accrued-exception flags + 3 rounding-mode bits), so
 * mask to those rather than expecting a full word to round-trip.
 */
#define	FCSR_MASK	0xffUL

static void
fcsr_stamp(unsigned long v)
{
	__asm__ __volatile__("fscsr %0" :: "r"(v & FCSR_MASK));
}

static unsigned long
fcsr_read(void)
{
	unsigned long v;

	__asm__ __volatile__("frcsr %0" : "=r"(v));
	return (v & FCSR_MASK);
}

/*
 * Read ALL of f0..f31 back into memory and report both an OR of the differing
 * bits and a bitmap of WHICH registers differed. The bitmap matters: "f19 and
 * f27 are wrong" points at offset arithmetic, whereas "every register is wrong"
 * points at save/restore never running -- two very different bugs that a single
 * boolean cannot distinguish.
 *
 * Spilling to an array rather than to 32 output operands, because 32 simultaneous
 * "=r" constraints exhaust the integer registers and the compiler rejects it.
 */
static unsigned long
fp_readback(unsigned long *out32)
{
	__asm__ __volatile__(
	    "fsd f0,   0(%0)\n fsd f1,   8(%0)\n fsd f2,  16(%0)\n fsd f3,  24(%0)\n"
	    "fsd f4,  32(%0)\n fsd f5,  40(%0)\n fsd f6,  48(%0)\n fsd f7,  56(%0)\n"
	    "fsd f8,  64(%0)\n fsd f9,  72(%0)\n fsd f10, 80(%0)\n fsd f11, 88(%0)\n"
	    "fsd f12, 96(%0)\n fsd f13,104(%0)\n fsd f14,112(%0)\n fsd f15,120(%0)\n"
	    "fsd f16,128(%0)\n fsd f17,136(%0)\n fsd f18,144(%0)\n fsd f19,152(%0)\n"
	    "fsd f20,160(%0)\n fsd f21,168(%0)\n fsd f22,176(%0)\n fsd f23,184(%0)\n"
	    "fsd f24,192(%0)\n fsd f25,200(%0)\n fsd f26,208(%0)\n fsd f27,216(%0)\n"
	    "fsd f28,224(%0)\n fsd f29,232(%0)\n fsd f30,240(%0)\n fsd f31,248(%0)\n"
	    :: "r"(out32) : "memory");
	return (0);
}

/*
 * Compare all 32 against `pat`. Returns the OR of differing bits; *whichp gets a
 * bitmap of the offending register numbers.
 */
static unsigned long
fp_diff_all(unsigned long pat, unsigned long *whichp)
{
	unsigned long regs[32];
	unsigned long diff = 0, which = 0;
	int i;

	(void) fp_readback(regs);
	for (i = 0; i < 32; i++) {
		unsigned long d = regs[i] ^ pat;

		if (d != 0) {
			diff |= d;
			which |= (1UL << i);
		}
	}
	if (whichp != 0)
		*whichp = which;
	return (diff);
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
#define	PAT_CHILD2	0x5555555577777777UL

static int
run(unsigned long pat, const char *who)
{
	unsigned long d, which = 0;
	int round;
	int bad = 0;

	for (round = 0; round < 4; round++) {
		fp_stamp(pat);
	fcsr_stamp(pat);	/* fcsr is separate state and leaks just as well */
		burn(2000000);		/* long enough for several clock ticks */
		d = fp_diff_all(pat, &which);
		if (d != 0) {
			puts_("  [FAIL] ");
			puts_(who);
			puts_(" FP CLOBBERED across a switch, xor=");
			puthex16(d);
			puts_(" regs=");
			puthex16(which);
			puts_("\n");
			bad++;
			break;
		}
		if (fcsr_read() != (pat & FCSR_MASK)) {
			puts_("  [FAIL] ");
			puts_(who);
			puts_(" fcsr CLOBBERED across a switch\n");
			bad++;
			break;
		}
	}
	if (!bad) {
		puts_("  [ok] ");
		puts_(who);
		puts_(" f0-f31 + fcsr survived 4 rounds of preemption\n");
	}
	return (bad);
}

void
_start(void)
{
	int pid, pid2, bad = 0, st = 0;

	puts_("FPTEST: does hard-float state survive a context switch?\n");

	/*
	 * THREE processes, not two. With only a parent and one child, a
	 * save/restore that swaps two contexts by accident still looks correct
	 * from both sides; a third distinct pattern makes that impossible.
	 */
	pid = (int)sys(SYS_fork, 0, 0, 0);
	if (pid == 0) {
		int cbad = run(PAT_CHILD, "child1");
		sys(SYS_exit, cbad, 0, 0);
	}
	pid2 = (int)sys(SYS_fork, 0, 0, 0);
	if (pid2 == 0) {
		int cbad = run(PAT_CHILD2, "child2");
		sys(SYS_exit, cbad, 0, 0);
	}

	bad += run(PAT_PARENT, "parent");
	if (pid > 0)
		(void) sys(SYS_wait4, pid, (long)&st, 0);
	if (st != 0)
		bad++;
	st = 0;
	if (pid2 > 0)
		(void) sys(SYS_wait4, pid2, (long)&st, 0);
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
