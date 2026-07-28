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
#include "init_elf.h"

extern void kputdec(unsigned long v);
extern void kputhex(unsigned long v);

/* From vioblk.c: is a block device attached + readable? */
extern int vioblk_present(void);

/* From proc.c: create + dispatch a kernel thread; yield. */
extern void *thread_create(void (*entry)(void *), void *arg);
extern void thread_yield(void);

/* From uproc.c: exec a static ELF image as the first userland process. */
extern int proc_exec_user(const char *path, const void *img, unsigned long len);

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
	 * R-P7: exec the real /sbin/init as a U-mode process. rootfs serves the
	 * embedded static riscv64 ELF (init_elf[]); proc_exec_user builds a
	 * fresh address space, loads the ELF, and drops to U-mode. It returns
	 * when init exits (the interactive loop exits on 'q'). This is the
	 * milestone: userland runs.
	 *
	 * NOTE: init_elf[] is embedded in the kernel image (built by
	 * user/build-init.sh). The disk is attached + proven readable (R-P6),
	 * but the ramdisk root serves no file bytes yet, so R-P7 embeds init;
	 * reading /sbin/init off vioblk into this buffer is the R-P8 upgrade.
	 */
	single_user_reached = 1;

	(void) proc_exec_user("/sbin/init", init_elf, init_elf_len);

	sbi_console_puts("\n[init] /sbin/init returned to kernel; dropping to "
	    "single-user shell stub\n");
	sbi_console_puts("\n# ");	/* the single-user shell prompt */

	/* No further console loop wired in the kernel (R-P8): yield forever. */
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
