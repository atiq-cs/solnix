/*
 * head_glue.h -- the gnulib/config.h + system.h + lib/ glue that lets the
 * UNMODIFIED GNU coreutils-9.5 src/tail.c compile + LINK against the REAL
 * solnix riscv64 libc.a.  Built on top of wc_glue.h (shared C-locale
 * reduction): stdio/stdlib/string/fd I/O come from the real libc; this header
 * adds only the names tail.c references beyond wc's set:
 *   - safe_read / full_read (gnulib lib/safe-read.c + lib/full-write.c,
 *     reduced to the EINTR-retry read loop; SAFE_READ_ERROR == (size_t)-1)
 *   - xdectoumax (gnulib lib/xdectoint.c, reduced: strtoumax with the
 *     bkKmMG... IEC/SI suffix multipliers head passes, bounded + error-exit)
 *   - xmalloc / xnrealloc (gnulib lib/xmalloc.c, reduced; xalloc_die on OOM)
 *   - quote() (gnulib lib/quote.c; C locale -> passthrough, like quotef)
 *   - assure() (gnulib assure.h; == assert without <assert.h>)
 *   - OFF_T_MAX (gnulib intprops; off_t is 64-bit signed here)
 */
#ifndef TAIL_GLUE_H
#define TAIL_GLUE_H

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


/* ===== tail.c-only glue (on top of the shared wc/head reduction) ===== */

/* --- errno/fcntl constants tail references (the reduced kernel's values). --- */
#ifndef EAGAIN
#define EAGAIN 11
#endif
#ifndef ENOENT
#define ENOENT 2
#endif
#ifndef EPERM
#define EPERM 1
#endif
#ifndef O_NONBLOCK
#define O_NONBLOCK 0x80
#endif
#ifndef F_GETFL
#define F_GETFL 3
#endif
#ifndef F_SETFL
#define F_SETFL 4
#endif
static inline int fcntl(int fd, int cmd, ...) { (void) fd; (void) cmd; return 0; }
#ifndef S_ISSOCK
#define S_ISSOCK(m) 0
#endif
#ifndef S_ISFIFO
#define S_ISFIFO(m) 0
#endif
#ifndef S_ISCHR
#define S_ISCHR(m) 0
#endif
extern char *program_name;
static inline void write_error(void) { error(1, errno, "error writing standard output"); }
static inline void main_exit(int status) { close_stdout(); exit(status); }

/* --- MAYBE_UNUSED (gnulib): attribute wrapper. --- */
#define MAYBE_UNUSED __attribute__((unused))
#ifndef PTRDIFF_MAX
#define PTRDIFF_MAX 0x7fffffffffffffffL
#endif
#ifndef PID_T_MAX
#define PID_T_MAX 0x7fffffff
#endif
#ifndef ENOSYS
#define ENOSYS 89
#endif
#ifndef HAVE_FIFO_PIPES
#define HAVE_FIFO_PIPES 1
#endif
typedef long ptrdiff_t;

/* --- stat-time.h (gnulib): struct timespec + get_stat_mtime, reduced.
 *     The reduced kernel getattr has no sub-second time, so mtime is {0,0}. --- */
struct timespec { long tv_sec; long tv_nsec; };
static inline struct timespec get_stat_mtime(struct stat const *st)
	{ struct timespec t; t.tv_sec = 0; t.tv_nsec = 0; (void) st; return t; }
static inline struct timespec get_stat_atime(struct stat const *st)
	{ struct timespec t; t.tv_sec = 0; t.tv_nsec = 0; (void) st; return t; }
static inline int timespec_cmp(struct timespec a, struct timespec b)
	{ return a.tv_sec != b.tv_sec ? (a.tv_sec < b.tv_sec ? -1 : 1)
	       : (a.tv_nsec < b.tv_nsec ? -1 : a.tv_nsec > b.tv_nsec ? 1 : 0); }
static inline struct timespec dtotimespec(double sec)
	{ struct timespec t; t.tv_sec = (long) sec;
	  t.tv_nsec = (long) ((sec - (double) t.tv_sec) * 1e9); return t; }

/* --- iopoll.h (gnulib): tail -f output-liveness poll.  Without -f (the only
 *     mode the reduced kernel supports) this is never reached at runtime; the
 *     symbol must merely resolve.  Report "not broken". --- */
#define IOPOLL_BROKEN_OUTPUT (-2)
#define IOPOLL_ERROR         (-1)
static inline int iopoll(int fdin, int fdout, int block)
	{ (void) fdin; (void) fdout; (void) block; return 0; }

/* --- isapipe.h (gnulib): not a pipe on the reduced kernel. --- */
static inline int isapipe(int fd) { (void) fd; return 0; }

/* --- xnanosleep.h (gnulib): tail -f sleep between polls; no -f, so a stub. --- */
static inline int xnanosleep(double seconds) { (void) seconds; return 0; }

/* --- cl-strtod.h / xstrtod.h (gnulib): parse a floating seconds argument.
 *     tail's -s SECONDS; C-locale strtod-lite is enough. --- */
static inline double cl_strtod(char const *str, char **endptr)
{
	double v = 0.0, frac = 0.0, scale = 1.0; int neg = 0;
	char const *s = str;
	while (*s == ' ' || *s == '\t') s++;
	if (*s == '+') s++; else if (*s == '-') { neg = 1; s++; }
	while (*s >= '0' && *s <= '9') { v = v * 10.0 + (*s - '0'); s++; }
	if (*s == '.') { s++; while (*s >= '0' && *s <= '9') { frac = frac * 10.0 + (*s - '0'); scale *= 10.0; s++; } }
	v += frac / scale;
	if (endptr) *endptr = (char *) s;
	return neg ? -v : v;
}
static inline int xstrtod(char const *str, char **endptr, double *result, double (*conv)(char const *, char **))
	{ char *e; double v = (conv ? conv : cl_strtod)(str, &e);
	  if (e == str) return 0; if (endptr) *endptr = e; if (result) *result = v; return 1; }

/* --- xstrtol.h (gnulib): the LONGINT_* status flags + xstrtoumax parse. --- */
typedef enum {
	LONGINT_OK = 0,
	LONGINT_OVERFLOW = 1,
	LONGINT_INVALID_SUFFIX_CHAR = 2,
	LONGINT_INVALID_SUFFIX_CHAR_WITH_OVERFLOW = 3,
	LONGINT_INVALID = 4
} strtol_error;
static inline strtol_error
xstrtoumax(char const *s, char **endp, int base, uintmax_t *val, char const *suffixes)
{
	char *e; uintmax_t v = strtoul(s, &e, base);
	uintmax_t mult = 1;
	if (e != s && *e && suffixes && strchr(suffixes, *e)) {
		switch (*e++) {
		case 'b': mult = 512; break;
		case 'k': case 'K': mult = 1024UL; break;
		case 'm': case 'M': mult = 1024UL * 1024; break;
		case 'G': mult = 1024UL * 1024 * 1024; break;
		default: break;
		}
	}
	if (endp) *endp = e;
	if (val) *val = v * mult;
	if (*e != '\0') return LONGINT_INVALID_SUFFIX_CHAR;
	return LONGINT_OK;
}

/* --- xpalloc / xreallocarray (gnulib lib/xalloc): grow an array, exit on OOM.
 *     tail's line-buffer growth.  Reduced: geometric doubling. --- */
static inline void *
xpalloc(void *pa, idx_t *pn, idx_t n_incr_min, ptrdiff_t n_max, idx_t s)
{
	idx_t n = *pn, nnew = n ? n * 2 : 8;
	if (nnew < n + n_incr_min) nnew = n + n_incr_min;
	if (n_max >= 0 && nnew > (idx_t) n_max) nnew = (idx_t) n_max;
	void *p = realloc(pa, (size_t) nnew * (size_t) s);
	if (!p) xalloc_die();
	*pn = nnew;
	return p;
}
static inline void *xreallocarray(void *p, size_t n, size_t s)
	{ void *q = realloc(p, (n ? n : 1) * (s ? s : 1)); if (!q) xalloc_die(); return q; }
static inline void *ximalloc(idx_t n) { return xmalloc((size_t) n); }

/* --- last_component (gnulib lib/basename-lgpl): pointer to the final path
 *     element.  tail's pretty-printing of a filename. --- */
static inline char *last_component(char const *name)
{
	char const *base = name, *p;
	for (p = name; *p; p++) if (*p == '/') base = p + 1;
	return (char *) base;
}

/* --- posixver.h: POSIX version query (unused at runtime). --- */
static inline int posix2_version(void) { return 200809; }

/* --- fcntl--.h / fcntl-safer: no fd-safety wrapper needed. --- */

/* --- gettime (gnulib): current time; the reduced kernel has no RTC. --- */
static inline void gettime(struct timespec *ts) { if (ts) { ts->tv_sec = 0; ts->tv_nsec = 0; } }
static inline struct timespec current_timespec(void) { struct timespec t = {0,0}; return t; }

#endif /* TAIL_GLUE_H */
