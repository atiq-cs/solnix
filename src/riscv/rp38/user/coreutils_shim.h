/*
 * coreutils_shim.h -- the minimal freestanding "libc" surface a solnix package
 * links against on riscv64 when the full libc is not yet ported: exactly the
 * entry points GNU coreutils echo.c references, backed by the illumos riscv64
 * syscall ABI (a7=nr, a0..=args, result in a0).  The point of R-P38.1 is to
 * compile the REAL, UNMODIFIED coreutils echo.c algorithm with the on-node
 * cross toolchain (riscv64-unknown-solaris2.11 xgcc) and DYNAMICALLY LINK it
 * against libgcc_s.so.1 via the real ld.so.1 -- i.e. built the way a solnix
 * package is built, not a hand-tailored test.  This shim stands in for the libc
 * a real package would pull in; the echo algorithm itself is upstream verbatim.
 *
 * CRIB PROVENANCE: the syscall stub shape is the illumos libc SYSTRAP idiom
 * (a7 trap number, ecall); the stdio putchar/fputs semantics are C89; the
 * gnulib scaffolding (config.h/system.h/c-ctype.h) is replaced by the smallest
 * set of definitions coreutils echo.c actually uses so the compiler sees the
 * genuine echo main() unchanged.
 */
#ifndef COREUTILS_SHIM_H
#define COREUTILS_SHIM_H

typedef unsigned long size_t;
typedef long ssize_t;

#define SYS_exit  1
#define SYS_read  3
#define SYS_write 4

static long
__sc3(long nr, long a0v, long a1v, long a2v)
{
	register long a7 __asm__("a7") = nr;
	register long a0 __asm__("a0") = a0v;
	register long a1 __asm__("a1") = a1v;
	register long a2 __asm__("a2") = a2v;
	__asm__ __volatile__("ecall" : "+r"(a0) : "r"(a7), "r"(a1), "r"(a2) : "memory");
	return (a0);
}

/* a small buffered stdout so the byte-at-a-time putchar() the echo algorithm
 * uses does not become one write(2) per character; flushed by close_stdout. */
static char __ob[512];
static int  __obn;
static void __flush(void) { if (__obn) { (void) __sc3(SYS_write, 1, (long)__ob, __obn); __obn = 0; } }
static int  putchar(int c) { if (__obn == sizeof(__ob)) __flush(); __ob[__obn++] = (char)c; return c; }

static size_t __slen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }

/* stdio surface echo.c uses.  FILE is opaque here (only stdout is referenced). */
typedef int FILE;
extern FILE *stdout;
static int fputs(const char *s, FILE *f) { (void)f; const char *p = s; while (*p) putchar(*p++); return 0; }

/* atexit hook: echo registers close_stdout; we run one hook and flush. */
static void (*__atexit_fn)(void);
static int atexit(void (*fn)(void)) { __atexit_fn = fn; return 0; }
static void exit(int status)
{
	if (__atexit_fn) __atexit_fn();
	__flush();
	(void) __sc3(SYS_exit, status & 0xff, 0, 0);
	for (;;) ;
}

/* environment: main() reads getenv("POSIXLY_CORRECT"); envp comes in argv[argc+1]. */
static char **__environ;
static char *getenv(const char *name)
{
	size_t nl = __slen(name);
	char **e = __environ;
	if (!e) return (void *)0;
	for (; *e; e++) {
		char *s = *e; size_t i = 0;
		while (i < nl && s[i] == name[i]) i++;
		if (i == nl && s[i] == "="[0]) return s + nl + 1;
	}
	return (void *)0;
}

/* no-op locale / gettext / program-name scaffolding (coreutils common). */
static char *program_name;
static void set_program_name(const char *a) { program_name = (char *)a; }
static char *setlocale(int cat, const char *loc) { (void)cat; (void)loc; return (char *)""; }
static char *bindtextdomain(const char *d, const char *dir) { (void)d; (void)dir; return (char *)0; }
static char *textdomain(const char *d) { (void)d; return (char *)0; }
static void close_stdout(void) { __flush(); }

/* c-ctype: c_isxdigit, used by the \x escape branch. */
static int c_isxdigit(int c)
{
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

/* macros/consts echo.c uses from gnulib/config.h. */
#define STREQ(a,b) (__streq((a),(b)))
static int __streq(const char *a, const char *b) { while (*a && *a == *b) { a++; b++; } return *a == *b; }
#define EXIT_SUCCESS 0
#define FALLTHROUGH __attribute__((fallthrough))
#define _(s) (s)
#define N_(s) (s)
#define nullptr ((void*)0)
#define bool int
#define true 1
#define false 0

/* usage()/--help/--version are not reachable in the R-P38 proof invocations;
 * provide thin stubs so the file compiles as the genuine upstream translation
 * unit (the echo ALGORITHM below is byte-for-byte upstream). */
#define PACKAGE 0
#define LOCALEDIR 0
#define LC_ALL 0
static void initialize_main(int *ac, char ***av) { (void)ac; (void)av; }
#define affirm(x) ((void)0)
static void usage(int status);
#define version_etc(a,b,c,d,...) ((void)0)
#define emit_ancillary_info(x) ((void)0)
#define printf(...) ((void)0)
#define proper_name(x) (x)
#define PROGRAM_NAME "echo"


/* usage() text macros (unreachable in the R-P38 proof invocations; defined only
 * so the verbatim upstream usage() compiles as part of the genuine echo TU). */
#define HELP_OPTION_DESCRIPTION ""
#define VERSION_OPTION_DESCRIPTION ""
#define USAGE_BUILTIN_WARNING ""
#define Version "9.5"
#define PACKAGE_NAME "GNU coreutils"

/* the verbatim upstream main(int,char**) is renamed so our real entry point can
 * capture envp (crt1 passes it in a2) for getenv(), then call the echo body. */
#define main echo_main
int echo_main(int argc, char **argv);

#endif /* COREUTILS_SHIM_H */
