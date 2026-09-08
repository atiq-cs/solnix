/*
 * newlibtest.c -- the first solnix riscv64 program built against a REAL libc.
 *
 * Every other program in this userland links user/libc.c, a hand-written slice
 * whose printf understands only %d/%u/%x/%s. This one links newlib 4.5.0's
 * libc.a -- genuine upstream code -- through the OS port in newlib_glue.c. The
 * question it answers is the one the project could not previously answer: is the
 * solnix riscv64 kernel's syscall surface adequate for a libc that was NOT
 * written to its limitations?
 *
 * The checks below are chosen so that PASSING IS ONLY POSSIBLE WITH A REAL LIBC:
 *
 *   1. "%ld" of a value larger than 32 bits. user/libc.c does not implement
 *      the `l` length modifier at all, so a toy-libc build cannot print this
 *      correctly. This is the provenance check in executable form.
 *   2. malloc/free of several blocks, written and read back. Exercises newlib's
 *      real _malloc_r (dlmalloc family) over _sbrk over the kernel's brk(2).
 *   3. snprintf into a bounded buffer, with the return value checked. Real
 *      stdio, real formatting engine.
 *   4. strtol + qsort: two ordinary libc routines nothing in this tree
 *      implements. If they run, the archive really is newlib.
 *   5. "%.3f" of a double. Pulls newlib's floating-point vfprintf path, which
 *      is hard-float (lp64d) code -- so this also exercises the kernel's FP
 *      context switch from inside a real libc.
 *
 * Each check sets a bit in `fails` rather than returning early, so one boot
 * reports EVERY broken facility instead of only the first.
 *
 * VERDICT LINE: prints "NEWLIBTEST PASS" only if every check passed, else
 * "NEWLIBTEST FAIL" plus which check failed. init runs this as a boot gate.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int
cmp_int(const void *a, const void *b)
{
	int x = *(const int *)a, y = *(const int *)b;

	return ((x > y) - (x < y));
}

int
main(int argc, char **argv)
{
	int fails = 0;
	char buf[64];

	printf("[newlibtest] start: argc=%d argv[0]=%s\n", argc,
	    (argc > 0 && argv[0] != NULL) ? argv[0] : "(none)");

	/*
	 * 1. The provenance check. 1234567890123 needs %ld; the toy libc has no
	 * `l` modifier, so a mis-linked build cannot produce this string.
	 */
	{
		long v = 1234567890123L;

		(void) snprintf(buf, sizeof (buf), "%ld", v);
		if (strcmp(buf, "1234567890123") != 0) {
			printf("[newlibtest] FAIL 1: %%ld gave \"%s\"\n", buf);
			fails |= 1;
		} else {
			printf("[newlibtest] ok 1: %%ld = %s (real libc)\n", buf);
		}
	}

	/*
	 * 2. Real malloc over the kernel's brk(2). Three separate blocks, each
	 * filled with a distinct pattern and verified after the others are
	 * allocated -- so an allocator handing out overlapping memory fails here
	 * rather than silently corrupting.
	 */
	{
		char *a = malloc(1000);
		char *b = malloc(2000);
		char *c = malloc(4000);

		if (a == NULL || b == NULL || c == NULL) {
			printf("[newlibtest] FAIL 2: malloc returned NULL "
			    "(a=%p b=%p c=%p)\n", (void *)a, (void *)b,
			    (void *)c);
			fails |= 2;
		} else {
			memset(a, 0xA1, 1000);
			memset(b, 0xB2, 2000);
			memset(c, 0xC3, 4000);
			if ((unsigned char)a[999] != 0xA1 ||
			    (unsigned char)b[1999] != 0xB2 ||
			    (unsigned char)c[3999] != 0xC3) {
				printf("[newlibtest] FAIL 2: heap readback "
				    "mismatch\n");
				fails |= 2;
			} else {
				printf("[newlibtest] ok 2: malloc 1000+2000+"
				    "4000 verified, brk heap at %p\n",
				    (void *)a);
			}
			free(b);
			free(a);
			free(c);
		}
	}

	/*
	 * 3. snprintf return value + formatting. "sol-42-ff" is 9 characters
	 * (3 + 1 + 2 + 1 + 2), and snprintf returns the length it would have
	 * written, so n must be 9.
	 */
	{
		int n = snprintf(buf, sizeof (buf), "%s-%d-%x", "sol", 42, 255);

		if (n != 9 || strcmp(buf, "sol-42-ff") != 0) {
			printf("[newlibtest] FAIL 3: snprintf n=%d buf=\"%s\"\n",
			    n, buf);
			fails |= 4;
		} else {
			printf("[newlibtest] ok 3: snprintf -> \"%s\" (n=%d)\n",
			    buf, n);
		}
	}

	/* 4. strtol + qsort: routines that exist ONLY in a real libc here. */
	{
		int v[5] = { 42, 7, 99, 1, 23 };
		long parsed = strtol("  -12345xyz", NULL, 10);

		qsort(v, 5, sizeof (int), cmp_int);
		if (parsed != -12345) {
			printf("[newlibtest] FAIL 4: strtol gave %ld\n", parsed);
			fails |= 8;
		} else if (v[0] != 1 || v[1] != 7 || v[2] != 23 ||
		    v[3] != 42 || v[4] != 99) {
			printf("[newlibtest] FAIL 4: qsort gave %d %d %d %d %d\n",
			    v[0], v[1], v[2], v[3], v[4]);
			fails |= 8;
		} else {
			printf("[newlibtest] ok 4: strtol=%ld qsort=%d,%d,%d,"
			    "%d,%d\n", parsed, v[0], v[1], v[2], v[3], v[4]);
		}
	}

	/*
	 * 5. Double formatting. This is newlib's hard-float vfprintf path, so it
	 * is simultaneously a real-libc check and an FP-state check taken from
	 * inside library code rather than from hand-written asm.
	 */
	{
		double d = 3.14159265358979;

		(void) snprintf(buf, sizeof (buf), "%.3f", d);
		if (strcmp(buf, "3.142") != 0) {
			printf("[newlibtest] FAIL 5: %%.3f gave \"%s\"\n", buf);
			fails |= 16;
		} else {
			printf("[newlibtest] ok 5: %%.3f = %s (hard-float "
			    "libc)\n", buf);
		}
	}

	if (fails == 0)
		printf("NEWLIBTEST PASS: real newlib libc.a on the solnix "
		    "riscv64 kernel\n");
	else
		printf("NEWLIBTEST FAIL: check mask 0x%x\n", fails);

	fflush(stdout);
	return (fails == 0 ? 0 : 1);
}
