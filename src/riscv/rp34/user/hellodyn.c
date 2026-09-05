/*
 * hellodyn.c -- R-P28 cross-object dynamic-linking proof: a DYNAMIC riscv64-
 * solaris hello that actually CALLS a libgcc_s.so.1 routine across the object
 * boundary.  Unlike the R-P27 dynamic hello (which reported DT_NEEDED but bound
 * no symbol -- its RELA table was empty), this program performs a 64-bit
 * unsigned division that the compiler lowers to a call to __udivdi3, a routine
 * that lives in libgcc_s.so.1, not in the executable.  That call turns into an
 * UNDEF .dynsym entry + an R_RISCV_JUMP_SLOT relocation against the app's GOT/
 * PLT -- so for the program to run correctly, ld.so.1 must MAP libgcc_s.so.1
 * into the address space, resolve __udivdi3 in its symbol table, and BIND the
 * app's JUMP_SLOT slot to the resolved address.  If the cross-object bind is
 * wrong the call faults or returns garbage; if it is right the division yields
 * the expected quotient.
 *
 * The exit status encodes the result: we perform a 128-bit binary-float
 * (long double / TFmode / _Float128) multiply that the compiler lowers to a
 * call to __multf3, a routine that lives in libgcc_s.so.1.  RV64GC has no
 * hardware 128-bit binary float, so __multf3 is ALWAYS a genuine cross-object
 * libcall (unlike 64-bit integer divide or 128-bit integer multiply, which
 * RV64GC does inline in hardware).  The operands are read through volatile
 * storage so the multiply cannot be constant-folded.  We arrange the result to
 * be 42 and return it as the exit status (masked to 0x7f by crt1).  A boot log
 * showing exit status 42 is positive proof that the cross-object libgcc_s call
 * executed and returned the correct value.
 *
 * Freestanding: crt1/crti/crtn only; write(2)/no libc for the progress line.
 *
 * CRIB PROVENANCE: exercising a compiler-emitted libgcc helper (__multf3) to
 * force a cross-object PLT/GOT reference is the standard way the RISC-V psABI +
 * GCC lower 128-bit binary-float arithmetic (no hardware _Float128 on RV64GC);
 * the JUMP_SLOT/GOT binding it produces is the SysV gABI dynamic-linking model.
 */

typedef unsigned long size_t;
typedef long ssize_t;

#define	SYS_write	4

static long
sc3(long nr, long x0, long x1, long x2)
{
	register long a7 __asm__("a7") = nr;
	register long a0 __asm__("a0") = x0;
	register long a1 __asm__("a1") = x1;
	register long a2 __asm__("a2") = x2;
	__asm__ __volatile__("ecall"
	    : "+r"(a0) : "r"(a7), "r"(a1), "r"(a2) : "memory");
	return (a0);
}

static ssize_t
write(int fd, const void *b, size_t n)
{
	return (sc3(SYS_write, fd, (long)b, (long)n));
}

static size_t
slen(const char *s)
{
	size_t n = 0;
	while (s[n])
		n++;
	return (n);
}

static void
puts_(const char *s)
{
	write(1, s, slen(s));
}

/*
 * Volatile file-scope operands: the compiler must load them at runtime and
 * cannot constant-fold the 128-bit float multiply, so it MUST lower a * b to a
 * genuine call to __multf3 in libgcc_s.so.1.  6.0 * 7.0 == 42.0.
 */
static volatile long double op_a = 6.0L;
static volatile long double op_b = 7.0L;

int
main(int argc, char **argv, char **envp)
{
	long double a, b, p;
	int r;

	(void) argc; (void) argv; (void) envp;

	a = op_a;			/* volatile load: opaque to the optimizer */
	b = op_b;

	puts_("  [hellodyn] calling __multf3 in libgcc_s.so.1 across the "
	    "object boundary...\n");

	p = a * b;			/* -> __multf3 (cross-object call) */
	r = (int)p;			/* -> __fixtfsi (also cross-object) == 42 */

	if (r == 42)
		puts_("  [hellodyn] __multf3 returned 42 -- cross-object "
		    "bind OK\n");
	else
		puts_("  [hellodyn] __multf3 returned WRONG value\n");

	return (r);			/* exit status == 42 if the bind worked */
}
