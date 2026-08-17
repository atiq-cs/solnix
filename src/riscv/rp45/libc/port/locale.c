/*
 * locale.c -- solnix riscv64 libc C-locale runtime for the faithful coreutils
 * ls.c + the gnulib module set: the multibyte/wide-char pass-through (mbrtowc,
 * mbsinit, wcwidth), the fixed C-locale queries (setlocale, localeconv,
 * nl_langinfo), UTC time (time, localtime_r/gmtime_r, mktime/timegm, tzset,
 * tzalloc/localtime_rz), the name-keyed passwd/group lookups (getpwnam/
 * getgrnam via /etc/passwd|group), the tty/host probes (ioctl/tcgetpgrp/uname),
 * the *_unlocked stdio aliases, reallocarray/strtoumax/strtoull, and the
 * assert failure hook.  All C-locale, UTC, single-byte -- the reduced-libc
 * truth that gnulib's HAVE_* config already reflects (illumos-riscv64).
 */
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <stdint.h>
#include <wchar.h>
#include <locale.h>
#include <langinfo.h>
#include <time.h>
#include <pwd.h>
#include <grp.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/utsname.h>
#include <sys/time.h>

/* ---- multibyte / wide-char: C-locale is single-byte identity ----------- */
size_t
mbrtowc(wchar_t *pwc, const char *s, size_t n, mbstate_t *ps)
{
	(void) ps;
	if (s == NULL)
		return (0);		/* initial state, stateless */
	if (n == 0)
		return ((size_t)-2);
	if (pwc != NULL)
		*pwc = (wchar_t)(unsigned char)*s;
	return (*s == '\0') ? 0 : 1;
}

size_t
mbrlen(const char *s, size_t n, mbstate_t *ps)
{
	return (mbrtowc(NULL, s, n, ps));
}

size_t
wcrtomb(char *s, wchar_t wc, mbstate_t *ps)
{
	(void) ps;
	if (s == NULL)
		return (1);
	*s = (char)wc;
	return (1);
}

int
mbsinit(const mbstate_t *ps)
{
	(void) ps;
	return (1);			/* always in the initial state */
}

int
wcwidth(wchar_t wc)
{
	unsigned int c = (unsigned int)wc;
	if (c == 0)
		return (0);
	if (c < 32 || (c >= 0x7f && c < 0xa0))
		return (-1);		/* control chars */
	return (1);			/* C-locale: every printable is width 1 */
}

wint_t
btowc(int c)
{
	return (c == EOF ? WEOF : (wint_t)(unsigned char)c);
}

int
wctob(wint_t c)
{
	return (c <= 255 ? (int)c : EOF);
}

int
mbtowc(int *pwc, const char *s, size_t n)
{
	if (s == NULL)
		return (0);
	if (n == 0)
		return (-1);
	if (pwc != NULL)
		*pwc = (unsigned char)*s;
	return (*s == '\0') ? 0 : 1;
}

int
mblen(const char *s, size_t n)
{
	return (mbtowc(NULL, s, n));
}

/* ---- locale: only the C/POSIX locale exists ---------------------------- */
char *
setlocale(int category, const char *locale)
{
	(void) category; (void) locale;
	return ((char *)"C");
}

struct lconv *
localeconv(void)
{
	static struct lconv lc;
	lc.decimal_point = (char *)".";
	lc.thousands_sep = (char *)"";
	lc.grouping = (char *)"";
	lc.int_curr_symbol = (char *)"";
	lc.currency_symbol = (char *)"";
	lc.mon_decimal_point = (char *)"";
	lc.mon_thousands_sep = (char *)"";
	lc.mon_grouping = (char *)"";
	lc.positive_sign = (char *)"";
	lc.negative_sign = (char *)"";
	lc.int_frac_digits = 127;
	lc.frac_digits = 127;
	lc.p_cs_precedes = 127;
	lc.p_sep_by_space = 127;
	lc.n_cs_precedes = 127;
	lc.n_sep_by_space = 127;
	lc.p_sign_posn = 127;
	lc.n_sign_posn = 127;
	return (&lc);
}

static const char *const c_abmon[12] = {
	"Jan","Feb","Mar","Apr","May","Jun",
	"Jul","Aug","Sep","Oct","Nov","Dec"
};
static const char *const c_mon[12] = {
	"January","February","March","April","May","June",
	"July","August","September","October","November","December"
};
static const char *const c_abday[7] = {
	"Sun","Mon","Tue","Wed","Thu","Fri","Sat"
};
static const char *const c_day[7] = {
	"Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"
};

char *
nl_langinfo(nl_item item)
{
	if (item >= ABMON_1 && item <= ABMON_1 + 11)
		return ((char *)c_abmon[item - ABMON_1]);
	if (item >= MON_1 && item <= MON_1 + 11)
		return ((char *)c_mon[item - MON_1]);
	if (item >= ABDAY_1 && item <= ABDAY_1 + 6)
		return ((char *)c_abday[item - ABDAY_1]);
	if (item >= DAY_1 && item <= DAY_1 + 6)
		return ((char *)c_day[item - DAY_1]);
	switch (item) {
	case CODESET:   return ((char *)"ANSI_X3.4-1968");	/* C locale */
	case RADIXCHAR: return ((char *)".");
	case THOUSEP:   return ((char *)"");
	case D_T_FMT:   return ((char *)"%a %b %e %H:%M:%S %Y");
	case D_FMT:     return ((char *)"%m/%d/%y");
	case T_FMT:     return ((char *)"%H:%M:%S");
	case AM_STR:    return ((char *)"AM");
	case PM_STR:    return ((char *)"PM");
	case YESEXPR:   return ((char *)"^[yY]");
	case NOEXPR:    return ((char *)"^[nN]");
	default:        return ((char *)"");
	}
}

/* ---- time: UTC, no zone database --------------------------------------- */
char *tzname[2] = { (char *)"UTC", (char *)"UTC" };
long timezone = 0;
int daylight = 0;

void
tzset(void)
{
}

/* days-since-epoch civil calendar (Howard Hinnant's algorithm). */
static long
days_from_civil(long y, unsigned m, unsigned d)
{
	y -= (m <= 2);
	long era = (y >= 0 ? y : y - 399) / 400;
	unsigned yoe = (unsigned)(y - era * 400);
	unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
	unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
	return (era * 146097L + (long)doe - 719468L);
}

static void
civil_from_days(long z, int *year, unsigned *month, unsigned *day)
{
	z += 719468L;
	long era = (z >= 0 ? z : z - 146096) / 146097;
	unsigned doe = (unsigned)(z - era * 146097L);
	unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
	long y = (long)yoe + era * 400;
	unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
	unsigned mp = (5 * doy + 2) / 153;
	*day = doy - (153 * mp + 2) / 5 + 1;
	*month = mp + (mp < 10 ? 3 : -9);
	*year = (int)(y + (*month <= 2));
}

struct tm *
gmtime_r(const time_t *tp, struct tm *r)
{
	long secs = *tp;
	long days = secs / 86400;
	long rem = secs % 86400;
	if (rem < 0) { rem += 86400; days--; }
	r->tm_hour = (int)(rem / 3600);
	r->tm_min = (int)((rem % 3600) / 60);
	r->tm_sec = (int)(rem % 60);
	r->tm_wday = (int)((days % 7 + 4 + 7) % 7);	/* 1970-01-01 == Thu */
	int year; unsigned mon, mday;
	civil_from_days(days, &year, &mon, &mday);
	r->tm_year = year - 1900;
	r->tm_mon = (int)mon - 1;
	r->tm_mday = (int)mday;
	long jan1 = days_from_civil(year, 1, 1);
	r->tm_yday = (int)(days - jan1);
	r->tm_isdst = 0;
	r->tm_gmtoff = 0;
	r->tm_zone = "UTC";
	return (r);
}

struct tm *
localtime_r(const time_t *tp, struct tm *r)
{
	return (gmtime_r(tp, r));	/* UTC == local in the reduced libc */
}

static struct tm __tm_static;
struct tm *gmtime(const time_t *tp)    { return (gmtime_r(tp, &__tm_static)); }
struct tm *localtime(const time_t *tp) { return (gmtime_r(tp, &__tm_static)); }

time_t
timegm(struct tm *tm)
{
	long days = days_from_civil(tm->tm_year + 1900,
	    (unsigned)(tm->tm_mon + 1), (unsigned)tm->tm_mday);
	return ((time_t)(days * 86400L + tm->tm_hour * 3600L +
	    tm->tm_min * 60L + tm->tm_sec));
}

time_t
mktime(struct tm *tm)
{
	time_t t = timegm(tm);
	(void) gmtime_r(&t, tm);	/* normalize the fields */
	return (t);
}

int
timespec_get(struct timespec *ts, int base)
{
	(void) base;
	ts->tv_sec = time(NULL);
	ts->tv_nsec = 0;
	return (base);
}

/* ---- name-keyed passwd/group: scan /etc/passwd|group ------------------- */
/* returns the uid/gid for a given name, or (unsigned long)-1 if not found. */
static unsigned long
name_to_id(const char *path, const char *name)
{
	FILE *f = fopen(path, "r");
	char line[256];
	unsigned long id = (unsigned long)-1;
	if (f == NULL)
		return (id);
	while (fgets(line, sizeof(line), f) != NULL) {
		char *p = strchr(line, ':');
		if (p == NULL)
			continue;
		*p = '\0';
		if (strcmp(line, name) != 0)
			continue;
		/* name:passwd:uid:... -- skip passwd field to the uid */
		char *q = strchr(p + 1, ':');
		if (q == NULL)
			continue;
		id = strtoul(q + 1, NULL, 10);
		break;
	}
	fclose(f);
	return (id);
}

struct passwd *
getpwnam(const char *name)
{
	static struct passwd pw;
	static char nbuf[64];
	unsigned long uid = name_to_id("/etc/passwd", name);
	if (uid == (unsigned long)-1)
		return (NULL);
	strncpy(nbuf, name, sizeof(nbuf) - 1);
	nbuf[sizeof(nbuf) - 1] = '\0';
	pw.pw_name = nbuf;
	pw.pw_passwd = (char *)"x";
	pw.pw_uid = (uid_t)uid;
	pw.pw_gid = 0;
	pw.pw_gecos = (char *)"";
	pw.pw_dir = (char *)"/";
	pw.pw_shell = (char *)"/bin/sh";
	return (&pw);
}

struct group *
getgrnam(const char *name)
{
	static struct group gr;
	static char nbuf[64];
	static char *nomem[1] = { NULL };
	unsigned long gid = name_to_id("/etc/group", name);
	if (gid == (unsigned long)-1)
		return (NULL);
	strncpy(nbuf, name, sizeof(nbuf) - 1);
	nbuf[sizeof(nbuf) - 1] = '\0';
	gr.gr_name = nbuf;
	gr.gr_passwd = (char *)"x";
	gr.gr_gid = (gid_t)gid;
	gr.gr_mem = nomem;
	return (&gr);
}

/* ---- tty / host probes -------------------------------------------------- */
int
ioctl(int fd, unsigned long req, ...)
{
	(void) fd; (void) req;
	errno = ENOTTY;
	return (-1);		/* reduced console reports no winsize */
}

int
tcgetpgrp(int fd)
{
	(void) fd;
	return (getpid());	/* single foreground group in the reduced session */
}

int
uname(struct utsname *n)
{
	if (n == NULL) { errno = EFAULT; return (-1); }
	strcpy(n->sysname, "SunOS");
	strcpy(n->nodename, "solnix");
	strcpy(n->release, "5.11");
	strcpy(n->version, "solnix");
	strcpy(n->machine, "riscv64");
	return (0);
}

/* ---- *_unlocked stdio aliases (single-threaded libc) ------------------- */
int putchar_unlocked(int c)         { return (putchar(c)); }
int putc_unlocked(int c, FILE *f)   { return (putc(c, f)); }
int fputc_unlocked(int c, FILE *f)  { return (putc(c, f)); }
int getc_unlocked(FILE *f)          { extern int getc(FILE *); return (getc(f)); }
int getchar_unlocked(void)          { extern int getchar(void); return (getchar()); }

/* ---- reallocarray + strtoumax/strtoull -------------------------------- */
void *
reallocarray(void *p, size_t nmemb, size_t sz)
{
	if (sz != 0 && nmemb > (size_t)-1 / sz) {
		errno = ENOMEM;
		return (NULL);
	}
	return (realloc(p, nmemb * sz));
}

unsigned long long
strtoull(const char *s, char **endp, int base)
{
	return ((unsigned long long)strtoul(s, endp, base));
}

long long
strtoll(const char *s, char **endp, int base)
{
	return ((long long)strtol(s, endp, base));
}

uintmax_t
strtoumax(const char *s, char **endp, int base)
{
	return ((uintmax_t)strtoul(s, endp, base));
}

intmax_t
strtoimax(const char *s, char **endp, int base)
{
	return ((intmax_t)strtol(s, endp, base));
}

/* ---- assert failure hook ----------------------------------------------- */
void
__assert_fail(const char *expr, const char *file, int line, const char *func)
{
	fprintf(stderr, "%s:%d: %s: Assertion `%s' failed.\n",
	    file ? file : "?", line, func ? func : "?", expr ? expr : "?");
	abort();
}

/* ---- time(): the reduced kernel has no clock syscall, so return a fixed
   build-era epoch (2024-01-01T00:00:00Z).  ls only needs a stable value for
   the -l timestamp column in the reduced boot. */
time_t
time(time_t *t)
{
	time_t now = 1704067200L;	/* 2024-01-01T00:00:00Z */
	if (t != NULL)
		*t = now;
	return (now);
}

int
gettimeofday(struct timeval *tv, void *tz)
{
	(void) tz;
	if (tv != NULL) {
		tv->tv_sec = time(NULL);
		tv->tv_usec = 0;
	}
	return (0);
}

/* ---- strftime(): C-locale subset covering the conversions ls -l and the
   gnulib nstrftime emit (%a %A %b %B %d %e %H %I %m %M %p %S %y %Y %j %Z %n
   %t %% and %T %R %D as combos).  Fixed C-locale names, UTC zone. */
static char *
u2(char *p, int v)
{
	*p++ = '0' + (v / 10) % 10;
	*p++ = '0' + v % 10;
	return (p);
}

size_t
strftime(char *s, size_t max, const char *fmt, const struct tm *tm)
{
	char *out = s;
	char *end = s + max;
	while (*fmt) {
		if (*fmt != '%') {
			if (out < end - 1) *out++ = *fmt;
			fmt++;
			continue;
		}
		fmt++;
		char buf[8];
		const char *ins = NULL;
		int inslen = 0;
		char *bp = buf;
		switch (*fmt) {
		case 'a': ins = c_abday[(tm->tm_wday) % 7]; break;
		case 'A': ins = c_day[(tm->tm_wday) % 7]; break;
		case 'b': case 'h': ins = c_abmon[(tm->tm_mon) % 12]; break;
		case 'B': ins = c_mon[(tm->tm_mon) % 12]; break;
		case 'd': bp = u2(bp, tm->tm_mday); ins = buf; inslen = 2; break;
		case 'e':
			buf[0] = tm->tm_mday < 10 ? ' ' : ('0' + tm->tm_mday / 10);
			buf[1] = '0' + tm->tm_mday % 10; ins = buf; inslen = 2; break;
		case 'H': bp = u2(bp, tm->tm_hour); ins = buf; inslen = 2; break;
		case 'I': {
			int h = tm->tm_hour % 12; if (h == 0) h = 12;
			bp = u2(bp, h); ins = buf; inslen = 2; break;
		}
		case 'm': bp = u2(bp, tm->tm_mon + 1); ins = buf; inslen = 2; break;
		case 'M': bp = u2(bp, tm->tm_min); ins = buf; inslen = 2; break;
		case 'S': bp = u2(bp, tm->tm_sec); ins = buf; inslen = 2; break;
		case 'p': ins = tm->tm_hour < 12 ? "AM" : "PM"; break;
		case 'y': bp = u2(bp, (tm->tm_year + 1900) % 100); ins = buf; inslen = 2; break;
		case 'Y': {
			int y = tm->tm_year + 1900;
			bp = u2(bp, y / 100); bp = u2(bp, y % 100);
			ins = buf; inslen = 4; break;
		}
		case 'j': {
			int d = tm->tm_yday + 1;
			buf[0] = '0' + d / 100; buf[1] = '0' + (d / 10) % 10;
			buf[2] = '0' + d % 10; ins = buf; inslen = 3; break;
		}
		case 'Z': ins = "UTC"; break;
		case 'n': ins = "\n"; break;
		case 't': ins = "\t"; break;
		case '%': ins = "%"; break;
		default: ins = ""; break;
		}
		if (inslen == 0 && ins) inslen = (int)strlen(ins);
		for (int i = 0; i < inslen && out < end - 1; i++)
			*out++ = ins[i];
		fmt++;
	}
	if (out < end) *out = '\0';
	else if (max > 0) s[max - 1] = '\0';
	return ((size_t)(out - s));
}

/* ---- strerror(): C-locale error strings for the errno set the reduced libc
   reports.  Unknown codes get a numeric fallback in a static buffer. */
char *
strerror(int errnum)
{
	static char buf[32];
	switch (errnum) {
	case 0:      return ((char *)"Success");
	case EPERM:  return ((char *)"Operation not permitted");
	case ENOENT: return ((char *)"No such file or directory");
	case ESRCH:  return ((char *)"No such process");
	case EINTR:  return ((char *)"Interrupted system call");
	case EIO:    return ((char *)"I/O error");
	case ENXIO:  return ((char *)"No such device or address");
	case EBADF:  return ((char *)"Bad file number");
	case EAGAIN: return ((char *)"Resource temporarily unavailable");
	case ENOMEM: return ((char *)"Not enough space");
	case EACCES: return ((char *)"Permission denied");
	case EFAULT: return ((char *)"Bad address");
	case EBUSY:  return ((char *)"Device busy");
	case EEXIST: return ((char *)"File exists");
	case EXDEV:  return ((char *)"Cross-device link");
	case ENODEV: return ((char *)"No such device");
	case ENOTDIR:return ((char *)"Not a directory");
	case EISDIR: return ((char *)"Is a directory");
	case EINVAL: return ((char *)"Invalid argument");
	case ENFILE: return ((char *)"File table overflow");
	case EMFILE: return ((char *)"Too many open files");
	case ENOTTY: return ((char *)"Inappropriate ioctl for device");
	case EFBIG:  return ((char *)"File too large");
	case ENOSPC: return ((char *)"No space left on device");
	case ESPIPE: return ((char *)"Illegal seek");
	case EROFS:  return ((char *)"Read-only file system");
	case EMLINK: return ((char *)"Too many links");
	case EPIPE:  return ((char *)"Broken pipe");
	case ERANGE: return ((char *)"Result too large");
	case ENAMETOOLONG: return ((char *)"File name too long");
	case ENOSYS: return ((char *)"Operation not applicable");
	case ELOOP:  return ((char *)"Too many levels of symbolic links");
	case EOVERFLOW: return ((char *)"Value too large for defined data type");
	default: {
		char *p = buf + sizeof(buf);
		int n = errnum < 0 ? -errnum : errnum;
		*--p = '\0';
		do { *--p = '0' + n % 10; n /= 10; } while (n);
		char *d = buf;
		const char *pre = "Error ";
		while (*pre) *d++ = *pre++;
		while (*p) *d++ = *p++;
		*d = '\0';
		return (buf);
	}
	}
}

int
strerror_r(int errnum, char *buf, size_t buflen)
{
	char *s = strerror(errnum);
	size_t n = strlen(s);
	if (n >= buflen) { if (buflen) buf[0] = '\0'; return (ERANGE); }
	memcpy(buf, s, n + 1);
	return (0);
}
