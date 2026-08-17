/*
 * head_glue.h -- the gnulib/config.h + system.h + lib/ glue that lets the
 * UNMODIFIED GNU coreutils-9.5 src/head.c compile + LINK against the REAL
 * solnix riscv64 libc.a.  Built on top of wc_glue.h (shared C-locale
 * reduction): stdio/stdlib/string/fd I/O come from the real libc; this header
 * adds only the names head.c references beyond wc's set:
 *   - safe_read / full_read (gnulib lib/safe-read.c + lib/full-write.c,
 *     reduced to the EINTR-retry read loop; SAFE_READ_ERROR == (size_t)-1)
 *   - xdectoumax (gnulib lib/xdectoint.c, reduced: strtoumax with the
 *     bkKmMG... IEC/SI suffix multipliers head passes, bounded + error-exit)
 *   - xmalloc / xnrealloc (gnulib lib/xmalloc.c, reduced; xalloc_die on OOM)
 *   - quote() (gnulib lib/quote.c; C locale -> passthrough, like quotef)
 *   - assure() (gnulib assure.h; == assert without <assert.h>)
 *   - OFF_T_MAX (gnulib intprops; off_t is 64-bit signed here)
 */
#ifndef HEAD_GLUE_H
#define HEAD_GLUE_H

#include "wc_glue.h"

/* --- assure.h (gnulib): a checked assertion, verify-style. --- */
#define assure(x) ((void) ((x) || (abort(), 0)))

/* --- quote.h (gnulib lib/quote.c): C locale -> identity, like quotef. --- */
#define quote(arg)      (arg)
#define quote_n(n, arg) (arg)

/* --- intprops.h: off_t is 64-bit signed on the solnix riscv64 ABI. --- */
#define OFF_T_MAX 0x7fffffffffffffffL
#ifndef EINTR
#define EINTR 4
#endif
#ifndef ENOMEM
#define ENOMEM 12
#endif

/* --- xmalloc.c (gnulib), reduced: exit on OOM.  (xnmalloc is in wc_glue.) --- */
static inline void *xmalloc(size_t n) { void *p = malloc(n ? n : 1); if (!p) xalloc_die(); return p; }
static inline void *xnrealloc(void *p, size_t n, size_t s)
	{ void *q = realloc(p, (n ? n : 1) * (s ? s : 1)); if (!q) xalloc_die(); return q; }
static inline void *xrealloc(void *p, size_t n) { void *q = realloc(p, n ? n : 1); if (!q) xalloc_die(); return q; }

/* --- safe-read.h / full-read.h (gnulib): the EINTR-retry read loops. --- */
#define SAFE_READ_ERROR ((size_t) -1)
static inline size_t
safe_read(int fd, void *buf, size_t count)
{
	for (;;) {
		ssize_t r = read(fd, buf, count);
		if (r >= 0)
			return (size_t) r;
		if (errno == EINTR)
			continue;
		return SAFE_READ_ERROR;
	}
}
static inline size_t
full_read(int fd, void *buf, size_t count)
{
	size_t total = 0;
	char *p = buf;
	while (count > 0) {
		size_t n = safe_read(fd, p, count);
		if (n == SAFE_READ_ERROR)
			break;
		if (n == 0) {
			errno = 0;   /* FULL_READ: errno 0 at EOF */
			break;
		}
		total += n;
		p += n;
		count -= n;
	}
	return total;
}

/* --- xdectoint.h (gnulib lib/xdectoint.c), reduced.  head passes
 *     suffixes "bkKmMGTPEZYRQ0" and bounds [0, UINTMAX_MAX]; parse the
 *     decimal prefix, then apply the (optional) block/IEC multiplier. --- */
static inline uintmax_t
xdectoumax(char const *n_str, uintmax_t min, uintmax_t max,
    char const *suffixes, char const *err, int err_exit)
{
	char *end;
	uintmax_t v = strtoul(n_str, &end, 10);
	uintmax_t mult = 1;
	(void) min;
	if (end != n_str && *end && suffixes && strchr(suffixes, *end)) {
		int c = *end++;
		if (*end == 'B') end++;
		switch (c) {
		case 'b': mult = 512; break;
		case '0': mult = 1;   break;
		case 'k': case 'K': mult = 1024UL; break;
		case 'm': case 'M': mult = 1024UL * 1024; break;
		case 'G': mult = 1024UL * 1024 * 1024; break;
		case 'T': mult = 1024UL * 1024 * 1024 * 1024; break;
		case 'P': mult = 1024UL * 1024 * 1024 * 1024 * 1024; break;
		case 'E': mult = 1024UL * 1024 * 1024 * 1024 * 1024 * 1024; break;
		default:  mult = 1; break;
		}
	}
	if (*end != '\0')
		error(err_exit ? err_exit : 1, 0, "%s: %s", err ? err : "invalid number", n_str);
	v *= mult;
	if (v > max)
		v = max;
	return v;
}


/* --- inttostr.h (gnulib): offtostr renders a signed off_t in decimal. --- */
static inline char *offtostr(off_t v, char *buf)
{
	char tmp[24]; int i = 0, neg = (v < 0);
	unsigned long u = neg ? -(unsigned long)v : (unsigned long)v;
	do { tmp[i++] = '0' + (u % 10); u /= 10; } while (u);
	if (neg) tmp[i++] = '-';
	char *p = buf;
	while (i) *p++ = tmp[--i];
	*p = 0;
	return buf;
}

/* --- system.h: ISDIGIT is c_isdigit (ASCII-only, C locale). --- */
#define ISDIGIT(c) ((unsigned) ((c) - '0') <= 9)

/* --- system.h: the mandatory argument help note. --- */
static inline void emit_mandatory_arg_note(void)
{
	fputs("\nMandatory arguments to long options are mandatory for short options too.\n", stdout);
}

#endif /* HEAD_GLUE_H */
