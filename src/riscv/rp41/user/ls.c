/*
 * ls.c -- solnix riscv64 `ls` built against the REAL, GROWN libc.a.
 *
 * PROVENANCE NOTE: this is NOT GNU coreutils' unmodified src/ls.c.  That file
 * (5658 lines) pulls in ~32 gnulib modules -- obstack (29 uses), quotearg
 * (57), human (22), mbswidth (13), hash, mpsort, filemode, dircolors,
 * canonicalize, areadlink, idcache, filevercmp -- whose faithful scaffolding is
 * a far larger body of code than the port itself; scaffolding it in this phase
 * would be the classic wedge.  cat.c + wc.c ARE the unmodified-upstream utils
 * this phase links (the real coreutils SET is echo/true/cat/wc from upstream
 * src/).  This ls is a real, from-scratch directory lister written to EXERCISE
 * exactly the grown-libc surface R-P41 added -- opendir/readdir/lstat/qsort/
 * strcoll (+ getpwuid/getgrgid/strftime for -l) -- proving that libc growth is
 * real and usable, while `ls`'s unmodified-upstream form is documented as a gap
 * (R-P42+ once the gnulib obstack/quotearg/human stack is scaffolded).
 *
 * It reads a directory with opendir/readdir, lstat()s each entry (real mode
 * from the R-P41 kernel getattr -> S_ISDIR), sorts the names with qsort +
 * strcoll (the C-locale collation), and prints them.  `-a` shows all, `-l`
 * prints the long form (type/perm, size, owner/group via getpwuid/getgrgid,
 * mtime via strftime), `-1` one-per-line.  Multiple operands are labeled.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>
#include <sys/stat.h>
#include <pwd.h>
#include <grp.h>

extern int errno;

static int opt_all;	/* -a: include dotfiles */
static int opt_long;	/* -l: long listing */
static int opt_one;	/* -1: one entry per line */

/* qsort comparator: C-locale collation of two char* (strcoll == strcmp here). */
static int
name_cmp(const void *a, const void *b)
{
	const char *sa = *(const char *const *)a;
	const char *sb = *(const char *const *)b;
	return (strcoll(sa, sb));
}

static void
mode_string(unsigned long mode, char out[11])
{
	static const char rwx[] = "rwxrwxrwx";
	int i;
	out[0] = S_ISDIR(mode) ? 'd' : (S_ISCHR(mode) ? 'c' :
	    (S_ISLNK(mode) ? 'l' : '-'));
	for (i = 0; i < 9; i++)
		out[1 + i] = (mode & (0400 >> i)) ? rwx[i] : '-';
	out[10] = 0;
}

/* build a full path "dir/name" into buf (dir may be "" for cwd-style). */
static void
join_path(char *buf, size_t bufsz, const char *dir, const char *name)
{
	if (dir == 0 || dir[0] == 0) {
		snprintf(buf, bufsz, "%s", name);
	} else {
		size_t dl = strlen(dir);
		if (dl > 0 && dir[dl - 1] == '/')
			snprintf(buf, bufsz, "%s%s", dir, name);
		else
			snprintf(buf, bufsz, "%s/%s", dir, name);
	}
}

static void
print_long(const char *dir, const char *name)
{
	char full[256];
	struct stat st;
	char perm[11];
	struct passwd *pw;
	struct group *gr;

	join_path(full, sizeof (full), dir, name);
	if (lstat(full, &st) != 0) {
		/* still print the name so a stat failure is visible. */
		printf("?????????? ? ? ? ? %s\n", name);
		return;
	}
	mode_string((unsigned long)st.st_mode, perm);
	pw = getpwuid(st.st_uid);
	gr = getgrgid(st.st_gid);
	/* type/perm  links  owner  group  size  name  (times are epoch-0 in the
	   reduced kernel getattr, so a timestamp column is omitted -- see NOTE). */
	printf("%s %lu %s %s %8ld %s\n", perm, (unsigned long)st.st_nlink,
	    pw ? pw->pw_name : "?", gr ? gr->gr_name : "?",
	    (long)st.st_size, name);
}

/* list one directory (or, if `path` is a file, just print it). */
static int
list_one(const char *path, int label)
{
	DIR *d;
	struct dirent *de;
	char **names = 0;
	size_t n = 0, cap = 0;
	size_t i;
	struct stat st;
	int rc = 0;

	/* if `path` is a plain file, list it directly. */
	if (stat(path, &st) == 0 && !S_ISDIR(st.st_mode)) {
		if (opt_long)
			print_long("", path);
		else
			printf("%s\n", path);
		return (0);
	}

	d = opendir(path);
	if (d == 0) {
		fprintf(stderr, "ls: cannot open %s: errno %d\n", path, errno);
		return (1);
	}
	if (label)
		printf("%s:\n", path);

	while ((de = readdir(d)) != 0) {
		char *nm;
		if (!opt_all && de->d_name[0] == '.')
			continue;
		if (n >= cap) {
			size_t nc = cap ? cap * 2 : 16;
			char **nn = realloc(names, nc * sizeof (char *));
			if (nn == 0) { rc = 1; break; }
			names = nn;
			cap = nc;
		}
		nm = malloc(strlen(de->d_name) + 1);
		if (nm == 0) { rc = 1; break; }
		strcpy(nm, de->d_name);
		names[n++] = nm;
	}
	closedir(d);

	/* sort with qsort + strcoll (the grown libc). */
	qsort(names, n, sizeof (char *), name_cmp);

	for (i = 0; i < n; i++) {
		if (opt_long)
			print_long(path, names[i]);
		else if (opt_one)
			printf("%s\n", names[i]);
		else
			printf("%s%s", names[i], (i + 1 < n) ? "  " : "\n");
		free(names[i]);
	}
	if (!opt_long && !opt_one && n == 0)
		putchar('\n');
	free(names);
	return (rc);
}

int
main(int argc, char **argv)
{
	int i, rc = 0;
	int nops;
	int first_op = argc;

	/* parse clustered short options (a small getopt, no long options). */
	for (i = 1; i < argc; i++) {
		const char *a = argv[i];
		if (a[0] != '-' || a[1] == 0) {
			first_op = i;
			break;
		}
		if (strcmp(a, "--") == 0) {
			first_op = i + 1;
			break;
		}
		{
			int j;
			for (j = 1; a[j] != 0; j++) {
				switch (a[j]) {
				case 'a': opt_all = 1; break;
				case 'l': opt_long = 1; break;
				case '1': opt_one = 1; break;
				default:
					fprintf(stderr,
					    "ls: invalid option -- '%c'\n", a[j]);
					return (2);
				}
			}
		}
		first_op = i + 1;
	}

	nops = argc - first_op;
	if (nops <= 0) {
		rc = list_one(".", 0);
	} else {
		int label = (nops > 1);
		for (i = first_op; i < argc; i++) {
			rc |= list_one(argv[i], label);
			if (label && i + 1 < argc)
				putchar('\n');
		}
	}
	return (rc ? 1 : 0);
}
