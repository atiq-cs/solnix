/*
 * vfs.c -- R-P32.3: a real-ish vnode layer (VOP_READ/WRITE/LOOKUP/GETATTR) over
 * two filesystems: the existing read-only ramfs (initramfs blob) and a small
 * WRITABLE tmpfs so a process can write(2) a file + read it back.
 *
 * The R-P31 read(2) path stored the ramfs byte range directly in the fd (no
 * vnode indirection, no write path).  R-P32 introduces the vnode abstraction:
 * struct vnode dispatched through an op vector; fop_read/fop_write/fop_getattr
 * call v_op->vop_*, and vfs_lookup is the reduced fop_lookup that resolves a
 * path to a file vnode (a ramfs file or a tmpfs file).  This is illumos
 * fs/vnode.c fop_read/fop_write/fop_lookup/fop_getattr + the vnodeops vector,
 * reduced to two fs types and no mounts/directories beyond an exact-name lookup.
 *
 *   ramfs vnode  -- read-only, backed by the initramfs bytes (VOP_WRITE -> EROFS).
 *   tmpfs vnode  -- writable, backed by a kmem buffer that grows on write; the
 *                   tmpfs directory is a fixed table of named files created on
 *                   first open-for-write of a /tmp/ path.
 *
 * CRIB PROVENANCE: the vnode + vnodeops (vop_read/vop_write/vop_lookup/
 * vop_getattr) dispatch is illumos uts/common/sys/vnode.h + fs/vnode.c fop_*();
 * the ramfs-over-a-boot-archive read is illumos boot_archive; the tmpfs (a
 * writable in-RAM file whose bytes ARE the file, grown on write) is illumos
 * uts/common/fs/tmpfs/tmp_vnops.c (tmp_write/tmp_read/tmpnode) reduced to a flat
 * kmem-backed buffer per file; the BSD analogue is tmpfs + uiomove.
 */

#include "sbi.h"
#include "mmu_riscv.h"

extern int ramfs_lookup(const char *path, const unsigned char **out,
    unsigned long *outlen);
extern void *kmem_alloc(unsigned long);
extern void kmem_free(void *, unsigned long);

#define	VERR_ENOENT	(-2)
#define	VERR_EROFS	(-30)
#define	VERR_ENOSPC	(-28)

enum vtype { VT_RAMFS = 0, VT_TMPFS = 1 };

struct vnode;
typedef struct vnodeops {
	long (*vop_read)(struct vnode *, char *ubuf, unsigned long off,
	    unsigned long n);
	long (*vop_write)(struct vnode *, const char *ubuf, unsigned long off,
	    unsigned long n);
	long (*vop_getattr)(struct vnode *, unsigned long *size);
} vnodeops_t;

typedef struct vnode {
	const vnodeops_t *v_op;		/* the op vector */
	enum vtype	v_type;
	const unsigned char *v_ro_data;	/* ramfs: the backing bytes */
	unsigned char	*v_rw_data;	/* tmpfs: the growable kmem buffer */
	unsigned long	v_len;		/* current file length */
	unsigned long	v_cap;		/* tmpfs: allocated capacity */
	const char	*v_name;	/* tmpfs: file name (for lookup) */
	int		v_used;		/* tmpfs slot in use */
} vnode_t;

/* ---- ramfs vnode ops (read-only) ------------------------------------- */

static long
ramfs_vop_read(vnode_t *vp, char *ubuf, unsigned long off, unsigned long n)
{
	unsigned long i, avail;
	if (off >= vp->v_len)
		return (0);			/* EOF */
	avail = vp->v_len - off;
	if (n > avail)
		n = avail;
	for (i = 0; i < n; i++)
		ubuf[i] = (char)vp->v_ro_data[off + i];
	return ((long)n);
}
static long
ramfs_vop_write(vnode_t *vp, const char *ubuf, unsigned long off,
    unsigned long n)
{
	(void) vp; (void) ubuf; (void) off; (void) n;
	return (VERR_EROFS);			/* ramfs is read-only */
}
static long
ramfs_vop_getattr(vnode_t *vp, unsigned long *size)
{
	if (size != 0)
		*size = vp->v_len;
	return (0);
}
static const vnodeops_t ramfs_vnodeops = {
	ramfs_vop_read, ramfs_vop_write, ramfs_vop_getattr
};

/* ---- tmpfs: a small table of writable in-RAM files ------------------- */

#define	NTMPFILE	8
#define	TMPFS_CHUNK	4096UL
static vnode_t tmpfs_tab[NTMPFILE];

static int
name_eq(const char *a, const char *b)
{
	unsigned int i;
	for (i = 0; a[i] != 0 || b[i] != 0; i++)
		if (a[i] != b[i])
			return (0);
	return (1);
}

static long
tmpfs_vop_read(vnode_t *vp, char *ubuf, unsigned long off, unsigned long n)
{
	unsigned long i, avail;
	if (off >= vp->v_len)
		return (0);
	avail = vp->v_len - off;
	if (n > avail)
		n = avail;
	for (i = 0; i < n; i++)
		ubuf[i] = (char)vp->v_rw_data[off + i];
	return ((long)n);
}
static long
tmpfs_vop_write(vnode_t *vp, const char *ubuf, unsigned long off,
    unsigned long n)
{
	unsigned long end = off + n, i;

	/* grow the backing buffer if the write runs past the capacity. */
	if (end > vp->v_cap) {
		unsigned long newcap = (end + TMPFS_CHUNK - 1) &
		    ~(TMPFS_CHUNK - 1);
		unsigned char *nb = kmem_alloc(newcap);
		if (nb == 0)
			return (VERR_ENOSPC);
		for (i = 0; i < vp->v_len; i++)
			nb[i] = vp->v_rw_data ? vp->v_rw_data[i] : 0;
		if (vp->v_rw_data != 0)
			kmem_free(vp->v_rw_data, vp->v_cap);
		vp->v_rw_data = nb;
		vp->v_cap = newcap;
	}
	/* zero-fill any gap between the old end and the write offset. */
	for (i = vp->v_len; i < off; i++)
		vp->v_rw_data[i] = 0;
	for (i = 0; i < n; i++)
		vp->v_rw_data[off + i] = (unsigned char)ubuf[i];
	if (end > vp->v_len)
		vp->v_len = end;
	return ((long)n);
}
static long
tmpfs_vop_getattr(vnode_t *vp, unsigned long *size)
{
	if (size != 0)
		*size = vp->v_len;
	return (0);
}
static const vnodeops_t tmpfs_vnodeops = {
	tmpfs_vop_read, tmpfs_vop_write, tmpfs_vop_getattr
};

/* ---- the root VOP_LOOKUP: resolve a path to a vnode ------------------ */
/*
 * vfs_lookup -- the reduced fop_lookup: resolve `path` to a vnode.  A /tmp/*
 * path resolves to (or, with create=1, creates) a tmpfs file; any other path is
 * looked up in the read-only ramfs.  Fills *out with a POINTER to a vnode
 * (a ramfs vnode is built on the fly into a scratch node; a tmpfs vnode lives in
 * tmpfs_tab).  Returns 0 or a negative errno.
 *
 * CRIB PROVENANCE: fop_lookup dispatching by path prefix to the right fs +
 * VOP_CREATE for a new tmpfs file is illumos lookuppn / vn_openat + tmp_lookup /
 * tmp_create, reduced to a prefix test + a flat name table.
 */
static int
is_tmp_path(const char *p)
{
	return (p[0] == '/' && p[1] == 't' && p[2] == 'm' && p[3] == 'p' &&
	    p[4] == '/');
}

int
vfs_lookup(const char *path, vnode_t **out, int create)
{
	int i, free_slot = -1;

	if (is_tmp_path(path)) {
		/* tmpfs: find an existing file by name, or create one. */
		for (i = 0; i < NTMPFILE; i++) {
			if (tmpfs_tab[i].v_used &&
			    name_eq(tmpfs_tab[i].v_name, path)) {
				*out = &tmpfs_tab[i];
				return (0);
			}
			if (!tmpfs_tab[i].v_used && free_slot < 0)
				free_slot = i;
		}
		if (!create || free_slot < 0)
			return (VERR_ENOENT);
		{
			vnode_t *vp = &tmpfs_tab[free_slot];
			static char names[NTMPFILE][64];
			int k;
			for (k = 0; k < 63 && path[k]; k++)
				names[free_slot][k] = path[k];
			names[free_slot][k] = 0;
			vp->v_op = &tmpfs_vnodeops;
			vp->v_type = VT_TMPFS;
			vp->v_rw_data = 0;
			vp->v_len = 0;
			vp->v_cap = 0;
			vp->v_name = names[free_slot];
			vp->v_used = 1;
			*out = vp;
			return (0);
		}
	}

	/* ramfs (read-only): build a transient vnode over the archive bytes. */
	{
		static vnode_t scratch;	/* one outstanding ramfs open at a time */
		const unsigned char *data;
		unsigned long len;
		if (ramfs_lookup(path, &data, &len) != 0)
			return (VERR_ENOENT);
		scratch.v_op = &ramfs_vnodeops;
		scratch.v_type = VT_RAMFS;
		scratch.v_ro_data = data;
		scratch.v_len = len;
		scratch.v_used = 1;
		*out = &scratch;
		return (0);
	}
}

/* ---- the fop_* dispatch (what proc.c calls) -------------------------- */
long
fop_read(vnode_t *vp, char *ubuf, unsigned long off, unsigned long n)
{
	return (vp->v_op->vop_read(vp, ubuf, off, n));
}
long
fop_write(vnode_t *vp, const char *ubuf, unsigned long off, unsigned long n)
{
	return (vp->v_op->vop_write(vp, ubuf, off, n));
}
long
fop_getattr(vnode_t *vp, unsigned long *size)
{
	return (vp->v_op->vop_getattr(vp, size));
}
