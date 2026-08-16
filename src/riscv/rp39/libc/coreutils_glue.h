/*
 * coreutils_glue.h -- the gnulib/config.h + system.h glue that lets an
 * unmodified GNU coreutils src/ files translation unit compile against the solnix
 * riscv64 libc.  This is NOT a libc -- the libc is the real, separately
 * compiled libc.a (stdio/string/stdlib/ctype/syscalls).  This header only
 * supplies the gnulib scaffolding names coreutils expects (config.h macros,
 * system.h's _()/N_()/STREQ, c-ctype's c_isxdigit, the program_name +
 * close_stdout helpers, the usage-text option macros) mapped onto the real libc
 * headers -- exactly what the coreutils build's config.h/system.h/lib/ would
 * provide, reduced to what these small utils reference.
 *
 * CRIB PROVENANCE: the names below are gnulib/coreutils' own (system.h,
 * lib/c-ctype.h, lib/progname.c, lib/closeout.c, lib/version-etc.c); they are
 * declared/defined here so the genuine upstream src file is the compilation
 * unit, unchanged, and it links the real libc for stdio/string/stdlib.
 */
#ifndef COREUTILS_GLUE_H
#define COREUTILS_GLUE_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <unistd.h>

/* config.h / system.h scaffolding. */
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

/* c-ctype: coreutils' locale-independent classifiers map to the real libc. */
#define c_isxdigit(c) isxdigit((unsigned char)(c))
#define c_isdigit(c)  isdigit((unsigned char)(c))

/* gnulib progname + closeout, provided by the glue TU (progname.c-alike). */
extern char *program_name;
static inline void set_program_name(const char *a) { program_name = (char *)a; }
static inline void close_stdout(void) { fflush(stdout); fflush(stderr); }

/* locale/gettext no-ops (C locale only). */
static inline char *setlocale(int c, const char *l) { (void)c; (void)l; return (char *)""; }
static inline char *bindtextdomain(const char *d, const char *dir) { (void)d; (void)dir; return (char *)0; }
static inline char *textdomain(const char *d) { (void)d; return (char *)0; }
static inline void initialize_main(int *ac, char ***av) { (void)ac; (void)av; }

/* version-etc / ancillary-info: reachable only via --version; thin stubs. */
static inline const char *proper_name(const char *x) { return (x); }
#define version_etc(f, prog, pkg, ver, ...) \
	fprintf((f), "%s (%s) %s\n", (prog), (pkg), (ver))
static inline void emit_ancillary_info(const char *x) { (void)x; }
static inline void emit_try_help(void) { fputs("Try '--help' for more information.\n", stderr); }

/* usage()/--help/--version option-description text (gnulib long-options.h). */
#define HELP_OPTION_DESCRIPTION \
	"      --help        display this help and exit\n"
#define VERSION_OPTION_DESCRIPTION \
	"      --version     output version information and exit\n"
#define USAGE_BUILTIN_WARNING ""

#endif /* COREUTILS_GLUE_H */
