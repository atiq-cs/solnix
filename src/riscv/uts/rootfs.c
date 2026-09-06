/*
 * rootfs.c — illumos riscv64 minimal root vfs + mount-root + single-user seam
 * (R-P6).
 *
 * The R-P6 milestone: mount a root filesystem and reach the single-user seam.
 * The simplest viable path is an in-memory root: a tiny vnode/vfs with a fixed
 * root directory holding the conventional illumos top-level stubs (/etc, /dev,
 * /sbin, /var, /tmp). This is the ramdisk/bootfs pattern — enough of a vfs to
 * say "root is mounted, / has N entries" and to hang a first user context off.
 *
 * This mirrors how uts/i86pc / the arm64-gate bring the root vfs online before
 * exec'ing init: rootvfs points at the mounted root, and the root vnode is the
 * lookup anchor. Here the vfs is deliberately read-only + in-memory; a
 * blk-backed / real-FS root (reading a UFS/ZFS image off vioblk) is R-P7.
 *
 * If virtio-blk attached (vioblk_present), we record the root device as the
 * block disk (root would come off it in R-P7); otherwise root is the ramdisk.
 * Either way the mounted vfs served to userland in R-P6 is the in-memory one.
 *
 * NOTE: in-memory read-only root, fixed directory, no write/create/unlink, no
 * real on-disk FS parse. It is the honest mount-root + single-user seam;
 * R-P7 grows a real VFS (lookup/read/write) + reads a root image off vioblk.
 */

#include "sbi.h"
#include "riscv_regs.h"
#include "user_elfs.h"

extern void kputdec(unsigned long v);
extern void kputhex(unsigned long v);

/* From vioblk.c: is a block device attached + readable? */
extern int vioblk_present(void);

/* From vioblk.c: the on-disk root FS disk (second virtio-blk) — R-P9 gate 4. */
extern int vioblk_fs_attach(void);
extern int vioblk_fs_present(void);
extern int vioblk_fs_read_sector(unsigned long sector, void *buf);

/* kmem.c: allocate the tar staging buffer. */
extern void *kmem_alloc(unsigned long size);

/* From proc.c: create + dispatch a kernel thread; yield. */
extern void *thread_create(void (*entry)(void *), void *arg);
extern void thread_yield(void);

/* From uproc.c: the R-P8 process model. */
extern int proc_first(const char *path, const void *img, unsigned long len);
extern int proc_waitpid(int pid, int *statusp);

/* Defined below: on-disk ustar root FS mount + query (R-P9 gate 4). */
int rootfs_mount_ondisk(void);
int rootfs_is_ondisk(void);
int vfs_lookup(const char *path, const void **datap, unsigned long *lenp);

/*
 * ---------------------------------------------------------------------------
 * Minimal vnode / vfs. A vnode has a type + name; a directory vnode points at
 * a fixed array of child vnodes. This is the seed of uts/common/fs/vnode.c +
 * the illumos vfs — pared to what mount-root + a directory listing need.
 * ---------------------------------------------------------------------------
 */
enum vtype { VNON = 0, VREG, VDIR, VCHR };

struct vnode {
	enum vtype	v_type;
	const char	*v_name;
	struct vnode	*v_children;	/* dir: first child */
	int		v_nchildren;
};

/* The root directory's fixed children (illumos-conventional top level). */
static struct vnode root_children[] = {
	{ VDIR, "etc",  0, 0 },
	{ VDIR, "dev",  0, 0 },
	{ VDIR, "sbin", 0, 0 },
	{ VDIR, "var",  0, 0 },
	{ VDIR, "tmp",  0, 0 },
};

/* The root vnode + the mounted root vfs. */
static struct vnode rootvnode = {
	VDIR, "/", root_children,
	(int)(sizeof (root_children) / sizeof (root_children[0]))
};

struct vfs {
	struct vnode	*vfs_root;	/* root vnode of this fs */
	const char	*vfs_type;	/* "ramdisk" / "vioblk" */
	const char	*vfs_dev;	/* backing device name */
	int		vfs_mounted;
};

static struct vfs rootvfs;

/* Exported for a would-be lookup path (R-P7). */
struct vnode *
rootdir(void)
{
	return (rootvfs.vfs_mounted ? rootvfs.vfs_root : 0);
}

/*
 * mountroot — bring the root vfs online. Choose the root device string based on
 * whether virtio-blk attached (the R-P7 real-root source) and mount the
 * in-memory root. PROVE: "root mounted (type=..., / has N entries)".
 */
int
mountroot(void)
{
	int i;

	sbi_console_puts("\n[rootfs] mounting root filesystem\n");

	rootvfs.vfs_root = &rootvnode;
	rootvfs.vfs_type = "ramdisk";		/* in-memory root vfs */
	if (vioblk_present())
		rootvfs.vfs_dev = "/dev/dsk/c0t0d0 (virtio-blk)";
	else
		rootvfs.vfs_dev = "ramdisk";
	rootvfs.vfs_mounted = 1;

	/*
	 * R-P9 gate 4: try to mount a REAL on-disk root FS (a ustar archive on a
	 * second virtio-blk). If present, /sbin/init + /bin/* are served off it
	 * (vfs_lookup consults the disk FS first); otherwise the embedded ELFs
	 * are used. This is the seed of a blk-backed rootvfs.
	 */
	if (rootfs_mount_ondisk()) {
		rootvfs.vfs_type = "ustar";
		rootvfs.vfs_dev = "/dev/dsk/c1t0d0 (virtio-blk, ustar)";
	}

	sbi_console_puts("[rootfs] rootvfs -> ");
	sbi_console_puts(rootvfs.vfs_dev);
	sbi_console_puts(", root vnode '/'\n");
	sbi_console_puts("[rootfs] / contents:");
	for (i = 0; i < rootvnode.v_nchildren; i++) {
		sbi_console_puts(" /");
		sbi_console_puts(rootvnode.v_children[i].v_name);
	}
	sbi_console_puts("\n");

	sbi_console_puts("root mounted (type=");
	sbi_console_puts(rootvfs.vfs_type);
	sbi_console_puts(", / has ");
	kputdec((unsigned long)rootvnode.v_nchildren);
	sbi_console_puts(" entries)\n");

	return (1);
}

/*
 * ---------------------------------------------------------------------------
 * single-user seam: the init-analog. After root is mounted we dispatch a first
 * "user" context — here a kernel thread that plays the role of init/sulogin,
 * printing the single-user prompt. Full userland + a real init exec is R-P7;
 * this proves the kernel mounts root and reaches the single-user milestone.
 * ---------------------------------------------------------------------------
 */
static volatile int single_user_reached;

static void
single_user_thread(void *arg)
{
	(void) arg;

	sbi_console_puts("\n[init] starting single-user context\n");
	sbi_console_puts("[init] root filesystem is mounted read-only; "
	    "entering single-user mode\n");
	sbi_console_puts("\nSINGLE USER MODE\n");

	/*
	 * R-P8: spawn the real /sbin/init as a U-mode process on its OWN kernel
	 * thread (proc_first), then wait for it (proc_waitpid). init runs the
	 * syscall-set + fork/exec/wait gates, then execs the interactive shell;
	 * it exits only when the shell exits. This kernel thread is the reaper:
	 * proc_waitpid yields cooperatively so init + its children get
	 * dispatched, then reaps init. This is the R-P8 milestone: userland is
	 * interactive + multi-process.
	 *
	 * NOTE (R-P9): if a ustar root FS is mounted off a second virtio-blk
	 * (rootfs_mount_ondisk), /sbin/init + /bin/* are read off the DISK; the
	 * embedded ELFs (user_elfs.h) are only the fallback when no disk FS is
	 * present. proc_waitpid now blocks on a real sleep queue, not a spin.
	 */
	single_user_reached = 1;

	{
		const void *img;
		unsigned long len;
		int pid;
		int st = 0, rpid;

		/*
		 * R-P9 gate 4: if a real on-disk (ustar) root FS is mounted,
		 * exec /sbin/init off the DISK (vfs_lookup serves it from the
		 * disk table); else fall back to the embedded ELF.
		 */
		if (rootfs_is_ondisk() &&
		    vfs_lookup("/sbin/init", &img, &len)) {
			sbi_console_puts("root: exec'd /sbin/init from vioblk "
			    "(FS type=ustar)\n");
			pid = proc_first("/sbin/init", img, len);
		} else {
			pid = proc_first("/sbin/init", init_elf, init_elf_len);
		}

		if (pid < 0) {
			sbi_console_puts("[init] proc_first(/sbin/init) "
			    "FAILED\n");
		} else {
			rpid = proc_waitpid(-1, &st);
			sbi_console_puts("\n[init] reaped /sbin/init pid ");
			kputdec((unsigned long)rpid);
			sbi_console_puts(" status ");
			kputdec((unsigned long)st);
			sbi_console_puts("\n");
		}
	}

	sbi_console_puts("\n[init] /sbin/init exited; single-user shell stub\n");
	sbi_console_puts("\n# ");	/* the single-user shell prompt */

	/* No further console loop wired in the kernel: yield forever. */
	thread_yield();
	for (;;)
		thread_yield();
}

/*
 * single_user — dispatch the single-user context and yield to it so it runs.
 * Called from startup after mountroot. Returns after the prompt has printed.
 */
int
single_user(const char *rootdev)
{
	void *t;

	t = thread_create(single_user_thread, 0);
	if (t == 0) {
		sbi_console_puts("[init] FAILED to create single-user thread\n");
		return (0);
	}

	/* Yield so the single-user thread runs and prints its prompt. */
	thread_yield();

	if (single_user_reached) {
		sbi_console_puts("\n[R-P6] root on ");
		sbi_console_puts(rootdev);
		sbi_console_puts(", single-user reached\n");
		return (1);
	}
	sbi_console_puts("[init] single-user thread did not report in\n");
	return (0);
}

/* The mounted root device string, for the milestone banner. */
const char *
rootdev_name(void)
{
	return (rootvfs.vfs_mounted ? rootvfs.vfs_dev : "(none)");
}

/*
 * ---------------------------------------------------------------------------
 * R-P8 file registry: a fixed table mapping a path to file bytes. It serves
 * two roles: (1) regular files userland can open()+read() (e.g. /etc/motd),
 * and (2) executable images exec() loads (the embedded userland ELFs). This is
 * the pared vfs "namei/lookup + read" the R-P8 syscalls need; a real on-disk FS
 * read off vioblk is the R-P9 upgrade.
 * ---------------------------------------------------------------------------
 */
static const char motd[] =
    "solnix riscv64 - the first illumos on RISC-V. R-P8: interactive, "
    "multi-process.\n";

struct vfile {
	const char	*f_path;
	const void	*f_data;
	unsigned long	f_len;
};

static const struct vfile vfiles[] = {
	{ "/etc/motd",  motd,      sizeof (motd) - 1 },
	{ "/sbin/init", init_elf,  0 },		/* f_len filled at init */
	{ "/bin/sh",    sh_elf,    0 },
	{ "/bin/hello", hello_elf, 0 },
	{ "/bin/echo",  echo_elf,  0 },
	{ "/bin/cat",   cat_elf,   0 },
	{ "/bin/fbtest", fbtest_elf, 0 },	/* R-P64 scanout-seam proof */
	{ "/bin/socktest", socktest_elf, 0 },	/* AF_UNIX + SCM_RIGHTS gate */
	{ "/bin/polltest", polltest_elf, 0 },	/* poll(2) + anon mmap gate */
	{ "/bin/fptest", fptest_elf, 0 },	/* hard-float context-switch gate */
};
#define NVFILES (int)(sizeof (vfiles) / sizeof (vfiles[0]))

/* The ELF lengths are sizeof() of generated arrays; fill a parallel table
 * (can't use sizeof in a static initializer of a const void*). */
static unsigned long vfile_len[NVFILES];
static int vfiles_ready;

static void
vfiles_init(void)
{
	if (vfiles_ready)
		return;
	vfile_len[0] = vfiles[0].f_len;		/* motd: real length above */
	vfile_len[1] = init_elf_len;
	vfile_len[2] = sh_elf_len;
	vfile_len[3] = hello_elf_len;
	vfile_len[4] = echo_elf_len;
	vfile_len[5] = cat_elf_len;
	vfile_len[6] = fbtest_elf_len;
	vfile_len[7] = socktest_elf_len;
	vfile_len[8] = polltest_elf_len;
	vfile_len[9] = fptest_elf_len;
	vfiles_ready = 1;
}

static int
str_eq(const char *a, const char *b)
{
	while (*a && *a == *b) { a++; b++; }
	return (*a == *b);
}

/*
 * ---------------------------------------------------------------------------
 * R-P9 gate 4: an on-disk root filesystem read off a second virtio-blk.
 *
 * The FS image is a POSIX ustar (tar) archive — the simplest real on-disk FS a
 * bootstrap needs: a sequence of 512-byte header+data blocks. We read the whole
 * archive off the disk into a kmem staging buffer at mount, parse the ustar
 * headers, and register each regular file's (name, data pointer, length) in an
 * on-disk file table. vfs_lookup then serves /sbin/init + /bin/* from THIS
 * table (falling back to the embedded ELFs only if the disk FS is absent), so
 * exec loads the userland off a real FS on vioblk, not from the kernel image.
 *
 * ustar header (512 bytes, the fields we use):
 *   [0]   name        (NUL-terminated, up to 100 bytes)
 *   [124] size        (11-octal digits + NUL/space)
 *   [156] typeflag    ('0' or '\0' = regular file)
 *   [257] magic       "ustar" (proves it is a ustar archive)
 * Data follows the header, padded up to the next 512-byte boundary. Two all-
 * zero blocks mark end of archive.
 * ---------------------------------------------------------------------------
 */
#define	TAR_BLOCK	512
#define	ROOTFS_MAX_BYTES (2UL * 1024 * 1024)	/* 2 MiB staging cap */
#define	NDISKFILE	16

struct diskfile {
	char		df_path[100];
	const unsigned char *df_data;
	unsigned long	df_len;
};
static struct diskfile diskfiles[NDISKFILE];
static int ndiskfile;
static int rootfs_ondisk;		/* 1 once the tar FS is mounted */
static unsigned char *rootfs_buf;	/* kmem staging of the whole archive */

/* Parse an octal ASCII field of `n` bytes into an unsigned long. */
static unsigned long
tar_octal(const unsigned char *p, int n)
{
	unsigned long v = 0;
	int i;
	for (i = 0; i < n; i++) {
		if (p[i] < '0' || p[i] > '7')
			break;
		v = (v << 3) | (unsigned long)(p[i] - '0');
	}
	return (v);
}

/*
 * rootfs_mount_ondisk — attach the second virtio-blk, read the ustar archive
 * off it into a kmem buffer, parse the headers, and populate the on-disk file
 * table. Returns 1 if a valid ustar root FS was mounted, 0 otherwise (no disk /
 * not a tar / read error — the kernel then serves the embedded ELFs). PROVE:
 * "root: exec'd /sbin/init from vioblk (FS type=ustar)".
 */
int
rootfs_mount_ondisk(void)
{
	unsigned long off = 0;
	unsigned long sector = 0;

	if (!vioblk_fs_attach())
		return (0);		/* no second disk */

	rootfs_buf = kmem_alloc(ROOTFS_MAX_BYTES);
	if (rootfs_buf == 0)
		return (0);

	/*
	 * Read the whole archive into rootfs_buf, sector by sector, until a read
	 * fails (past the end of the raw image) or the staging cap is reached.
	 * We deliberately do NOT stop on an all-zero block: an ELF payload can
	 * contain long runs of zero bytes, and a 2-zero-block heuristic would
	 * truncate the image mid-file. Reading to end-of-disk is correct and the
	 * images are small (bounded by ROOTFS_MAX_BYTES).
	 */
	while (off + TAR_BLOCK <= ROOTFS_MAX_BYTES) {
		if (!vioblk_fs_read_sector(sector, rootfs_buf + off))
			break;		/* end of disk / read error */
		off += TAR_BLOCK;
		sector++;
	}

	/* Parse ustar headers. */
	ndiskfile = 0;
	off = 0;
	while (off + TAR_BLOCK <= ROOTFS_MAX_BYTES && ndiskfile < NDISKFILE) {
		const unsigned char *h = rootfs_buf + off;
		unsigned long size, datablocks;
		int j;

		/* End of archive: empty name. */
		if (h[0] == 0)
			break;
		/* Validate ustar magic at offset 257. */
		if (!(h[257] == 'u' && h[258] == 's' && h[259] == 't' &&
		    h[260] == 'a' && h[261] == 'r'))
			break;		/* not ustar */

		size = tar_octal(h + 124, 11);

		/* Regular file (typeflag '0' or NUL). Register it with a leading
		 * '/' so lookup paths like "/sbin/init" match tar names like
		 * "sbin/init" or "./sbin/init". */
		if (h[156] == '0' || h[156] == 0) {
			struct diskfile *df = &diskfiles[ndiskfile];
			const char *name = (const char *)h;
			int pi = 0;

			if (name[0] == '.' && name[1] == '/')
				name += 2;
			df->df_path[pi++] = '/';
			for (j = 0; name[j] != 0 && j < 98; j++)
				df->df_path[pi++] = name[j];
			df->df_path[pi] = 0;
			df->df_data = h + TAR_BLOCK;
			df->df_len = size;
			ndiskfile++;
		}

		datablocks = (size + TAR_BLOCK - 1) / TAR_BLOCK;
		off += TAR_BLOCK + datablocks * TAR_BLOCK;
	}

	if (ndiskfile == 0)
		return (0);		/* no files parsed: not a usable FS */

	rootfs_ondisk = 1;
	sbi_console_puts("[rootfs] on-disk ustar root FS: ");
	kputdec((unsigned long)ndiskfile);
	sbi_console_puts(" files off vioblk:");
	{
		int i;
		for (i = 0; i < ndiskfile; i++) {
			sbi_console_puts(" ");
			sbi_console_puts(diskfiles[i].df_path);
		}
	}
	sbi_console_puts("\n");
	return (1);
}

/* Is the root served off a real on-disk FS? (used by single_user banner.) */
int
rootfs_is_ondisk(void)
{
	return (rootfs_ondisk);
}

/* Look up a path in the on-disk file table (R-P9). Returns 1 on hit. */
static int
diskfs_lookup(const char *path, const void **datap, unsigned long *lenp)
{
	int i;
	if (!rootfs_ondisk)
		return (0);
	for (i = 0; i < ndiskfile; i++) {
		if (str_eq(path, diskfiles[i].df_path)) {
			*datap = diskfiles[i].df_data;
			*lenp = diskfiles[i].df_len;
			return (1);
		}
	}
	return (0);
}

/*
 * vfs_lookup — resolve `path` to its bytes. Consults the on-disk ustar root FS
 * FIRST (R-P9 gate 4), falling back to the embedded ELFs / motd if the disk FS
 * is absent or lacks the file. Returns 1 and fills datap/lenp on a hit, 0 on
 * miss. Used by the open/read syscall path and the exec syscall path.
 */
int
vfs_lookup(const char *path, const void **datap, unsigned long *lenp)
{
	int i;

	if (diskfs_lookup(path, datap, lenp))
		return (1);		/* served off the on-disk FS */

	vfiles_init();
	for (i = 0; i < NVFILES; i++) {
		if (str_eq(path, vfiles[i].f_path)) {
			*datap = vfiles[i].f_data;
			*lenp = vfile_len[i];
			return (1);
		}
	}
	return (0);
}
