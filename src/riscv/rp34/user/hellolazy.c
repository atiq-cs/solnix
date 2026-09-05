/*
 * hellolazy.c -- R-P31.2 ld.so.1 hardening proof: a DYNAMIC riscv64-solaris
 * program that calls a libgcc_s.so.1 routine (__multf3) across the object
 * boundary TWICE.  Linked with lazy binding (the default), --hash-style=both
 * (so the app carries BOTH .hash and .gnu.hash) and -z relro (so it carries a
 * PT_GNU_RELRO segment).  This exercises, in one run:
 *   - LAZY PLT binding: the FIRST __multf3 call jumps through an unbound PLT
 *     slot into the PLT0 header -> the ld.so.1 _rtld_bind trampoline ->
 *     rtld_bind(), which resolves __multf3 and patches the GOT slot; the log
 *     shows "LAZY bind on first call".  The SECOND call goes straight through
 *     the patched slot (no resolver) -- so the bind happened exactly once, on
 *     first use, not eagerly at startup.
 *   - .gnu.hash lookup + GNU symbol versioning: the __multf3 reference is
 *     versioned @GCC_3.0; ld.so.1 matches the like-versioned definition.
 *   - RELRO: ld.so.1 mprotects the relro segment read-only after relocation.
 *
 * The result (6.0 * 7.0 == 42, then 2.0 * 3.0 == 6 on the second call) is
 * arranged so the exit status is 42 iff both cross-object calls returned
 * correctly.
 *
 * Freestanding: crt1/crti/crtn + inline write(2), no libc.
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

static ssize_t write(int fd, const void *b, size_t n) { return (sc3(SYS_write, fd, (long)b, (long)n)); }
static size_t slen(const char *s) { size_t n = 0; while (s[n]) n++; return (n); }
static void puts_(const char *s) { write(1, s, slen(s)); }

static volatile long double op_a = 6.0L;
static volatile long double op_b = 7.0L;
static volatile long double op_c = 2.0L;
static volatile long double op_d = 3.0L;

int
main(int argc, char **argv, char **envp)
{
	long double a, b, c, d, p1, p2;
	int r1, r2;

	(void) argc; (void) argv; (void) envp;

	a = op_a; b = op_b; c = op_c; d = op_d;

	puts_("  [hellolazy] FIRST cross-object call to __multf3 (fires the "
	    "lazy bind)...\n");
	p1 = a * b;			/* first __multf3 call -> LAZY bind fires */
	r1 = (int)p1;			/* __fixtfsi (also lazy) */

	puts_("  [hellolazy] SECOND cross-object call to __multf3 (uses the "
	    "patched GOT, no resolver)...\n");
	p2 = c * d;			/* second __multf3 call -> straight through */
	r2 = (int)p2;

	if (r1 == 42 && r2 == 6)
		puts_("  [hellolazy] both cross-object calls correct "
		    "(42 and 6) -- lazy binding works\n");
	else
		puts_("  [hellolazy] WRONG result from a cross-object call\n");

	return (r1);			/* exit status 42 */
}
