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
#define	VERR_ENOMEM	(-12)
#define	VERR_EROFS	(-30)
#define	VERR_ENOSPC	(-28)

enum vtype { VT_RAMFS = 0, VT_TMPFS = 1, VT_DIR = 2 };

/* R-P34.3: forward decl -- which fs (by mount table) backs a path. */
static enum vtype mount_fstype(const char *path);

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

#define	NTMPFILE	24
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
	return (mount_fstype(p) == VT_TMPFS);	/* R-P34.3: by mount table */
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
	return (mount_fstype(p) == VT_TMPFS);	/* R-P34.3: by mount table */
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

/* ---- R-P34.3: a mount table + a multi-level path walk (lookuppn) ------ */
/*
 * A mount table maps a mount-point path prefix to a filesystem type.  "/" is
 * ramfs (the root), and mount("tmpfs", "/mnt") makes any path under /mnt a
 * tmpfs path.  vfs_walk (the reduced lookuppn) walks a path component-by-
 * component from the root: it validates that each intermediate prefix names an
 * existing directory (created by mkdir), rejecting a walk through a missing
 * directory, then resolves the leaf against the fs the leaf's mount covers.
 * A '/tmp' mount is pre-installed so the R-P32/33 tmpfs paths keep working.
 *
 * CRIB PROVENANCE: a vfs list keyed by mount-point vnode that fop_lookup /
 * lookuppn crosses when a path descends into a mounted fs is illumos
 * uts/common/fs/lookup.c lookuppnvp() + vfs_t/vfssw (the vfsp->vfs_vnodecovered
 * mount linkage); reduced here to a prefix table + a component walk that checks
 * each intermediate directory exists.
 */
#define	NMOUNT		8
typedef struct mount {
	char		m_path[64];	/* mount-point path (e.g. "/mnt") */
	enum vtype	m_fstype;	/* VT_RAMFS or VT_TMPFS backs this subtree */
	int		m_used;
} mount_t;
static mount_t mount_tab[NMOUNT];

static int
str_prefix(const char *pre, const char *s)
{
	unsigned int i;
	for (i = 0; pre[i] != 0; i++)
		if (pre[i] != s[i])
			return (0);
	/* prefix must end at a '/' boundary or the end of s ("/mnt" vs "/mnt/x"). */
	return (s[i] == 0 || s[i] == '/');
}

/*
 * vfs_mount -- add a mount-table entry: `fstype` ("tmpfs"/"ramfs") backs the
 * subtree at `path`.  Returns 0 or a negative errno.
 */
int
vfs_mount(const char *fstype, const char *path)
{
	int i, free_slot = -1;
	enum vtype vt;

	if (fstype == 0 || path == 0 || path[0] != '/')
		return (VERR_ENOENT);
	if (fstype[0] == 't')		/* "tmpfs" */
		vt = VT_TMPFS;
	else
		vt = VT_RAMFS;
	for (i = 0; i < NMOUNT; i++) {
		if (mount_tab[i].m_used && name_eq(mount_tab[i].m_path, path))
			return (VERR_ENOENT);	/* already mounted */
		if (!mount_tab[i].m_used && free_slot < 0)
			free_slot = i;
	}
	if (free_slot < 0)
		return (VERR_ENOSPC);
	{
		int k;
		for (k = 0; k < 63 && path[k]; k++)
			mount_tab[free_slot].m_path[k] = path[k];
		mount_tab[free_slot].m_path[k] = 0;
		mount_tab[free_slot].m_fstype = vt;
		mount_tab[free_slot].m_used = 1;
	}
	return (0);
}

/*
 * vfs_mount_init -- seed the mount table: "/" is ramfs (root), "/tmp" is tmpfs
 * (so the R-P32/33 tmpfs paths resolve).  Called once at boot.
 */
void
vfs_mount_init(void)
{
	(void) vfs_mount("ramfs", "/");
	(void) vfs_mount("tmpfs", "/tmp");
}

/* which fs backs `path`? -> the LONGEST matching mount prefix's fstype. */
static enum vtype
mount_fstype(const char *path)
{
	int i, best = -1;
	unsigned int bestlen = 0;
	for (i = 0; i < NMOUNT; i++) {
		unsigned int l = 0;
		if (!mount_tab[i].m_used || !str_prefix(mount_tab[i].m_path, path))
			continue;
		while (mount_tab[i].m_path[l] != 0)
			l++;
		if (best < 0 || l > bestlen) {
			best = i;
			bestlen = l;
		}
	}
	return (best < 0 ? VT_RAMFS : mount_tab[best].m_fstype);
}

/* is there a tmpfs directory vnode named exactly `path`? */
static int
tmpfs_dir_exists(const char *path)
{
	int i;
	for (i = 0; i < NMOUNT; i++)
		if (mount_tab[i].m_used && name_eq(mount_tab[i].m_path, path))
			return (1);	/* a mount point is a directory */
	for (i = 0; i < NTMPFILE; i++)
		if (tmpfs_tab[i].v_used && tmpfs_tab[i].v_type == VT_DIR &&
		    name_eq(tmpfs_tab[i].v_name, path))
			return (1);
	return (0);
}

/*
 * R-P36: vfs_path_isdir -- is the absolute path `path` an existing directory?
 * "/" and any mount point are directories; a tmpfs mkdir'd dir is a directory.
 * Used by chdir(2) to validate a cd target.  Exported (chdir lives in proc.c).
 */
int
vfs_path_isdir(const char *path)
{
	if (path != 0 && path[0] == '/' && path[1] == 0)
		return (1);			/* the root */
	return (tmpfs_dir_exists(path));
}

/*
 * vfs_walk -- the reduced lookuppn.  Walk `path` component-by-component from
 * the root, validating that every INTERMEDIATE prefix ("/mnt", "/mnt/sub", ...)
 * names an existing directory (a mount point or a mkdir'd tmpfs dir), then
 * resolve the LEAF against the fs the leaf's longest mount prefix covers.
 * `create` creates the leaf (tmpfs only).  Rejects a walk through a missing
 * intermediate directory with ENOENT.  Returns 0 or a negative errno.
 */
int
vfs_walk(const char *path, vnode_t **out, int create)
{
	char prefix[64];
	unsigned int i, plen;

	if (path == 0 || path[0] != '/')
		return (VERR_ENOENT);

	/* validate each intermediate directory component of a tmpfs path. */
	if (mount_fstype(path) == VT_TMPFS) {
		plen = 0;
		for (i = 1; path[i] != 0; i++) {
			if (path[i] != '/')
				continue;
			/* prefix = path[0..i) is an intermediate dir; must exist. */
			for (plen = 0; plen < i && plen < 63; plen++)
				prefix[plen] = path[plen];
			prefix[plen] = 0;
			if (!tmpfs_dir_exists(prefix))
				return (VERR_ENOENT);	/* missing dir in the walk */
		}
	}
	/* leaf resolution reuses the flat-name vfs_lookup over the leaf fs. */
	return (vfs_lookup(path, out, create));
}

/*
 * vfs_unlink -- remove a tmpfs file named `path` (frees its buffer, frees the
 * slot).  Returns 0 or a negative errno (ENOENT if absent, EROFS if not tmpfs).
 */
int
vfs_unlink(const char *path)
{
	int i;
	if (mount_fstype(path) != VT_TMPFS)
		return (VERR_EROFS);
	for (i = 0; i < NTMPFILE; i++) {
		if (tmpfs_tab[i].v_used && tmpfs_tab[i].v_type == VT_TMPFS &&
		    name_eq(tmpfs_tab[i].v_name, path)) {
			if (tmpfs_tab[i].v_rw_data != 0)
				kmem_free(tmpfs_tab[i].v_rw_data,
				    tmpfs_tab[i].v_cap);
			tmpfs_tab[i].v_used = 0;
			tmpfs_tab[i].v_rw_data = 0;
			tmpfs_tab[i].v_len = 0;
			tmpfs_tab[i].v_cap = 0;
			return (0);
		}
	}
	return (VERR_ENOENT);
}

/*
 * vfs_rename -- rename a tmpfs file `from` -> `to` (both must be tmpfs paths).
 * If `to` already exists it is replaced.  Reduced: just rewrites the slot's
 * name (same backing buffer).  Returns 0 or a negative errno.
 */
int
vfs_rename(const char *from, const char *to)
{
	int i, slot = -1, k;
	if (mount_fstype(from) != VT_TMPFS || mount_fstype(to) != VT_TMPFS)
		return (VERR_EROFS);
	for (i = 0; i < NTMPFILE; i++)
		if (tmpfs_tab[i].v_used && name_eq(tmpfs_tab[i].v_name, from)) {
			slot = i;
			break;
		}
	if (slot < 0)
		return (VERR_ENOENT);
	(void) vfs_unlink(to);		/* replace an existing target */
	for (k = 0; k < 63 && to[k]; k++)
		tmpfs_names[slot][k] = to[k];
	tmpfs_names[slot][k] = 0;
	tmpfs_tab[slot].v_name = tmpfs_names[slot];
	return (0);
}

/*
 * vfs_truncate -- R-P37.3: O_TRUNC support.  Reset a tmpfs file to length 0
 * (its backing buffer is kept but the file is now empty).  A ramfs vnode is
 * read-only (EROFS).  Returns 0 or a negative errno.
 */
int
vfs_truncate(vnode_t *vp)
{
	if (vp == 0)
		return (VERR_ENOENT);
	if (vp->v_type != VT_TMPFS)
		return (VERR_EROFS);
	vp->v_len = 0;
	return (0);
}

/*
 * vfs_rmdir -- R-P37.3: remove an EMPTY tmpfs directory named `path`.  Fails
 * with ENOTEMPTY (reported as ENOENT here) if any entry lives directly under
 * it, EROFS if not tmpfs, ENOENT if absent.  Returns 0 or a negative errno.
 */
int
vfs_rmdir(const char *path)
{
	int i, slot = -1;
	if (mount_fstype(path) != VT_TMPFS)
		return (VERR_EROFS);
	for (i = 0; i < NTMPFILE; i++)
		if (tmpfs_tab[i].v_used && tmpfs_tab[i].v_type == VT_DIR &&
		    name_eq(tmpfs_tab[i].v_name, path)) {
			slot = i;
			break;
		}
	if (slot < 0)
		return (VERR_ENOENT);
	/* refuse a non-empty directory: any entry directly under it. */
	for (i = 0; i < NTMPFILE; i++)
		if (tmpfs_tab[i].v_used && &tmpfs_tab[i] != &tmpfs_tab[slot] &&
		    is_direct_child(tmpfs_tab[slot].v_name, tmpfs_tab[i].v_name))
			return (VERR_ENOENT);	/* not empty */
	tmpfs_tab[slot].v_used = 0;
	return (0);
}

/* ==== R-P38.3: a block-device vnode + a minimal on-disk blockfs =========
 *
 * A simple RAM-backed BLOCK DEVICE (bdev0) with the classic Unix block
 * strategy routine bdev_strategy(blkno, buf, rw) -- read or write one 512-byte
 * block.  On top of it, a trivial on-disk filesystem (blockfs): block 0 is a
 * superblock, block 1 is an inode table, and blocks 2+ hold file data.  A
 * blockfs vnode's vop_read pulls the file's data BLOCKS through bdev_strategy,
 * so a read(2) of a blockfs file crosses the block-device layer -- proving the
 * vfs is NOT ramfs-only: a second, block-backed filesystem is mounted and read
 * through a block vnode (the specfs/bdev + ufs-lite model), not the in-memory
 * ramfs/tmpfs.
 *
 * CRIB PROVENANCE: the strategy(9E)/buf-based block I/O entry point is the
 * illumos bdev_strategy / specfs spec_read -> VOP_STRATEGY (usr/src/uts/common/
 * io + fs/specfs); the superblock + inode + data-block on-disk layout read via
 * a block-read primitive is xv6 fs.c (readsb/ilock/readi + bread) and a ufs-
 * lite fs_clean/inode layout; the mount-then-read-back-then-unmount lifecycle
 * is the standard vfs_mount/VFS_ROOT/VFS_UNMOUNT sequence.
 */
#define	BDEV_BSIZE	512UL
#define	BDEV_NBLK	64		/* 32 KiB RAM disk */
#define	BLOCKFS_MAGIC	0x53464e42UL	/* "BNFS" -- solniX blockfs */
#define	BLOCKFS_NINODE	8
#define	BLOCKFS_SB_BLK	0
#define	BLOCKFS_INO_BLK	1
#define	BLOCKFS_DATA_BLK 2		/* first data block */

/* the RAM-backed block device: NBLK fixed-size blocks. */
static unsigned char bdev0[BDEV_NBLK][BDEV_BSIZE];

/*
 * bdev_strategy -- the block-device strategy routine.  Transfer ONE block
 * between the device and `buf`: rw==0 reads block `blkno` into buf, rw==1
 * writes buf to block `blkno`.  Returns 0, or -1 on a bad block number.  (A
 * real driver queues a buf(9S) + interrupts on completion; the RAM disk copies
 * synchronously, but every blockfs read/write goes THROUGH here, exercising the
 * block vnode/strategy layer.)
 */
static int
bdev_strategy(unsigned long blkno, unsigned char *buf, int rw)
{
	unsigned long i;
	if (blkno >= BDEV_NBLK)
		return (-1);
	if (rw == 0)
		for (i = 0; i < BDEV_BSIZE; i++)
			buf[i] = bdev0[blkno][i];
	else
		for (i = 0; i < BDEV_BSIZE; i++)
			bdev0[blkno][i] = buf[i];
	return (0);
}

/* on-disk inode (packed into the inode-table block). */
struct blockfs_inode {
	unsigned long	i_magic;	/* BLOCKFS_MAGIC if in use, else 0 */
	unsigned long	i_size;		/* file size in bytes */
	unsigned long	i_dblk;		/* first data block number */
	char		i_name[40];	/* leaf name (no dirs: flat) */
};

/* superblock (block 0). */
struct blockfs_sb {
	unsigned long	s_magic;
	unsigned long	s_ninode;
	unsigned long	s_inoblk;	/* block holding the inode table */
};

/*
 * blockfs_mkfs -- lay a fresh blockfs onto bdev0: write the superblock, zero
 * the inode table, then create one file "hello" whose data lives in a data
 * block.  All writes go through bdev_strategy (the block layer).  Returns 0.
 */
static int
blockfs_mkfs(void)
{
	unsigned char blk[BDEV_BSIZE];
	struct blockfs_sb *sb = (struct blockfs_sb *)blk;
	struct blockfs_inode *itab;
	unsigned long i;
	static const char fname[] = "hello";
	static const char fdata[] =
	    "solnix riscv64 blockfs (R-P38): read via a block vnode + "
	    "bdev_strategy, not ramfs.\n";

	/* superblock. */
	for (i = 0; i < BDEV_BSIZE; i++) blk[i] = 0;
	sb->s_magic = BLOCKFS_MAGIC;
	sb->s_ninode = BLOCKFS_NINODE;
	sb->s_inoblk = BLOCKFS_INO_BLK;
	if (bdev_strategy(BLOCKFS_SB_BLK, blk, 1) != 0)
		return (-1);

	/* inode table: inode 0 = "hello" -> data block BLOCKFS_DATA_BLK. */
	for (i = 0; i < BDEV_BSIZE; i++) blk[i] = 0;
	itab = (struct blockfs_inode *)blk;
	itab[0].i_magic = BLOCKFS_MAGIC;
	itab[0].i_dblk = BLOCKFS_DATA_BLK;
	{
		unsigned long n = 0;
		while (fdata[n] != 0) n++;
		itab[0].i_size = n;
		for (i = 0; i < 39 && fname[i]; i++)
			itab[0].i_name[i] = fname[i];
		itab[0].i_name[i] = 0;
	}
	if (bdev_strategy(BLOCKFS_INO_BLK, blk, 1) != 0)
		return (-1);

	/* data block: the file contents. */
	for (i = 0; i < BDEV_BSIZE; i++) blk[i] = 0;
	for (i = 0; fdata[i] != 0 && i < BDEV_BSIZE; i++)
		blk[i] = (unsigned char)fdata[i];
	if (bdev_strategy(BLOCKFS_DATA_BLK, blk, 1) != 0)
		return (-1);
	return (0);
}

/*
 * blockfs_find -- read the inode table (through bdev_strategy) and return the
 * inode index for leaf `name`, or -1.  Fills *dblk/*size.
 */
static int
blockfs_find(const char *name, unsigned long *dblk, unsigned long *size)
{
	unsigned char blk[BDEV_BSIZE];
	struct blockfs_inode *itab;
	unsigned int k;

	if (bdev_strategy(BLOCKFS_INO_BLK, blk, 0) != 0)
		return (-1);
	itab = (struct blockfs_inode *)blk;
	for (k = 0; k < BLOCKFS_NINODE; k++) {
		if (itab[k].i_magic != BLOCKFS_MAGIC)
			continue;
		if (name_eq(itab[k].i_name, name)) {
			if (dblk != 0) *dblk = itab[k].i_dblk;
			if (size != 0) *size = itab[k].i_size;
			return ((int)k);
		}
	}
	return (-1);
}

/*
 * R-P39.3: block-fs WRITE-BACK + persistence.  blockfs_create allocates a free
 * inode slot + a fresh data block for a new leaf, writing the inode table THROUGH
 * bdev_strategy so the file survives an unmount+remount (the RAM disk bdev0 is
 * the persistent backing store; nothing re-mkfs's it).  blockfs_set_size /
 * blockfs_vop_write push a file's data block + its inode size back through the
 * block layer.  CRIB PROVENANCE: the ialloc/balloc + writei write-back path is
 * the illumos ufs (ufs_itrunc/wrip -> bmap -> bwrite) and xv6 fs.c (ialloc/
 * balloc/writei -> log_write/bwrite) block-write model, reduced to one data
 * block per file.
 */
static int
blockfs_create(const char *name, unsigned long *dblk_out)
{
	unsigned char blk[BDEV_BSIZE];
	struct blockfs_inode *itab;
	unsigned int k;
	unsigned long i;

	if (bdev_strategy(BLOCKFS_INO_BLK, blk, 0) != 0)
		return (-1);
	itab = (struct blockfs_inode *)blk;
	/* already present? reuse its inode/data block. */
	for (k = 0; k < BLOCKFS_NINODE; k++) {
		if (itab[k].i_magic == BLOCKFS_MAGIC &&
		    name_eq(itab[k].i_name, name)) {
			if (dblk_out != 0) *dblk_out = itab[k].i_dblk;
			return ((int)k);
		}
	}
	/* first free inode: its data block is DATA_BLK + inode index. */
	for (k = 0; k < BLOCKFS_NINODE; k++) {
		if (itab[k].i_magic == BLOCKFS_MAGIC)
			continue;
		itab[k].i_magic = BLOCKFS_MAGIC;
		itab[k].i_size = 0;
		itab[k].i_dblk = BLOCKFS_DATA_BLK + k;
		if (itab[k].i_dblk >= BDEV_NBLK)
			return (-1);		/* out of data blocks */
		for (i = 0; i < 39 && name[i]; i++)
			itab[k].i_name[i] = name[i];
		itab[k].i_name[i] = 0;
		if (bdev_strategy(BLOCKFS_INO_BLK, blk, 1) != 0) /* write-back */
			return (-1);
		if (dblk_out != 0) *dblk_out = itab[k].i_dblk;
		return ((int)k);
	}
	return (-1);				/* inode table full */
}

/* update a file's recorded size in the inode table (write-back). */
static int
blockfs_set_size(const char *name, unsigned long size)
{
	unsigned char blk[BDEV_BSIZE];
	struct blockfs_inode *itab;
	unsigned int k;

	if (bdev_strategy(BLOCKFS_INO_BLK, blk, 0) != 0)
		return (-1);
	itab = (struct blockfs_inode *)blk;
	for (k = 0; k < BLOCKFS_NINODE; k++) {
		if (itab[k].i_magic == BLOCKFS_MAGIC &&
		    name_eq(itab[k].i_name, name)) {
			itab[k].i_size = size;
			return (bdev_strategy(BLOCKFS_INO_BLK, blk, 1));
		}
	}
	return (-1);
}

/* a blockfs vnode caches the file's first data block number + size. */
static long
blockfs_vop_read(vnode_t *vp, char *ubuf, unsigned long off, unsigned long n)
{
	unsigned char blk[BDEV_BSIZE];
	unsigned long avail, blkno, i;

	if (off >= vp->v_len)
		return (0);			/* EOF */
	avail = vp->v_len - off;
	if (n > avail)
		n = avail;
	/* single-data-block files (<= BDEV_BSIZE): read the block, copy out. */
	blkno = vp->v_cap;			/* v_cap holds the data block no. */
	if (bdev_strategy(blkno, blk, 0) != 0)	/* THROUGH the block layer */
		return (-1);
	for (i = 0; i < n; i++)
		ubuf[i] = (char)blk[off + i];
	return ((long)n);
}
static long
blockfs_vop_write(vnode_t *vp, const char *ubuf, unsigned long off,
    unsigned long n)
{
	unsigned char blk[BDEV_BSIZE];
	unsigned long blkno, i, end;

	/* single-data-block files: bounded by the block size. */
	end = off + n;
	if (end > BDEV_BSIZE)
		return (VERR_EROFS);		/* R-P39.3: >1 block not yet */
	blkno = vp->v_cap;			/* v_cap holds the data block no. */
	if (bdev_strategy(blkno, blk, 0) != 0)	/* read-modify-write */
		return (-1);
	for (i = 0; i < n; i++)
		blk[off + i] = (unsigned char)ubuf[i];
	if (bdev_strategy(blkno, blk, 1) != 0)	/* write-back THROUGH bdev */
		return (-1);
	if (end > vp->v_len) {
		vp->v_len = end;
		/* push the new size to the on-disk inode (persist across mount). */
		if (vp->v_name != 0)
			(void) blockfs_set_size(vp->v_name, vp->v_len);
	}
	return ((long)n);
}
static long
blockfs_vop_getattr(vnode_t *vp, unsigned long *size)
{
	if (size != 0)
		*size = vp->v_len;
	return (0);
}
static const vnodeops_t blockfs_vnodeops = {
	blockfs_vop_read, blockfs_vop_write, blockfs_vop_getattr
};

static int blockfs_mounted;
static int blockfs_fmt_done;		/* R-P39.3: mkfs happens ONCE per boot */

/*
 * vfs_blockfs_mount -- mkfs the RAM disk ONCE (first mount), then verify the
 * superblock reads back through the block layer + mark mounted.  On a REMOUNT
 * (blockfs_fmt_done already set) it does NOT re-mkfs: the bdev0 RAM disk is the
 * persistent backing store, so files written before the unmount are still
 * there -- R-P39.3 persistence across an unmount+remount within a boot.
 * Returns 0 or -errno.
 */
int
vfs_blockfs_mount(void)
{
	unsigned char blk[BDEV_BSIZE];
	struct blockfs_sb *sb = (struct blockfs_sb *)blk;

	if (!blockfs_fmt_done) {		/* format only the first time */
		if (blockfs_mkfs() != 0)
			return (-1);
		blockfs_fmt_done = 1;
	}
	/* verify the superblock reads back through the block layer. */
	if (bdev_strategy(BLOCKFS_SB_BLK, blk, 0) != 0)
		return (-1);
	if (sb->s_magic != BLOCKFS_MAGIC)
		return (-1);
	blockfs_mounted = 1;
	return (0);
}

void
vfs_blockfs_unmount(void)
{
	blockfs_mounted = 0;
}

/*
 * vfs_blockfs_create -- R-P39.3: create (or truncate) leaf `name` on the
 * mounted blockfs and hand back a writable vnode.  The inode is written back
 * through bdev_strategy so the file persists across an unmount+remount.
 */
int
vfs_blockfs_create(const char *name, vnode_t **out)
{
	static vnode_t cvn;		/* one outstanding blockfs create/open */
	unsigned long dblk = 0;

	if (!blockfs_mounted)
		return (VERR_ENOENT);
	if (blockfs_create(name, &dblk) < 0)
		return (VERR_ENOMEM);
	cvn.v_op = &blockfs_vnodeops;
	cvn.v_type = VT_RAMFS;
	cvn.v_len = 0;
	cvn.v_cap = dblk;		/* the data block number */
	cvn.v_name = name;		/* so vop_write can update i_size */
	cvn.v_used = 1;
	*out = &cvn;
	return (0);
}

/*
 * vfs_blockfs_open -- resolve leaf `name` on the mounted blockfs to a transient
 * vnode whose vop_read/vop_write cross bdev_strategy.  Returns 0 or -errno.
 */
int
vfs_blockfs_open(const char *name, vnode_t **out)
{
	static vnode_t bvn;		/* one outstanding blockfs open */
	unsigned long dblk = 0, size = 0;

	if (!blockfs_mounted)
		return (VERR_ENOENT);
	if (blockfs_find(name, &dblk, &size) < 0)
		return (VERR_ENOENT);
	bvn.v_op = &blockfs_vnodeops;
	bvn.v_type = VT_RAMFS;		/* a plain file for fd purposes */
	bvn.v_len = size;
	bvn.v_cap = dblk;		/* stash the data block number */
	bvn.v_name = name;		/* so vop_write can update i_size */
	bvn.v_used = 1;
	*out = &bvn;
	return (0);
}
