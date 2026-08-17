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
#ifndef CU3_GLUE_H
#define CU3_GLUE_H

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


/* ===== cu3.c-only glue (basename/dirname/env; on the shared reduction) ===== */

/* --- basename-lgpl.h / dirname-lgpl.h (gnulib), POSIX single-slash. --- */
#define ISSLASH(c) ((c) == '/')
#define FILE_SYSTEM_PREFIX_LEN(f) 0
#define IS_RELATIVE_FILE_NAME(f)  (! ISSLASH((f)[0]))
#define IS_ABSOLUTE_FILE_NAME(f)  (ISSLASH((f)[0]))

/* base_len: length of the final path component (trailing slashes stripped). */
static inline size_t base_len(char const *name)
{
	size_t len, prefix = 0;
	for (len = strlen(name); 1 < len && ISSLASH(name[len - 1]); len--)
		continue;
	return len - prefix;
}

/* dir_len: length of the directory prefix of NAME (gnulib). */
static inline size_t dir_len(char const *file)
{
	size_t prefix_length = 0;
	size_t length;
	for (length = base_len(file); length && !ISSLASH(file[length - 1]); length--)
		continue;
	for (; length && ISSLASH(file[length - 1]); length--)
		continue;
	return length ? length : prefix_length ? prefix_length : ISSLASH(file[0]) ? 1 : 0;
}

/* strip_trailing_slashes (gnulib lib/stripslash.c): trim, keep a lone root. */
static inline int strip_trailing_slashes(char *file)
{
	char *base = file, *p;
	int had = 0;
	for (p = base; *p; p++)
		continue;
	while (base < p && ISSLASH(p[-1])) { p--; had = 1; }
	if (p == base && ISSLASH(*base)) { p++; had = 0; }
	*p = '\0';
	return had;
}

/* base_name (gnulib lib/dirname-lgpl.c): xmalloc'd final component, with a
 * trailing slash appended if the base is "." or the whole thing is slashes. */
static inline char *base_name(char const *name)
{
	char const *base = name, *p;
	size_t length;
	int last_was_slash = 0;
	while (ISSLASH(*base)) base++;
	for (p = base; *p; p++) {
		if (ISSLASH(*p)) last_was_slash = 1;
		else if (last_was_slash) { base = p; last_was_slash = 0; }
	}
	for (length = 0; base[length] && !ISSLASH(base[length]); length++)
		continue;
	if (length == 0) {  /* name is all slashes -> "/" */
		char *r = xmalloc(2); r[0] = '/'; r[1] = '\0'; return r;
	}
	char *r = xmalloc(length + 1);
	memcpy(r, base, length);
	r[length] = '\0';
	return r;
}

/* c-ctype.h (gnulib): ASCII-only classifiers env.c uses. */
#define c_isspace(c) ((c) == ' ' || (c) == '\t' || (c) == '\n' || (c) == '\r' || (c) == '\v' || (c) == '\f')
#define c_isdigit(c) ((unsigned) ((c) - '0') <= 9)
#define c_isalpha(c) (((unsigned)((c)|32) - 'a') <= 25)
#define c_isalnum(c) (c_isalpha(c) || c_isdigit(c))

/* environ (real libc). */
extern char **environ;

#endif /* CU3_GLUE_H */
