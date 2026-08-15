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

enum vtype { VT_RAMFS = 0, VT_TMPFS = 1, VT_DIR = 2 };

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
/* R-P33.2: the tmpfs name storage, shared by vfs_lookup (create a file) and
   vfs_mkdir (create a dir); one 64-byte name per slot. */
static char tmpfs_names[NTMPFILE][64];
char *
tmpfs_name_slot(int slot)
{
	return (tmpfs_names[slot]);
}

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

/* ---- tmpfs directories: VOP_READDIR over the flat name table --------- */
/*
 * A directory is a tmpfs_tab entry with v_type == VT_DIR whose v_name is the
 * dir path (e.g. "/tmp/d").  readdir enumerates every tmpfs entry (file OR dir)
 * whose name lies DIRECTLY under the dir path -- i.e. name == dir "/" basename
 * with no further "/".  vop_read/write on a dir are errors; vop_getattr reports
 * the entry count.  This is the illumos tmpfs tmp_readdir walking the tdirent
 * list, reduced to a prefix scan of the flat name table.
 */
static long dir_vop_read(vnode_t *vp, char *ubuf, unsigned long off,
    unsigned long n)
{ (void) vp; (void) ubuf; (void) off; (void) n; return (VERR_ENOENT); }
static long dir_vop_write(vnode_t *vp, const char *ubuf, unsigned long off,
    unsigned long n)
{ (void) vp; (void) ubuf; (void) off; (void) n; return (VERR_EROFS); }
static long
dir_vop_getattr(vnode_t *vp, unsigned long *size)
{
	if (size != 0)
		*size = vp->v_len;	/* the entry count (set by lookup) */
	return (0);
}
static const vnodeops_t dir_vnodeops = {
	dir_vop_read, dir_vop_write, dir_vop_getattr
};

/* is `name` DIRECTLY under `dir` (dir + "/" + basename, no further "/")? */
static int
is_direct_child(const char *dir, const char *name)
{
	unsigned int i = 0;
	/* dir must be a proper prefix of name. */
	while (dir[i] != 0) {
		if (name[i] != dir[i])
			return (0);
		i++;
	}
	if (name[i] != '/')
		return (0);		/* not "dir/..." */
	i++;
	if (name[i] == 0)
		return (0);		/* nothing after the slash */
	/* the remainder must have no further '/'. */
	for (; name[i] != 0; i++)
		if (name[i] == '/')
			return (0);
	return (1);
}

/*
 * vfs_mkdir -- create a tmpfs directory named `path` (must be a /tmp/* path,
 * not already present).  Returns 0 or a negative errno.
 */
int
vfs_mkdir(const char *path)
{
	int i, free_slot = -1;
	extern int is_tmp_path_pub(const char *p);

	if (!is_tmp_path_pub(path))
		return (VERR_EROFS);	/* only tmpfs is writable */
	for (i = 0; i < NTMPFILE; i++) {
		if (tmpfs_tab[i].v_used && name_eq(tmpfs_tab[i].v_name, path))
			return (VERR_ENOENT);	/* already exists */
		if (!tmpfs_tab[i].v_used && free_slot < 0)
			free_slot = i;
	}
	if (free_slot < 0)
		return (VERR_ENOSPC);
	{
		vnode_t *vp = &tmpfs_tab[free_slot];
		extern char *tmpfs_name_slot(int slot);
		char *nm = tmpfs_name_slot(free_slot);
		int k;
		for (k = 0; k < 63 && path[k]; k++)
			nm[k] = path[k];
		nm[k] = 0;
		vp->v_op = &dir_vnodeops;
		vp->v_type = VT_DIR;
		vp->v_rw_data = 0;
		vp->v_len = 0;
		vp->v_cap = 0;
		vp->v_name = nm;
		vp->v_used = 1;
	}
	return (0);
}

/*
 * vfs_readdir -- return the basename of the `index`th entry directly under the
 * directory vnode `dvp` into `name` (up to `nsz` bytes).  Returns 1 if an entry
 * was written, 0 at end-of-directory.
 */
int
vfs_readdir(vnode_t *dvp, unsigned long index, char *name, unsigned long nsz)
{
	int i;
	unsigned long seen = 0;

	if (dvp->v_type != VT_DIR)
		return (0);
	for (i = 0; i < NTMPFILE; i++) {
		if (!tmpfs_tab[i].v_used || &tmpfs_tab[i] == dvp)
			continue;
		if (!is_direct_child(dvp->v_name, tmpfs_tab[i].v_name))
			continue;
		if (seen == index) {
			/* copy the basename (past the dir prefix + '/'). */
			const char *full = tmpfs_tab[i].v_name;
			unsigned int p = 0, k = 0;
			while (dvp->v_name[p] != 0) p++;
			p++;			/* skip the '/' */
			while (full[p] != 0 && k + 1 < nsz)
				name[k++] = full[p++];
			name[k] = 0;
			return (1);
		}
		seen++;
	}
	return (0);
}

/* is_tmp_path exposed to vfs_mkdir + a name-slot allocator shared with lookup. */
int
is_tmp_path_pub(const char *p)
{
	return (p[0] == '/' && p[1] == 't' && p[2] == 'm' && p[3] == 'p' &&
	    p[4] == '/');
}

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
			int k;
			for (k = 0; k < 63 && path[k]; k++)
				tmpfs_names[free_slot][k] = path[k];
			tmpfs_names[free_slot][k] = 0;
			vp->v_op = &tmpfs_vnodeops;
			vp->v_type = VT_TMPFS;
			vp->v_rw_data = 0;
			vp->v_len = 0;
			vp->v_cap = 0;
			vp->v_name = tmpfs_names[free_slot];
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

/* R-P33.2: is this vnode a directory? (proc.c tags the fd for getdents) */
int
vfs_isdir(vnode_t *vp)
{
	return (vp != 0 && vp->v_type == VT_DIR);
}
