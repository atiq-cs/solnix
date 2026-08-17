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


/* ===== pwd.c glue (xgetcwd + the robust_getcwd fallback names) ===== */
#include <dirent.h>
#include <sys/stat.h>

/* xgetcwd.h (gnulib lib/xgetcwd.c): getcwd(NULL,0) allocates; OOM -> die. */
static inline char *xgetcwd(void)
{
	char *cwd = getcwd((char *)0, 0);
	if (!cwd && errno == ENOMEM)
		xalloc_die();
	return cwd;
}

#ifndef PATH_MAX
#define PATH_MAX 1024
#endif

/* root-dev-ino.h / dev-ino.h (gnulib): the dev/ino identity pair + compare. */
struct dev_ino { dev_t st_dev; ino_t st_ino; };
#define SAME_INODE(a, b) ((a).st_ino == (b).st_ino && (a).st_dev == (b).st_dev)
#define PSAME_INODE(a, b) ((a)->st_ino == (b)->st_ino && (a)->st_dev == (b)->st_dev)
/* same-inode.h (gnulib): psame_inode compares two struct stat. */
static inline int psame_inode(const struct stat *a, const struct stat *b)
{ return a->st_ino == b->st_ino && a->st_dev == b->st_dev; }
/* root-dev-ino.c (gnulib): the dev/ino of "/" (lstat), or NULL on error. */
static inline struct dev_ino *get_root_dev_ino(struct dev_ino *r)
{
	struct stat sb;
	if (lstat("/", &sb))
		return (struct dev_ino *)0;
	r->st_ino = sb.st_ino;
	r->st_dev = sb.st_dev;
	return r;
}

/* dirent-safer / gnulib dirent macros the robust fallback path uses. */
#define NOT_AN_INODE_NUMBER 0
#define D_INO(dp) ((dp)->d_ino)
#define _D_EXACT_NAMLEN(dp) (strlen((dp)->d_name))

/* readdir_ignoring_dot_and_dotdot (gnulib lib/readdir-safer style). */
static inline struct dirent *readdir_ignoring_dot_and_dotdot(DIR *dirp)
{
	for (;;) {
		struct dirent *dp = readdir(dirp);
		if (dp == (struct dirent *)0)
			return (struct dirent *)0;
		const char *n = dp->d_name;
		if (n[0] == '.' && (n[1] == '\0' || (n[1] == '.' && n[2] == '\0')))
			continue;
		return dp;
	}
}

/* dirfd/fchdir: the reduced kernel has no fd->DIR mapping the fallback can
 * fchdir through; return -1 so pwd's robust path uses chdir("..") instead.
 * (This path is unreachable anyway -- xgetcwd succeeds via SYS_getcwd.) */
static inline int dirfd(DIR *d) { (void)d; return (-1); }
static inline int fchdir(int fd) { (void)fd; errno = 89 /*ENOSYS*/; return (-1); }

#ifndef ERANGE
#define ERANGE 34
#endif


/* ===== ENV.C GLUE (compile blockers + signals + execvp) ===== */
#include <signal.h>

typedef long intptr_t;
#ifndef EXIT_CANCELED
#define EXIT_CANCELED     125
#define EXIT_CANNOT_INVOKE 126
#define EXIT_ENOENT       127
#endif
#ifndef ENOENT
#define ENOENT 2
#endif

/* system.h: C-locale whitespace chars env accepts in its short-opt string. */
#define C_ISSPACE_CHARS " \t\n\v\f\r"

/* error.c (gnulib): exit_failure is the status error() exits with; env sets it. */
static int exit_failure = 1;
static inline void initialize_exit_failure(int status) { exit_failure = status; }

/* xstrdup.c (gnulib): strdup + xalloc_die on OOM. */
static inline char *xstrdup(const char *s2)
{
	char *r = strdup(s2);
	if (!r) xalloc_die();
	return r;
}

/* x2nrealloc (gnulib xalloc): grow *pn by ~1.5x, realloc, xalloc_die on OOM.
 * env uses it to grow the unset-var vector; a doubling growth is fine. */
static inline void *x2nrealloc(void *p, size_t *pn, size_t s)
{
	size_t n = *pn;
	if (!p) {
		if (n == 0) n = 16;
	} else {
		n += n / 2 + 1;
	}
	void *q = realloc(p, n * s);
	if (!q) xalloc_die();
	*pn = n;
	return q;
}

/* env's devmsg (--debug tracing): C-locale fprintf to stderr (from stdio). */
#define devmsg(...) ((void) fprintf(stderr, __VA_ARGS__))
#ifndef IDX_MAX
#define IDX_MAX 0x7fffffffffffffffL
#endif
#ifndef INT_MAX
#define INT_MAX 0x7fffffff
#endif

/* sig2str.h (gnulib): fixed name<->number tables, small C-locale reduction.
 * SIG2STR_MAX bounds the "SIGRTMAX+n" form; here the plain names suffice. */
#define SIG2STR_MAX 17
#define SIGNUM_BOUND (NSIG)
struct __signame { int num; const char *name; };
static const struct __signame __signames[] = {
	{SIGHUP,"HUP"},{SIGINT,"INT"},{SIGQUIT,"QUIT"},{SIGILL,"ILL"},
	{SIGKILL,"KILL"},{SIGSEGV,"SEGV"},{SIGPIPE,"PIPE"},{SIGALRM,"ALRM"},
	{SIGTERM,"TERM"},{SIGUSR1,"USR1"},{SIGUSR2,"USR2"},{SIGCHLD,"CHLD"},
	{SIGCONT,"CONT"},{SIGSTOP,"STOP"},{SIGTSTP,"TSTP"},
};
/* sig2str: fill BUF with the bare signal name (no "SIG"); 0 ok, -1 unknown. */
static inline int sig2str(int signum, char *buf)
{
	unsigned i;
	for (i = 0; i < sizeof(__signames)/sizeof(__signames[0]); i++)
		if (__signames[i].num == signum) {
			const char *n = __signames[i].name;
			while (*n) *buf++ = *n++;
			*buf = 0;
			return 0;
		}
	return -1;
}
/* operand2sig (coreutils lib): number or NAME -> signal number, -1 on error. */
static inline int operand2sig(const char *operand)
{
	if (c_isdigit((unsigned char)*operand)) {
		char *end;
		long l = strtol(operand, &end, 10);
		if (operand == end || *end)
			return -1;
		int i = (int)l;
		return (i & (i >= 0xFF ? 0xFF : 0x7F));
	}
	const char *p = operand;
	if (p[0]=='S' && p[1]=='I' && p[2]=='G') p += 3;
	unsigned i;
	for (i = 0; i < sizeof(__signames)/sizeof(__signames[0]); i++) {
		const char *n = __signames[i].name, *q = p;
		while (*n && *q && ((*n)|32)==((*q)|32)) { n++; q++; }
		if (*n==0 && *q==0)
			return __signames[i].num;
	}
	return -1;
}

/* xpalloc (gnulib lib/xalloc): geometric array growth (env's split buffer). */
#ifndef _PTRDIFF_T_DEFINED
typedef long ptrdiff_t;
#endif
static inline void *xpalloc(void *pa, idx_t *pn, idx_t n_incr_min, ptrdiff_t n_max, idx_t s)
{
	idx_t n = *pn, nnew = n ? n * 2 : 8;
	if (nnew < n + n_incr_min) nnew = n + n_incr_min;
	if (n_max >= 0 && nnew > (idx_t) n_max) nnew = (idx_t) n_max;
	void *p = realloc(pa, (size_t) nnew * (size_t) s);
	if (!p) xalloc_die();
	*pn = nnew;
	return p;
}

/* strtok (C89) -- env splits an -S/--split-string operand on commas. */
static inline char *strtok(char *str, const char *delim)
{
	static char *save;
	if (str) save = str;
	if (!save) return (char *)0;
	while (*save && strchr(delim, *save)) save++;
	if (!*save) { save = (char *)0; return (char *)0; }
	char *tok = save;
	while (*save && !strchr(delim, *save)) save++;
	if (*save) { *save = 0; save++; } else save = (char *)0;
	return tok;
}

/* POSIX sigset ops on the libc's scalar sigset_t (1 bit per signal). */
static inline int sigemptyset(sigset_t *s) { *s = 0; return 0; }
static inline int sigfillset(sigset_t *s)  { *s = ~0UL; return 0; }
static inline int sigaddset(sigset_t *s, int n)
	{ if (n<1||n>=NSIG) { errno=22; return -1; } *s |= (1UL<<n); return 0; }
static inline int sigdelset(sigset_t *s, int n)
	{ if (n<1||n>=NSIG) { errno=22; return -1; } *s &= ~(1UL<<n); return 0; }
static inline int sigismember(const sigset_t *s, int n)
	{ if (n<1||n>=NSIG) { errno=22; return -1; } return (*s>>n)&1; }

#define SIG_BLOCK   0
#define SIG_UNBLOCK 1
#define SIG_SETMASK 2
extern int sigprocmask(int how, const sigset_t *set, sigset_t *old);

/* system.h: main_exit flushes stdout then exits (like close_stdout+exit). */
extern int fflush(FILE *);
static inline void main_exit(int status) { fflush(stdout); exit(status); }

/* system.h: emit_exec_status -- the exec-status help note (usage epilogue). */
static inline void emit_exec_status(const char *program)
{
	(void)program;
	fputs("\nExit status:\n"
	      "  125  if the env command itself fails\n"
	      "  126  if COMMAND is found but cannot be invoked\n"
	      "  127  if COMMAND cannot be found\n"
	      "  -    the exit status of COMMAND otherwise\n", stdout);
}

/* execvp: search PATH for FILE (or use it directly if it has a '/'), exec. */
extern int execve(const char *path, char *const argv[], char *const envp[]);
extern char **environ;
static inline int execvp(const char *file, char *const argv[])
{
	if (strchr(file, '/'))
		return execve(file, argv, environ);
	/* search a minimal PATH; the reduced env's default PATH is /bin. */
	static char pbuf[256];
	const char *dirs = getenv("PATH");
	if (!dirs || !*dirs) dirs = "/bin";
	const char *d = dirs;
	while (*d) {
		const char *e = d;
		while (*e && *e != ':') e++;
		size_t dl = (size_t)(e - d), fl = strlen(file);
		if (dl + 1 + fl + 1 < sizeof pbuf) {
			memcpy(pbuf, d, dl);
			pbuf[dl] = '/';
			memcpy(pbuf + dl + 1, file, fl);
			pbuf[dl + 1 + fl] = 0;
			execve(pbuf, argv, environ);
		}
		d = (*e == ':') ? e + 1 : e;
	}
	errno = ENOENT;
	return -1;
}

#endif /* CU3_GLUE_H */
