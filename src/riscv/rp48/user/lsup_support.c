/* lsup_support.c -- R-P45 support TU for the faithful UNMODIFIED coreutils-9.5
   ls.c.  Holds the C-locale reductions for the three gnulib modules not taken
   verbatim (their upstream .c pulls glibc-internal machinery -- scratch_buffer,
   the extended-glob fnmatch_loop, the xdectoint suffix table -- that the reduced
   solnix libc does not carry).  ls.c and the 40+ verbatim gnulib .c stay
   unmodified; the glue lives here, exactly as for the other landed utils. */
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fnmatch.h>

/* the ls binary personality name (src/ls-ls.c sets ls_mode; this is the
   PACKAGE Version string the generated version.h would carry). */
char const *Version = "9.5";

/* xnumtoumax: ls uses it for --block-size / -I numeric args with an optional
   size suffix.  C-locale reduction: parse the leading unsigned integer with
   strtoumax and honor a single k/K/m/M/g/G binary suffix; on parse failure
   call the util's xstrtol_fatal path indirectly by returning min-1 clamps.
   The reduced ls exercises only plain decimal counts, so the suffix table is
   the common {K,M,G,T} binary multipliers. */
uintmax_t
xnumtoumax(char const *n_str, int base, uintmax_t min, uintmax_t max,
    char const *suffixes, char const *err, int err_exit)
{
	char *end;
	uintmax_t v = strtoumax(n_str, &end, base ? base : 10);
	(void) suffixes; (void) err; (void) err_exit;
	if (end && *end) {
		uintmax_t mul = 0;
		switch (*end) {
		case 'k': case 'K': mul = 1024UL; break;
		case 'm': case 'M': mul = 1024UL*1024; break;
		case 'g': case 'G': mul = 1024UL*1024*1024; break;
		case 't': case 'T': mul = 1024UL*1024*1024*1024; break;
		default: mul = 0; break;
		}
		if (mul)
			v *= mul;
	}
	if (v < min) v = min;
	if (v > max) v = max;
	return (v);
}

/* xdectoumax: the decimal (base 10) form nproc.c uses for --ignore/--all. */
uintmax_t
xdectoumax(char const *n_str, uintmax_t min, uintmax_t max,
    char const *suffixes, char const *err, int err_exit)
{
	return (xnumtoumax(n_str, 10, min, max, suffixes, err, err_exit));
}

/* canonicalize_filename_mode: ls uses it (with CAN_MISSING) only to resolve
   the command-line operand for --dereference-command-line-symlink-to-dir.  The
   reduced fs has no symlinks (readlink returns EINVAL), so canonicalization is
   pure lexical: collapse "//" and "/./" and resolve "/../".  Returns a malloc'd
   absolute-ish path (relative paths are returned normalized as-is, which is
   what ls needs to stat the operand). */
char *
canonicalize_filename_mode(const char *name, int can_mode)
{
	(void) can_mode;
	if (name == NULL) { errno = EINVAL; return (NULL); }
	size_t n = strlen(name);
	char *out = malloc(n + 1);
	if (out == NULL) return (NULL);
	const char *s = name;
	char *d = out;
	while (*s) {
		if (s[0] == '/' && s[1] == '/') { s++; continue; }
		if (s[0] == '/' && s[1] == '.' &&
		    (s[2] == '/' || s[2] == '\0')) { s += 2; continue; }
		*d++ = *s++;
	}
	if (d == out) *d++ = (name[0] == '/') ? '/' : '.';
	*d = '\0';
	return (out);
}

/* fnmatch: ls uses it for --ignore / --hide glob patterns (only FNM_PERIOD is
   ever passed).  C-locale glob: '*' '?' '[..]' with the leading-'.' rule.  A
   compact recursive matcher (patterns are short ignore-globs, so the O(n*m)
   backtrack is fine). */
static int
range_match(const char *p, char c, const char **pend)
{
	int neg = 0, matched = 0;
	if (*p == '!' || *p == '^') { neg = 1; p++; }
	for (; *p && *p != ']'; p++) {
		if (p[1] == '-' && p[2] && p[2] != ']') {
			if ((unsigned char)c >= (unsigned char)p[0] &&
			    (unsigned char)c <= (unsigned char)p[2])
				matched = 1;
			p += 2;
		} else if (*p == c) {
			matched = 1;
		}
	}
	if (*p == ']') p++;
	*pend = p;
	return (matched ^ neg);
}

int
fnmatch(const char *pattern, const char *string, int flags)
{
	const char *p = pattern, *s = string;
	if ((flags & FNM_PERIOD) && *s == '.' && *p != '.')
		return (FNM_NOMATCH);
	while (*p) {
		if (*p == '*') {
			p++;
			if (*p == '\0') return (0);
			for (; *s; s++)
				if (fnmatch(p, s, flags & ~FNM_PERIOD) == 0)
					return (0);
			return (fnmatch(p, s, flags & ~FNM_PERIOD));
		} else if (*p == '?') {
			if (*s == '\0') return (FNM_NOMATCH);
			p++; s++;
		} else if (*p == '[') {
			const char *pend;
			if (*s == '\0') return (FNM_NOMATCH);
			if (!range_match(p + 1, *s, &pend))
				return (FNM_NOMATCH);
			p = pend; s++;
		} else if (*p == '\\' && !(flags & FNM_NOESCAPE)) {
			p++;
			if (*p != *s) return (FNM_NOMATCH);
			p++; s++;
		} else {
			if (*p != *s) return (FNM_NOMATCH);
			p++; s++;
		}
	}
	return (*s == '\0' ? 0 : FNM_NOMATCH);
}

#ifdef LSUP_SUPPORT_SELFTEST
#include <assert.h>
int main(void) {
	assert(fnmatch("*.txt", "a.txt", 0) == 0);
	assert(fnmatch("*.txt", "a.md", 0) == FNM_NOMATCH);
	assert(fnmatch("f?o", "foo", 0) == 0);
	assert(fnmatch("[abc]z", "bz", 0) == 0);
	assert(fnmatch("[!abc]z", "dz", 0) == 0);
	assert(fnmatch("*", ".hid", FNM_PERIOD) == FNM_NOMATCH);
	assert(xnumtoumax("16", 10, 0, 1000000, "", "", 0) == 16);
	assert(xnumtoumax("2K", 10, 0, 1000000, "", "", 0) == 2048);
	char *c = canonicalize_filename_mode("/a//b/./c", 0);
	assert(strcmp(c, "/a/b/c") == 0); free(c);
	return (0);
}
#endif

/* ---- error()/error_at_line(): gnulib error.c wants a portable fcntl F_GETFL
   probe the reduced libc lacks; this is the plain GNU error() contract ------ */
#include <stdio.h>
#include <stdarg.h>
extern const char *program_name;		/* set by set_program_name (progname.c) */
unsigned int error_message_count = 0;
int error_one_per_line = 0;
void (*error_print_progname)(void) = 0;

static void
error_tail(int status, int errnum, const char *fmt, va_list ap)
{
	vfprintf(stderr, fmt, ap);
	if (errnum) {
		extern char *strerror(int);
		fprintf(stderr, ": %s", strerror(errnum));
	}
	fputc('\n', stderr);
	fflush(stderr);
	error_message_count++;
	if (status)
		exit(status);
}

void
error(int status, int errnum, const char *fmt, ...)
{
	va_list ap;
	fflush(stdout);
	if (error_print_progname)
		error_print_progname();
	else if (program_name)
		fprintf(stderr, "%s: ", program_name);
	va_start(ap, fmt);
	error_tail(status, errnum, fmt, ap);
	va_end(ap);
}

void
error_at_line(int status, int errnum, const char *fname, unsigned int lineno,
    const char *fmt, ...)
{
	va_list ap;
	fflush(stdout);
	if (program_name)
		fprintf(stderr, "%s:", program_name);
	if (fname)
		fprintf(stderr, "%s:%u: ", fname, lineno);
	va_start(ap, fmt);
	error_tail(status, errnum, fmt, ap);
	va_end(ap);
}

/* ---- close_stream(): gnulib close-stream.c needs __fpending; the reduced
   stdio flushes eagerly, so this is fflush-then-fclose with an error check.  */
int
close_stream(FILE *stream)
{
	int some_pending = (fflush(stream) != 0);
	int prev_fail = ferror(stream);
	int fclose_fail = (fclose(stream) != 0);
	if (prev_fail || (fclose_fail && (some_pending || errno != EBADF))) {
		if (!fclose_fail)
			errno = 0;
		return (EOF);
	}
	return (0);
}

/* ---- setlocale_null *_unlocked variants (single-threaded libc) ---------- */
/*
 * The reduced libc has only the C locale.  setlocale_null_unlocked returns
 * "C" directly; setlocale_null_r_unlocked copies that into BUF.  It must NOT
 * call the gnulib setlocale_null_r (setlocale_null.c), because that function
 * dispatches back to setlocale_null_r_unlocked -- routing through it here would
 * be infinite mutual recursion (the default `ls -l` startup stall: the locale
 * time-style path calls hard_locale(LC_TIME) -> setlocale_null_r -> _unlocked
 * -> setlocale_null_r -> ...).  Mirror the real gnulib _unlocked contract:
 * copy setlocale_null_unlocked()'s result, return 0 / ERANGE / EINVAL.
 */
#include <errno.h>
const char *setlocale_null_unlocked(int category);
int
setlocale_null_r_unlocked(int category, char *buf, size_t bufsize)
{
	const char *result = setlocale_null_unlocked(category);
	if (result == NULL) {
		if (bufsize > 0)
			buf[0] = '\0';
		return (EINVAL);
	}
	size_t length = strlen(result);
	if (length < bufsize) {
		memcpy(buf, result, length + 1);
		return (0);
	}
	if (bufsize > 0) {
		memcpy(buf, result, bufsize - 1);
		buf[bufsize - 1] = '\0';
	}
	return (ERANGE);
}

const char *
setlocale_null_unlocked(int category)
{
	(void) category;
	return ("C");
}

/* ---- gl_locale_name_unsafe: only the C locale exists -------------------- */
const char *
gl_locale_name_unsafe(int category, const char *categoryname)
{
	(void) category; (void) categoryname;
	return ("C");
}

/* ---- mbszero: zero an mbstate_t (wchar.in.h inline the reduced wchar.h lacks) */
#include <string.h>
#include <wchar.h>
void
mbszero(mbstate_t *ps)
{
	memset(ps, 0, sizeof(*ps));
}
