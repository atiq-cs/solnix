/*
 * libc.c — solnix riscv64 minimal libc slice (R-P10 gate 2).
 *
 * The IMPLEMENTATION half of libc.h: crt0 (_start), syscall stubs, a bump
 * malloc over brk, a small string set, and a real printf. Archived into
 * libc-riscv.a and linked into /bin/sh + the utilities. Freestanding, static,
 * no host libc. This is the first libc on illumos-RISC-V.
 */
#include "libc.h"

#include <stdarg.h>

long
__sys(long n, long a0, long a1, long a2, long a3)
{
	register long r_a0 asm("a0") = a0;
	register long r_a1 asm("a1") = a1;
	register long r_a2 asm("a2") = a2;
	register long r_a3 asm("a3") = a3;
	register long r_a7 asm("a7") = n;

	__asm__ __volatile__("ecall"
	    : "+r"(r_a0)
	    : "r"(r_a1), "r"(r_a2), "r"(r_a3), "r"(r_a7)
	    : "memory");
	return (r_a0);
}

long write(int fd, const char *b, size_t n) { return __sys(SYS_write, fd, (long)b, (long)n, 0); }
long read(int fd, char *b, size_t n)        { return __sys(SYS_read, fd, (long)b, (long)n, 0); }
int  open(const char *p, int fl)            { return (int)__sys(SYS_openat, -100, (long)p, fl, 0); }
int  close(int fd)                          { return (int)__sys(SYS_close, fd, 0, 0, 0); }
int  getpid(void)                           { return (int)__sys(SYS_getpid, 0, 0, 0, 0); }
int  fork(void)                             { return (int)__sys(SYS_fork, 0, 0, 0, 0); }
int  execve(const char *p, char *const av[], char *const ev[])
{ return (int)__sys(SYS_execve, (long)p, (long)av, (long)ev, 0); }
int  waitpid(int pid, int *st, int opt)     { return (int)__sys(SYS_wait4, pid, (long)st, opt, 0); }
void _exit(int s)                           { __sys(SYS_exit, s, 0, 0, 0); for (;;) ; }

void cowreport(void)     { __sys(SYS_cowreport, 0, 0, 0, 0); }
long preemptreport(void) { return __sys(SYS_preemptreport, 0, 0, 0, 0); }
void spin(unsigned long n)
{ volatile unsigned long i; for (i = 0; i < n; i++) __asm__ __volatile__(""); }

size_t strlen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }
void *memcpy(void *d, const void *s, size_t n)
{ char *cd = d; const char *cs = s; while (n--) *cd++ = *cs++; return d; }
void *memset(void *d, int c, size_t n)
{ char *cd = d; while (n--) *cd++ = (char)c; return d; }
int strcmp(const char *a, const char *b)
{ while (*a && *a == *b) { a++; b++; } return (int)((unsigned char)*a - (unsigned char)*b); }

/*
 * malloc over brk — a bump allocator. brk(0) queries the current break; each
 * malloc grows it and hands back the old top (8-byte aligned). free() is a
 * no-op: fine for short-lived userland (sh/utils). A real free-list is R-P11.
 * NOTE (R-P10 ceiling): bump allocator, no reuse; add a free-list if a util churns memory.
 */
static unsigned long heap_cur;
static unsigned long heap_end;

void *
malloc(size_t n)
{
	unsigned long p;

	n = (n + 7) & ~7UL;
	if (heap_cur == 0)
		heap_cur = heap_end = (unsigned long)__sys(SYS_brk, 0, 0, 0, 0);
	if (heap_cur + n > heap_end) {
		unsigned long want = heap_cur + n;
		unsigned long grow = (want + 0xfffUL) & ~0xfffUL;	/* page up */
		/*
		 * Kernel proc_brk ABI: brk(newbrk) returns 0 on success (the
		 * break moved to newbrk), <0 on failure. (brk(0) queries the
		 * current break.) So a 0 return means the grow succeeded.
		 */
		if (__sys(SYS_brk, (long)grow, 0, 0, 0) != 0)
			return (0);		/* out of memory */
		heap_end = grow;
	}
	p = heap_cur;
	heap_cur += n;
	return ((void *)p);
}

void free(void *p) { (void)p; }

int
puts(const char *s)
{
	long n = (long)strlen(s);
	return ((int)write(1, s, (size_t)n));
}

void
putdec(unsigned long v)
{
	char buf[24];
	int i = 0;
	if (v == 0) { write(1, "0", 1); return; }
	while (v) { buf[i++] = (char)('0' + (v % 10)); v /= 10; }
	while (i--) write(1, &buf[i], 1);
}

/* Format one unsigned into base (10 or 16) into buf, return length. */
static int
utoa(unsigned long v, unsigned base, char *buf)
{
	static const char hex[] = "0123456789abcdef";
	char tmp[24];
	int i = 0, j = 0;
	if (v == 0) { buf[0] = '0'; return (1); }
	while (v) { tmp[i++] = hex[v % base]; v /= base; }
	while (i--) buf[j++] = tmp[i];
	return (j);
}

/*
 * printf — the real thing (a genuine varargs formatter, not a fixed-arg stub):
 * %s %d %u %x %c %%. Emits to fd 1 via write(). Enough for sh + init + the
 * utilities; width/precision/long modifiers are R-P11.
 */
int
printf(const char *fmt, ...)
{
	va_list ap;
	char buf[32];
	int total = 0;

	va_start(ap, fmt);
	for (; *fmt; fmt++) {
		if (*fmt != '%') {
			write(1, fmt, 1);
			total++;
			continue;
		}
		fmt++;
		switch (*fmt) {
		case 's': {
			const char *s = va_arg(ap, const char *);
			int n = (int)strlen(s);
			write(1, s, (size_t)n);
			total += n;
			break;
		}
		case 'd': {
			int d = va_arg(ap, int);
			int n;
			if (d < 0) { write(1, "-", 1); total++; d = -d; }
			n = utoa((unsigned long)(unsigned)d, 10, buf);
			write(1, buf, (size_t)n);
			total += n;
			break;
		}
		case 'u': {
			unsigned u = va_arg(ap, unsigned);
			int n = utoa(u, 10, buf);
			write(1, buf, (size_t)n);
			total += n;
			break;
		}
		case 'x': {
			unsigned u = va_arg(ap, unsigned);
			int n = utoa(u, 16, buf);
			write(1, buf, (size_t)n);
			total += n;
			break;
		}
		case 'c': {
			char c = (char)va_arg(ap, int);
			write(1, &c, 1);
			total++;
			break;
		}
		case '%':
			write(1, "%", 1);
			total++;
			break;
		default:
			write(1, "%", 1);
			write(1, fmt, 1);
			total += 2;
			break;
		}
	}
	va_end(ap);
	return (total);
}

/*
 * _start — the crt0 process entry (now in libc, not per-program). The kernel
 * builds an ELF-ABI initial stack: at sp is argc, then argv[0..argc-1], NULL,
 * envp, NULL, auxv. Read argc at 0(sp), argv at 8(sp), call main, exit its
 * return. Naked so sp is untouched before capture.
 */
__attribute__((naked, used)) void
_start(void)
{
	__asm__ __volatile__(
	    "ld a0, 0(sp)\n"
	    "addi a1, sp, 8\n"
	    "call main\n"
	    "li a7, 93\n"		/* SYS_exit(main's return in a0) */
	    "ecall\n"
	    "1: j 1b\n");
}
