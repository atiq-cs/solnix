/*
 * brktest.c -- deterministic regression test for the brk shrink/regrow bug.
 * Grow the break by 4 pages, fill them, shrink by 4 pages, grow again, write a
 * pattern, then sleep (the switch away and back flushes this hart's TLB) and
 * read the pattern back. On the broken kernel the regrow
 * mapped fresh pages over the still-valid old ones without a TLB flush, so the
 * writes went to the old pages and the read after the flush sees zeros. Also
 * checks that a brk below the initial break is refused.
 *   prints BRKTEST PASS or BRKTEST FAIL <why>
 */
#include <stdio.h>
#include <unistd.h>

#define	PG	4096
#define	NPG	4

int
main(void)
{
	char *cur = sbrk(0), *base, *a, *b;
	unsigned long i, bad = 0;

	/* page-align the break first so the 4 pages are wholly ours */
	base = (char *)(((unsigned long)cur + PG - 1) & ~(unsigned long)(PG - 1));
	if (base != cur && sbrk(base - cur) == (void *)-1) {
		printf("BRKTEST FAIL align\n");
		return (1);
	}
	if (sbrk(NPG * PG) != base) {
		printf("BRKTEST FAIL grow1\n");
		return (1);
	}
	a = base;
	for (i = 0; i < NPG * PG; i++)
		a[i] = 0x5a;
	if (sbrk(-NPG * PG) == (void *)-1 || sbrk(0) != base) {
		printf("BRKTEST FAIL shrink\n");
		return (1);
	}
	if (sbrk(NPG * PG) != base) {
		printf("BRKTEST FAIL grow2\n");
		return (1);
	}
	b = base;
	for (i = 0; i < NPG * PG; i++)
		b[i] = (char)(i * 7 + 1);
	(void) usleep(30000);	/* block: the switch away flushes the TLB */
	for (i = 0; i < NPG * PG; i++)
		if (b[i] != (char)(i * 7 + 1))
			bad++;
	if (bad != 0) {
		printf("BRKTEST FAIL %lu of %d bytes lost after a TLB flush "
		    "(b[0]=0x%x)\n", bad, NPG * PG, (unsigned char)b[0]);
		return (1);
	}
	if (sbrk(-(long)(base - (char *)0x40010000)) != (void *)-1) {
		printf("BRKTEST FAIL brk below the initial break accepted\n");
		return (1);
	}
	printf("BRKTEST PASS\n");
	return (0);
}
