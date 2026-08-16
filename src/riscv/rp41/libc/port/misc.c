/*
 * misc.c -- solnix riscv64 libc: the surface a real ls/wc references beyond the
 * R-P40 syscall/stdio/string/stdlib set.  Everything here is a real libc TU
 * compiled into libc.a (nm shows T), not a per-program shim:
 *   - qsort:     a shellsort over an opaque element array (ls sorts entries)
 *   - strcoll:   the C-locale collation == strcmp (ls -> mpsort compare)
 *   - fileno / isatty / setvbuf: stdio glue ls/wc call at startup
 *   - getpwuid / getgrgid: minimal passwd/group lookups backed by /etc/passwd,
 *     /etc/group when present, else a numeric-name synthesis (ls -l owner)
 *   - readlink: ENOSYS (the reduced fs has no symlinks; lstat==stat)
 *   - strspn/strcspn/strpbrk/strstr/strdup/strtoul/strnlen/mempcpy: string/stdlib
 *     helpers gnulib + ls reference
 *
 * CRIB PROVENANCE: qsort as a shellsort with a byte-swap of arbitrary element
 * width is the classic K&R/illumos libc qsort reduced (Sedgewick gap sequence);
 * strcoll==strcmp is the illumos C-locale collation shortcut; getpwuid/getgrgid
 * scanning /etc/passwd/group is the illumos libc getpwuid_r/getgrgid_r nsswitch
 * "files" backend reduced to a single-file scan.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pwd.h>
#include <grp.h>

extern int errno;

/* ---- qsort: shellsort over element blocks of arbitrary width ---------- */
static void
__swap(char *a, char *b, size_t w)
{
	size_t i;
	for (i = 0; i < w; i++) {
		char t = a[i];
		a[i] = b[i];
		b[i] = t;
	}
}

void
qsort(void *base, size_t n, size_t w, int (*cmp)(const void *, const void *))
{
	char *a = base;
	size_t gap, i, j;
	if (n < 2 || w == 0)
		return;
	for (gap = n / 2; gap > 0; gap /= 2) {
		for (i = gap; i < n; i++) {
			for (j = i; j >= gap; j -= gap) {
				char *x = a + (j - gap) * w;
				char *y = a + j * w;
				if (cmp(x, y) <= 0)
					break;
				__swap(x, y, w);
			}
		}
	}
}

void *
bsearch(const void *key, const void *base, size_t n, size_t w,
    int (*cmp)(const void *, const void *))
{
	const char *a = base;
	size_t lo = 0, hi = n;
	while (lo < hi) {
		size_t mid = lo + (hi - lo) / 2;
		int r = cmp(key, a + mid * w);
		if (r == 0)
			return ((void *)(a + mid * w));
		if (r < 0)
			hi = mid;
		else
			lo = mid + 1;
	}
	return ((void *)0);
}

/* ---- collation: C locale == byte compare ------------------------------ */
int strcoll(const char *a, const char *b) { return (strcmp(a, b)); }

/* ---- more string helpers gnulib/ls reference -------------------------- */
size_t
strnlen(const char *s, size_t max)
{
	size_t n = 0;
	while (n < max && s[n] != 0)
		n++;
	return (n);
}

char *
strdup(const char *s)
{
	size_t n = strlen(s) + 1;
	char *p = malloc(n);
	if (p != (void *)0)
		memcpy(p, s, n);
	return (p);
}

void *
mempcpy(void *d, const void *s, size_t n)
{
	return ((char *)memcpy(d, s, n) + n);
}

size_t
strspn(const char *s, const char *set)
{
	size_t n = 0;
	while (s[n] != 0 && strchr(set, s[n]) != 0)
		n++;
	return (n);
}

size_t
strcspn(const char *s, const char *set)
{
	size_t n = 0;
	while (s[n] != 0 && strchr(set, s[n]) == 0)
		n++;
	return (n);
}

char *
strpbrk(const char *s, const char *set)
{
	for (; *s != 0; s++)
		if (strchr(set, *s) != 0)
			return ((char *)s);
	return ((void *)0);
}

char *
strstr(const char *hay, const char *needle)
{
	size_t nl = strlen(needle);
	if (nl == 0)
		return ((char *)hay);
	for (; *hay != 0; hay++)
		if (*hay == *needle && strncmp(hay, needle, nl) == 0)
			return ((char *)hay);
	return ((void *)0);
}

void *
memchr(const void *s, int c, size_t n)
{
	const unsigned char *p = s;
	size_t i;
	for (i = 0; i < n; i++)
		if (p[i] == (unsigned char)c)
			return ((void *)(p + i));
	return ((void *)0);
}

unsigned long
strtoul(const char *s, char **endp, int base)
{
	unsigned long v = 0;
	int neg = 0;
	while (*s == ' ' || *s == '\t')
		s++;
	if (*s == '+') s++;
	else if (*s == '-') { neg = 1; s++; }
	if ((base == 0 || base == 16) && s[0] == '0' &&
	    (s[1] == 'x' || s[1] == 'X')) {
		s += 2;
		base = 16;
	} else if (base == 0 && s[0] == '0') {
		base = 8;
	} else if (base == 0) {
		base = 10;
	}
	for (;;) {
		int d;
		char c = *s;
		if (c >= '0' && c <= '9') d = c - '0';
		else if (c >= 'a' && c <= 'z') d = c - 'a' + 10;
		else if (c >= 'A' && c <= 'Z') d = c - 'A' + 10;
		else break;
		if (d >= base)
			break;
		v = v * (unsigned long)base + (unsigned long)d;
		s++;
	}
	if (endp != 0)
		*endp = (char *)s;
	return (neg ? (unsigned long)(-(long)v) : v);
}

/* ---- stdio glue: fileno / isatty / setvbuf ---------------------------- */
int
fileno(FILE *f)
{
	return (f != 0 ? f->fd : -1);
}

int
isatty(int fd)
{
	/* the reduced kernel: fds 0/1/2 are the console tty; files are not. */
	return (fd >= 0 && fd <= 2) ? 1 : 0;
}

int
setvbuf(FILE *f, char *buf, int mode, size_t size)
{
	(void) f; (void) buf; (void) mode; (void) size;
	return (0);		/* buffering policy is fixed in this libc */
}

/* ---- getpwuid / getgrgid: /etc/passwd|group scan, else numeric -------- */
/* parse "name:passwd:id:..." for the entry whose 3rd field == id; return name
   into `namebuf` (static), or synthesize the decimal id.  A single-record scan
   of the "files" nsswitch backend reduced to one /etc file. */
static const char *
id_to_name(const char *path, unsigned long id, char *namebuf, size_t nsz)
{
	FILE *f = fopen(path, "r");
	char line[256];
	if (f != 0) {
		while (fgets(line, sizeof (line), f) != 0) {
			char *name = line;
			char *p = line;
			int col = 0;
			unsigned long fid = 0;
			while (*p != 0 && *p != '\n') {
				if (*p == ':') {
					*p = 0;
					col++;
					if (col == 2) {
						/* 3rd field starts here: the id. */
						char *q = p + 1;
						fid = strtoul(q, 0, 10);
						if (fid == id) {
							size_t k = 0;
							while (name[k] != 0 &&
							    k + 1 < nsz) {
								namebuf[k] =
								    name[k];
								k++;
							}
							namebuf[k] = 0;
							fclose(f);
							return (namebuf);
						}
					}
				}
				p++;
			}
		}
		fclose(f);
	}
	/* not found (or no file): synthesize the decimal id. */
	{
		char tmp[32];
		int i = 0, k;
		unsigned long v = id;
		if (v == 0)
			tmp[i++] = '0';
		while (v > 0) { tmp[i++] = (char)('0' + v % 10); v /= 10; }
		for (k = 0; k < i && (size_t)k + 1 < nsz; k++)
			namebuf[k] = tmp[i - 1 - k];
		namebuf[k] = 0;
	}
	return (namebuf);
}

struct passwd *
getpwuid(uid_t uid)
{
	static struct passwd pw;
	static char nbuf[64];
	pw.pw_name = (char *)id_to_name("/etc/passwd", (unsigned long)uid,
	    nbuf, sizeof (nbuf));
	pw.pw_passwd = (char *)"x";
	pw.pw_uid = uid;
	pw.pw_gid = 0;
	pw.pw_gecos = (char *)"";
	pw.pw_dir = (char *)"/";
	pw.pw_shell = (char *)"/bin/sh";
	return (&pw);
}

struct group *
getgrgid(gid_t gid)
{
	static struct group gr;
	static char nbuf[64];
	static char *nomem[1] = { 0 };
	gr.gr_name = (char *)id_to_name("/etc/group", (unsigned long)gid,
	    nbuf, sizeof (nbuf));
	gr.gr_passwd = (char *)"x";
	gr.gr_gid = gid;
	gr.gr_mem = nomem;
	return (&gr);
}

/* ---- readlink: no symlinks in the reduced fs -------------------------- */
long
readlink(const char *path, char *buf, unsigned long bufsz)
{
	(void) path; (void) buf; (void) bufsz;
	errno = 22;		/* EINVAL: not a symlink */
	return (-1);
}
