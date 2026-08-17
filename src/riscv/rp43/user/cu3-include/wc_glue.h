/*
 * wc_glue.h -- the gnulib/config.h + system.h + lib/ glue that lets the
 * UNMODIFIED GNU coreutils-9.5 src/wc.c compile + LINK against the REAL solnix
 * riscv64 libc.a.  As with cat_glue.h, this is NOT a libc: stdio/stdlib/string/
 * fd I/O (open/read/lseek/close/malloc/printf/getopt_long) come from the real
 * libc; this header only supplies the gnulib scaffolding names wc.c references
 * (system.h macros, the lib/ helpers argv-iter/physmem/readtokens0/argmatch,
 * umaxtostr/imaxtostr, INT_BUFSIZE_BOUND, xnmalloc, the multibyte fast-path
 * stubs), reduced to what wc exercises in the C locale (MB_CUR_MAX == 1, so the
 * wide-character branch is dead code that must merely compile).
 *
 * CRIB PROVENANCE: the names below are gnulib/coreutils' own (system.h, lib/
 * argv-iter.c [linked real], lib/physmem.c, lib/argmatch.c/xstrtoumax,
 * lib/inttostr umaxtostr/imaxtostr, gettext/error/quotearg); declared/defined
 * so the genuine upstream wc.c is the compilation unit, unchanged.
 */
#ifndef WC_GLUE_H
#define WC_GLUE_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <unistd.h>
#include <stdarg.h>
#include <sys/types.h>
#include <sys/stat.h>

extern int errno;

/* --- config.h / system.h scaffolding (shared shape with cat_glue.h). --- */
#define _(s)  (s)
#define N_(s) (s)
#define STREQ(a, b) (strcmp((a), (b)) == 0)
#define FALLTHROUGH __attribute__((fallthrough))
#ifndef nullptr
#define nullptr ((void *)0)
#endif
typedef int bool;
#define true 1
#define false 0
#define PACKAGE 0
#define LOCALEDIR 0
#define LC_ALL 0
#define PACKAGE_NAME "GNU coreutils"
#define Version "9.5"
#define affirm(x) ((void)0)
#define _GL_ATTRIBUTE_MAYBE_UNUSED
#define _GL_UNUSED
#define _GL_ATTRIBUTE_PURE
#define ATTRIBUTE_PURE
#define _GL_ARG_NONNULL(x)
#define _GL_ATTRIBUTE_DEALLOC(f, n)
#define _GL_ATTRIBUTE_DEALLOC_FREE
#define MB_CUR_MAX 1

/* fixed-width integer types wc uses (the reduced libc has no <stdint.h>). */
typedef unsigned long uintmax_t;
typedef long intmax_t;
typedef unsigned long size_t_uint;
#define UINTMAX_MAX (~0UL)
#define INTMAX_MAX  (0x7fffffffffffffffL)
#define SIZE_MAX  ((size_t)-1)
#define SSIZE_MAX ((ssize_t)(~0UL >> 1))
#define INT_MAX 0x7fffffff
#define CHAR_MAX 127
#define UCHAR_MAX 255
#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1
#define EOVERFLOW 79
#define STDIN_FILENO 0
#define STDOUT_FILENO 1

typedef long idx_t;
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#define MAX(a, b) ((a) > (b) ? (a) : (b))

/* checked arithmetic (gnulib stdckdint.h): 64-bit accumulators, small files. */
#define ckd_mul(r, a, b) ((*(r) = (a) * (b)), 0)
#define ckd_add(r, a, b) ((*(r) = (a) + (b)), 0)

/* INT_BUFSIZE_BOUND: max decimal digits + sign + NUL for a 64-bit type. */
#define INT_BUFSIZE_BOUND(t) 24

/* umaxtostr/imaxtostr (gnulib lib/inttostr.c): decimal render into buf. */
extern char *umaxtostr(uintmax_t v, char *buf);
extern char *imaxtostr(intmax_t v, char *buf);

/* progname + closeout. */
extern char *program_name;
static inline void set_program_name(const char *a) { program_name = (char *)a; }
static inline void close_stdout(void) { fflush(stdout); fflush(stderr); }

/* locale/gettext no-ops (C locale only). */
static inline char *setlocale(int c, const char *l) { (void)c; (void)l; return (char *)""; }
static inline char *bindtextdomain(const char *d, const char *dir) { (void)d; (void)dir; return (char *)0; }
static inline char *textdomain(const char *d) { (void)d; return (char *)0; }
static inline void initialize_main(int *ac, char ***av) { (void)ac; (void)av; }

static inline const char *proper_name_lite(const char *a, const char *b)
	{ (void)b; return (a); }
#define proper_name(x) proper_name_lite(x, x)
#define version_etc(f, prog, pkg, ver, ...) \
	fprintf((f), "%s (%s) %s\n", (prog), (pkg), (ver))
static inline void emit_ancillary_info(const char *x) { (void)x; }
static inline void emit_stdin_note(void)
	{ fputs("\nWith no FILE, or when FILE is -, read standard input.\n", stdout); }
#define emit_try_help() \
	fprintf(stderr, "Try '%s --help' for more information.\n", program_name)

#define HELP_OPTION_DESCRIPTION \
	"      --help        display this help and exit\n"
#define VERSION_OPTION_DESCRIPTION \
	"      --version     output version information and exit\n"
#define USAGE_BUILTIN_WARNING ""

/* --- getopt long-options plumbing (gnulib getopt.h). --- */
#include <getopt.h>
#define GETOPT_HELP_CHAR    (-2)
#define GETOPT_VERSION_CHAR (-3)
#define GETOPT_HELP_OPTION_DECL \
	"help", no_argument, nullptr, GETOPT_HELP_CHAR
#define GETOPT_VERSION_OPTION_DECL \
	"version", no_argument, nullptr, GETOPT_VERSION_CHAR
#define case_GETOPT_HELP_CHAR \
	case GETOPT_HELP_CHAR: \
	    usage(EXIT_SUCCESS); \
	    break;
#define case_GETOPT_VERSION_CHAR(Program_name, Authors) \
	case GETOPT_VERSION_CHAR: \
	    version_etc(stdout, Program_name, PACKAGE_NAME, Version, Authors, \
	        (char *)nullptr); \
	    exit(EXIT_SUCCESS); \
	    break;

/* --- error() (gnulib lib/error.c, reduced). --- */
static inline void
error(int status, int errnum, const char *fmt, ...)
{
	va_list ap;
	fprintf(stderr, "%s: ", program_name);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	if (errnum)
		fprintf(stderr, ": errno %d", errnum);
	fputc('\n', stderr);
	if (status)
		exit(status);
}

#define quotef(arg)  (arg)
#define quoteaf(arg) (arg)
static inline void xalloc_die(void) { fputs("wc: memory exhausted\n", stderr); exit(2); }
static inline void *xnmalloc(size_t n, size_t s)
	{ void *p = calloc(n ? n : 1, s ? s : 1); if (!p) xalloc_die(); return (p); }
static inline void unreachable(void) { abort(); }

/* --- fadvise.h: no-op on the reduced kernel. --- */
typedef enum { FADVISE_NORMAL, FADVISE_SEQUENTIAL, FADVISE_NOREUSE,
	       FADVISE_DONTNEED, FADVISE_WILLNEED, FADVISE_RANDOM } fadvice_t;
static inline void fdadvise(int fd, off_t off, off_t len, fadvice_t a)
	{ (void)fd; (void)off; (void)len; (void)a; }
static inline void fadvise(FILE *f, fadvice_t a) { (void)f; (void)a; }

/* --- xbinary-io.h: no binary/text distinction. --- */
#define O_BINARY 0
#define O_RDONLY 0x000
static inline void xset_binary_mode(int fd, int mode) { (void)fd; (void)mode; }

/* --- stat-size.h: usable_st_size + STP_BLKSIZE (gnulib), reduced. --- */
#define usable_st_size(st) (S_ISREG((st)->st_mode))
#define ST_BLKSIZE(st)  ((st)->st_blksize > 0 ? (st)->st_blksize : 4096)
#define STP_BLKSIZE(st) ST_BLKSIZE(st)

/* --- physmem.h: report a generous amount (gnulib lib/physmem.c). --- */
extern double physmem_available(void);
extern double physmem_total(void);

/* --- rawmemchr (gnulib): memchr where the byte is guaranteed present. --- */
static inline void *rawmemchr(const void *s, int c)
	{ const unsigned char *p = s; while (*p != (unsigned char)c) p++; return (void *)p; }

/* --- multibyte fast-path stubs: dead code with MB_CUR_MAX == 1, but wc.c
       still references these names, so they must compile.  (C locale.) --- */
typedef int wint_t;
typedef unsigned int char32_t;
typedef struct { int __c; } mbstate_t;
static inline void mbszero(mbstate_t *st) { if (st) st->__c = 0; }
static inline int mbsinit(const mbstate_t *st) { return (st ? st->__c == 0 : 1); }
static inline size_t mbrtoc32(char32_t *pc, const char *s, size_t n, mbstate_t *st)
	{ (void)st; if (n == 0) return ((size_t)-2); if (pc) *pc = (unsigned char)*s; return (1); }
static inline int c32width(char32_t c) { (void)c; return (1); }
static inline char32_t btoc32(int c) { return ((char32_t)(unsigned char)c); }
static inline int iswspace(wint_t c) { return (isspace((int)c)); }

/* --- argmatch.h: XARGMATCH linear match (gnulib lib/argmatch.c), reduced. --- */
#define ARGMATCH_VERIFY(a, b) typedef int __argmatch_verify_dummy
extern int __argmatch(const char *arg, const char *const *arglist);
#define XARGMATCH(ctx, arg, arglist, vallist) \
	((vallist)[__argmatch((arg), (arglist))])

/* --- uchar.h already pulled by wc.c; ensure UCHAR types resolve. --- */

#endif /* WC_GLUE_H */
