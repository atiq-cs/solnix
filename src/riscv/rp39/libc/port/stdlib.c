/*
 * stdlib.c -- solnix riscv64 libc: heap (malloc/free/realloc/calloc via SYS_brk
 * sbrk), the process environment (getenv), and process teardown (exit + atexit
 * running the registered hooks and flushing stdio).
 *
 * CRIB PROVENANCE: sbrk-backed bump allocation with a first-fit free list is
 * the classic K&R storage allocator shape (a coalescing-free bump heap); getenv
 * scans the environ vector the RISC-V psABI initial stack hands crt1; exit runs
 * the atexit chain LIFO then flushes stdio then traps _exit -- the C89 exit
 * contract (illumos libc exit()/atexit()).
 */
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/systrap.h>

/* the environment vector, captured by crt1 -> __libc_start. */
char **environ;

/* --- sbrk over SYS_brk: brk(addr) grows/queries the break, returns it. --- */
static char *__brk_cur;

void *
sbrk(long incr)
{
	long old, nw;
	if (__brk_cur == 0)
		__brk_cur = (char *)__systrap1(SYS_brk, 0);	/* query */
	old = (long)__brk_cur;
	if (incr == 0)
		return ((void *)old);
	nw = (long)__systrap1(SYS_brk, old + incr);
	if (nw < 0 || nw < old + incr)
		return ((void *)-1);
	__brk_cur = (char *)nw;
	return ((void *)old);
}

/*
 * A minimal first-fit heap.  Each block has an 8-byte header holding its
 * usable payload size and a free flag; malloc walks the list for a fit, else
 * grows the heap via sbrk.  free() marks the block free and coalesces with the
 * immediately following block.  This is a first-fit, forward-only-coalesce,
 * O(n)-walk allocator; size-binned free lists would replace it if allocation
 * churn ever matters.
 */
typedef struct blk {
	size_t		size;		/* payload bytes */
	int		free;
	struct blk	*next;
} blk_t;

#define HDR sizeof(blk_t)
#define ALIGN(n) (((n) + 15) & ~((size_t)15))

static blk_t *__heap_head;

static blk_t *
__grow(size_t need)
{
	size_t want = ALIGN(need + HDR);
	blk_t *b = sbrk((long)want);
	if ((void *)b == (void *)-1)
		return ((void *)0);
	b->size = want - HDR;
	b->free = 0;
	b->next = (void *)0;
	return (b);
}

void *
malloc(size_t n)
{
	blk_t *b, *last = (void *)0;
	if (n == 0)
		n = 1;
	n = ALIGN(n);
	for (b = __heap_head; b != (void *)0; last = b, b = b->next) {
		if (b->free && b->size >= n) {
			b->free = 0;
			return ((char *)b + HDR);
		}
	}
	b = __grow(n);
	if (b == (void *)0)
		return ((void *)0);
	if (last == (void *)0)
		__heap_head = b;
	else
		last->next = b;
	return ((char *)b + HDR);
}

void
free(void *p)
{
	blk_t *b, *n;
	if (p == (void *)0)
		return;
	b = (blk_t *)((char *)p - HDR);
	b->free = 1;
	/* forward coalesce with an adjacent free block. */
	n = b->next;
	if (n != (void *)0 && n->free) {
		b->size += HDR + n->size;
		b->next = n->next;
	}
}

void *
calloc(size_t nmemb, size_t sz)
{
	size_t t = nmemb * sz;
	void *p;
	if (nmemb != 0 && t / nmemb != sz)	/* overflow */
		return ((void *)0);
	p = malloc(t);
	if (p != (void *)0)
		memset(p, 0, t);
	return (p);
}

void *
realloc(void *p, size_t n)
{
	blk_t *b;
	void *np;
	if (p == (void *)0)
		return (malloc(n));
	b = (blk_t *)((char *)p - HDR);
	if (b->size >= ALIGN(n))
		return (p);
	np = malloc(n);
	if (np != (void *)0) {
		memcpy(np, p, b->size);
		free(p);
	}
	return (np);
}

/* --- environment --- */
char *
getenv(const char *name)
{
	size_t nl = strlen(name);
	char **e = environ;
	if (e == (void *)0)
		return ((void *)0);
	for (; *e; e++) {
		if (strncmp(*e, name, nl) == 0 && (*e)[nl] == '=')
			return (*e + nl + 1);
	}
	return ((void *)0);
}

/* --- exit / atexit --- */
#define MAXATEXIT 32
static void (*__atexit_fns[MAXATEXIT])(void);
static int __atexit_n;

int
atexit(void (*fn)(void))
{
	if (__atexit_n >= MAXATEXIT)
		return (-1);
	__atexit_fns[__atexit_n++] = fn;
	return (0);
}

void
exit(int status)
{
	int i;
	for (i = __atexit_n - 1; i >= 0; i--)	/* LIFO, C89 */
		__atexit_fns[i]();
	__stdio_flush_all();
	_exit(status);
}

void
abort(void)
{
	_exit(134);				/* 128 + SIGABRT(6) */
}

/* --- small numeric parsers --- */
long
strtol(const char *s, char **endp, int base)
{
	long v = 0;
	int neg = 0;
	while (*s == ' ' || *s == '\t' || *s == '\n')
		s++;
	if (*s == '+' || *s == '-')
		neg = (*s++ == '-');
	if ((base == 0 || base == 16) && s[0] == '0' &&
	    (s[1] == 'x' || s[1] == 'X')) {
		s += 2;
		base = 16;
	} else if (base == 0) {
		base = (s[0] == '0') ? 8 : 10;
	}
	for (;;) {
		int d;
		char c = *s;
		if (c >= '0' && c <= '9')
			d = c - '0';
		else if (c >= 'a' && c <= 'z')
			d = c - 'a' + 10;
		else if (c >= 'A' && c <= 'Z')
			d = c - 'A' + 10;
		else
			break;
		if (d >= base)
			break;
		v = v * base + d;
		s++;
	}
	if (endp != (void *)0)
		*endp = (char *)s;
	return (neg ? -v : v);
}

int  atoi(const char *s) { return ((int)strtol(s, (void *)0, 10)); }
long atol(const char *s) { return (strtol(s, (void *)0, 10)); }
