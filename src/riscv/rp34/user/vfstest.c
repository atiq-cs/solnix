/*
 * vfstest.c -- R-P32.3 proof: write(2) to a WRITABLE tmpfs file through the
 * vnode layer, read it back, and confirm the read-only ramfs rejects writes.
 *
 *   1. open("/tmp/hello.txt", O_CREAT) -> a fresh tmpfs vnode.
 *   2. write(fd, "solnix vfs write ...", n) -> VOP_WRITE grows the tmpfs buffer.
 *   3. close, reopen, read(fd, ...) -> VOP_READ returns the same bytes.
 *   4. fstat -> VOP_GETATTR reports the written length.
 *   5. open("/etc/release") (ramfs) + write -> VOP_WRITE returns EROFS.
 *
 * Self-contained inline syscall stubs (illumos riscv64 ABI: a7=nr, a0..a5=args,
 * result in a0), NO libc beyond crt.
 */

typedef unsigned long size_t;
typedef long ssize_t;

#define	SYS_exit	1
#define	SYS_read	3
#define	SYS_write	4
#define	SYS_open	5
#define	SYS_close	6
#define	SYS_fstat	28
#define	SYS_mkdir	236
#define	SYS_unlink	244
#define	SYS_rename	245
#define	SYS_mount	246

#define	O_CREAT		0x100

static long
sc3(long nr, long x0, long x1, long x2)
{
	register long a7 __asm__("a7") = nr;
	register long a0 __asm__("a0") = x0;
	register long a1 __asm__("a1") = x1;
	register long a2 __asm__("a2") = x2;
	__asm__ __volatile__("ecall"
	    : "+r"(a0) : "r"(a7), "r"(a1), "r"(a2) : "memory");
	return (a0);
}

static ssize_t write(int fd, const void *b, size_t n) { return (sc3(SYS_write, fd, (long)b, (long)n)); }
static void exit(int s) { sc3(SYS_exit, s, 0, 0); for (;;); }
static int open2(const char *p, int fl) { return ((int)sc3(SYS_open, (long)p, fl, 0)); }
static ssize_t read(int fd, void *b, size_t n) { return (sc3(SYS_read, fd, (long)b, (long)n)); }
static int close(int fd) { return ((int)sc3(SYS_close, fd, 0, 0)); }
static long fstat(int fd, void *st) { return (sc3(SYS_fstat, fd, (long)st, 0)); }
static long mkdir_(const char *p) { return (sc3(SYS_mkdir, (long)p, 0, 0)); }
static long unlink_(const char *p) { return (sc3(SYS_unlink, (long)p, 0, 0)); }
static long rename_(const char *a, const char *b) { return (sc3(SYS_rename, (long)a, (long)b, 0)); }
static long mount_(const char *fs, const char *p) { return (sc3(SYS_mount, (long)fs, (long)p, 0)); }

static size_t slen(const char *s) { size_t n = 0; while (s[n]) n++; return (n); }
static void puts_(const char *s) { write(1, s, slen(s)); }
static void putn(long v)
{
	char b[24]; int i = 0;
	if (v < 0) { write(1, "-", 1); v = -v; }
	if (v == 0) { write(1, "0", 1); return; }
	while (v > 0 && i < (int)sizeof (b)) { b[i++] = (char)('0' + v % 10); v /= 10; }
	while (i-- > 0) write(1, &b[i], 1);
}

static int
streq(const char *a, const char *b, size_t n)
{
	size_t i;
	for (i = 0; i < n; i++)
		if (a[i] != b[i])
			return (0);
	return (1);
}

static const char msg[] = "solnix riscv64 tmpfs write(2) works";

int
main(int argc, char **argv, char **envp)
{
	char buf[64];
	unsigned long st[4];
	int fd;
	long n;
	(void) argc; (void) argv; (void) envp;

	puts_("  [vfs] write(2) to a tmpfs file via the vnode layer:\n");

	/* 1+2: create + write. */
	fd = open2("/tmp/hello.txt", O_CREAT);
	if (fd < 0) {
		puts_("    open(/tmp/hello.txt, O_CREAT) FAILED\n");
		exit(1);
	}
	n = write(fd, msg, slen(msg));
	puts_("    wrote ");
	putn(n);
	puts_(" bytes to /tmp/hello.txt\n");
	close(fd);

	/* 3: reopen + read back. */
	fd = open2("/tmp/hello.txt", 0);
	if (fd < 0) {
		puts_("    reopen(/tmp/hello.txt) FAILED\n");
		exit(2);
	}
	n = read(fd, buf, sizeof(buf));
	puts_("    read back ");
	putn(n);
	puts_(" bytes: '");
	write(1, buf, (size_t)n);
	puts_("'\n");
	/* 4: fstat size. */
	if (fstat(fd, st) == 0) {
		puts_("    fstat size=");
		putn((long)st[0]);
		puts_("\n");
	}
	close(fd);

	if ((size_t)n == slen(msg) && streq(buf, msg, slen(msg)))
		puts_("    tmpfs write/read round-trip: MATCH\n");
	else
		puts_("    tmpfs write/read round-trip: MISMATCH\n");

	/* 5: a write to the read-only ramfs must fail (EROFS = -30). */
	fd = open2("/etc/release", 0);
	if (fd >= 0) {
		n = write(fd, msg, 4);
		puts_("    write to ramfs /etc/release returned ");
		putn(n);
		puts_(n < 0 ? " (EROFS -- ramfs is read-only, as expected)\n" :
		    " (BUG: ramfs accepted a write)\n");
		close(fd);
	}

	/* --- R-P34.3: mount tmpfs at /mnt + a multi-level path walk ------- */
	puts_("  [vfs] R-P34.3: mount tmpfs at /mnt + multi-level walk + "
	    "unlink/rename:\n");
	if (mount_("tmpfs", "/mnt") == 0)
		puts_("    mount tmpfs at /mnt: OK\n");
	else
		puts_("    mount tmpfs at /mnt: FAILED\n");
	/* a walk to a file under a MISSING dir must fail (validates the walk). */
	fd = open2("/mnt/sub/file", O_CREAT);
	puts_((fd < 0) ?
	    "    open(/mnt/sub/file) before mkdir: correctly ENOENT (walk "
	    "rejects missing dir)\n" :
	    "    BUG: opened a file under a missing directory\n");
	if (fd >= 0) close(fd);
	/* create the intermediate dir, then the file resolves. */
	mkdir_("/mnt/sub");
	fd = open2("/mnt/sub/file", O_CREAT);
	if (fd >= 0) {
		const char *m2 = "deep file under /mnt/sub";
		write(fd, m2, slen(m2));
		close(fd);
		fd = open2("/mnt/sub/file", 0);
		n = read(fd, buf, sizeof (buf));
		if (n > 0) buf[n] = 0;
		puts_("    walked /mnt/sub/file + read: '");
		write(1, buf, (size_t)(n > 0 ? n : 0));
		puts_("'\n");
		close(fd);
		puts_((n > 0) ?
		    "    multi-level path walk across a mount: OK\n" :
		    "    BUG: multi-level walk read nothing\n");
	} else {
		puts_("    BUG: open(/mnt/sub/file) after mkdir FAILED\n");
	}
	/* rename the deep file, then confirm old name gone + new name reads. */
	if (rename_("/mnt/sub/file", "/mnt/sub/renamed") == 0) {
		fd = open2("/mnt/sub/file", 0);
		puts_((fd < 0) ?
		    "    rename: old name /mnt/sub/file is gone (OK)\n" :
		    "    BUG: old name still present after rename\n");
		if (fd >= 0) close(fd);
		fd = open2("/mnt/sub/renamed", 0);
		puts_((fd >= 0) ?
		    "    rename: new name /mnt/sub/renamed reads (OK)\n" :
		    "    BUG: new name not found after rename\n");
		if (fd >= 0) close(fd);
	}
	/* unlink the renamed file, then confirm it is gone. */
	if (unlink_("/mnt/sub/renamed") == 0) {
		fd = open2("/mnt/sub/renamed", 0);
		puts_((fd < 0) ?
		    "    unlink: /mnt/sub/renamed removed (OK)\n" :
		    "    BUG: file still present after unlink\n");
		if (fd >= 0) close(fd);
	}

	puts_("  [vfs] done\n");
	exit(0);
	return (0);
}
