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
#define	VERR_EEXIST	(-17)

enum vtype { VT_RAMFS = 0, VT_TMPFS = 1, VT_DIR = 2, VT_BLOCKFS = 3 };
#define	BLOCKFS_DIR_TAG	0xd1720UL	/* v_cap tag: a blockfs directory vnode */

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
	int		v_ino;		/* R-P51: shared tmpfs inode index (-1 none) */
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

/* ---- R-P51: real tmpfs hard links -- a shared inode with an nlink ----- */
/*
 * R-P50's vfs_link COPIED bytes: each tmpfs_tab slot conflated a directory
 * entry (a name) with its file bytes, so two names could not alias one file.
 * R-P51 splits the two: a tmpfs_tab slot is now a DIRECTORY ENTRY (a name +
 * an inode index), and the file's bytes/length/capacity live in a separate
 * tmp_inode with an nlink count.  link(2) allocates a 2nd dir entry pointing
 * at the SAME inode and bumps nlink; unlink(2) frees the entry, drops nlink,
 * and frees the inode's data buffer only at nlink==0; stat sees nlink==2 and
 * the same st_ino for both names, and a write through one name shows through
 * the other (shared data).  This is illumos tmpfs tmpnode (the tn_nlink ref
 * counted node) + VOP_LINK (tdirenter, tn_nlink++) / VOP_REMOVE (tdirdelete,
 * tn_nlink--, tmpnode_free at 0), reduced to a flat inode table.
 */
#define	NTMPINODE	NTMPFILE
typedef struct tmp_inode {
	unsigned char	*i_data;	/* growable kmem buffer (the file bytes) */
	unsigned long	i_len;		/* current length */
	unsigned long	i_cap;		/* allocated capacity */
	unsigned long	i_nlink;	/* directory entries pointing here */
	int		i_used;
} tmp_inode_t;
static tmp_inode_t tmpfs_ino[NTMPINODE];

/* allocate a fresh inode (nlink=1), return its index or -1. */
static int
tmpfs_ino_alloc(void)
{
	int i;
	for (i = 0; i < NTMPINODE; i++)
		if (!tmpfs_ino[i].i_used) {
			tmpfs_ino[i].i_data = 0;
			tmpfs_ino[i].i_len = 0;
			tmpfs_ino[i].i_cap = 0;
			tmpfs_ino[i].i_nlink = 1;
			tmpfs_ino[i].i_used = 1;
			return (i);
		}
	return (-1);
}
/* drop one link; free the data buffer + the inode at nlink==0. */
static void
tmpfs_ino_unlink(int ino)
{
	if (ino < 0 || ino >= NTMPINODE || !tmpfs_ino[ino].i_used)
		return;
	if (tmpfs_ino[ino].i_nlink > 0)
		tmpfs_ino[ino].i_nlink--;
	if (tmpfs_ino[ino].i_nlink == 0) {
		if (tmpfs_ino[ino].i_data != 0)
			kmem_free(tmpfs_ino[ino].i_data, tmpfs_ino[ino].i_cap);
		tmpfs_ino[ino].i_data = 0;
		tmpfs_ino[ino].i_len = 0;
		tmpfs_ino[ino].i_cap = 0;
		tmpfs_ino[ino].i_used = 0;
	}
}
/* exported: st_nlink + st_ino for a tmpfs vnode (0/0 for non-tmpfs). */
void
vfs_ino_attr(vnode_t *vp, unsigned long *nlink, unsigned long *ino)
{
	if (vp != 0 && vp->v_type == VT_TMPFS && vp->v_ino >= 0 &&
	    vp->v_ino < NTMPINODE && tmpfs_ino[vp->v_ino].i_used) {
		if (nlink != 0)
			*nlink = tmpfs_ino[vp->v_ino].i_nlink;
		/* +1 so ino 0 (a real inode) is never confused with "none". */
		if (ino != 0)
			*ino = (unsigned long)vp->v_ino + 1;
		return;
	}
	if (nlink != 0)
		*nlink = 1;
	if (ino != 0)
		*ino = 0;
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
	tmp_inode_t *ip;
	if (vp->v_ino < 0 || !tmpfs_ino[vp->v_ino].i_used)
		return (0);
	ip = &tmpfs_ino[vp->v_ino];
	if (off >= ip->i_len)
		return (0);
	avail = ip->i_len - off;
	if (n > avail)
		n = avail;
	for (i = 0; i < n; i++)
		ubuf[i] = (char)ip->i_data[off + i];
	return ((long)n);
}
static long
tmpfs_vop_write(vnode_t *vp, const char *ubuf, unsigned long off,
    unsigned long n)
{
	unsigned long end = off + n, i;
	tmp_inode_t *ip;
	if (vp->v_ino < 0 || !tmpfs_ino[vp->v_ino].i_used)
		return (VERR_ENOSPC);
	ip = &tmpfs_ino[vp->v_ino];

	/* grow the backing buffer if the write runs past the capacity. */
	if (end > ip->i_cap) {
		unsigned long newcap = (end + TMPFS_CHUNK - 1) &
		    ~(TMPFS_CHUNK - 1);
		unsigned char *nb = kmem_alloc(newcap);
		if (nb == 0)
			return (VERR_ENOSPC);
		for (i = 0; i < ip->i_len; i++)
			nb[i] = ip->i_data ? ip->i_data[i] : 0;
		if (ip->i_data != 0)
			kmem_free(ip->i_data, ip->i_cap);
		ip->i_data = nb;
		ip->i_cap = newcap;
	}
	/* zero-fill any gap between the old end and the write offset. */
	for (i = ip->i_len; i < off; i++)
		ip->i_data[i] = 0;
	for (i = 0; i < n; i++)
		ip->i_data[off + i] = (unsigned char)ubuf[i];
	if (end > ip->i_len)
		ip->i_len = end;
	return ((long)n);
}
static long
tmpfs_vop_getattr(vnode_t *vp, unsigned long *size)
{
	if (size != 0)
		*size = (vp->v_ino >= 0 && tmpfs_ino[vp->v_ino].i_used) ?
		    tmpfs_ino[vp->v_ino].i_len : 0;
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

/* R-P41: a ramfs (read-only archive) directory vnode.  Same no-read/no-write
   dir ops, but a DISTINCT ops vector so vfs_readdir routes to ramfs_readdir
   (the flat-archive child enumeration) instead of the tmpfs name-table scan. */
static const vnodeops_t ramfs_dir_vnodeops = {
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
		vp->v_ino = -1;		/* R-P51: a dir has no tmpfs inode */
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
	/* R-P41: a ramfs archive directory enumerates its flat-archive children. */
	if (dvp->v_op == &ramfs_dir_vnodeops) {
		extern int ramfs_readdir(const char *dirpath, unsigned long index,
		    char *name, unsigned long nsz);
		return (ramfs_readdir(dvp->v_name, index, name, nsz));
	}
	/* R-P41.3: a blockfs directory enumerates its on-disk children (through
	   bdev_strategy).  Its ops vector is defined later; match by v_cap tag. */
	if (dvp->v_cap == BLOCKFS_DIR_TAG) {
		extern int vfs_blockfs_readdir(const char *dir, unsigned long index,
		    char *out, unsigned long osz);
		return (vfs_blockfs_readdir(dvp->v_name, index, name, nsz));
	}
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
			int k, ino = tmpfs_ino_alloc();
			if (ino < 0)
				return (VERR_ENOSPC);
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
			vp->v_ino = ino;
			*out = vp;
			return (0);
		}
	}

	/* ramfs (read-only): build a transient vnode over the archive bytes. */
	{
		static vnode_t scratch;	/* one outstanding ramfs open at a time */
		static char rdir_name[128];	/* R-P41: own the dir path */
		const unsigned char *data;
		unsigned long len;
		extern int ramfs_isdir(const char *path);
		/* R-P41: a ramfs directory ("/", "/bin", "/etc", ...) resolves to a
		   synthetic dir vnode so opendir/getdents can list its children. */
		if (ramfs_lookup(path, &data, &len) != 0) {
			int k;
			if (!ramfs_isdir(path))
				return (VERR_ENOENT);
			for (k = 0; k < 127 && path[k]; k++)
				rdir_name[k] = path[k];
			rdir_name[k] = 0;
			scratch.v_op = &ramfs_dir_vnodeops;
			scratch.v_type = VT_DIR;
			scratch.v_ro_data = 0;
			scratch.v_len = 0;
			scratch.v_name = rdir_name;
			scratch.v_used = 1;
			*out = &scratch;
			return (0);
		}
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

/* R-P41: the vnode type as a small code proc_stat/fstat hands userland so the
   libc can cook a real st_mode (0 = regular file, 1 = directory). */
int
vfs_vtype(vnode_t *vp)
{
	return (vp != 0 && vp->v_type == VT_DIR) ? 1 : 0;
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
	else if (fstype[0] == 'b')	/* "blockfs" (the virtio-blk disk) */
		vt = VT_BLOCKFS;
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
	/*
	 * R-P53 HEADLINE: /blk is a blockfs mount backed by the virtio-blk disk
	 * BY DEFAULT.  bdev_strategy routes its blocks to the real qemu -drive
	 * image (virtio_blk_strategy) whenever a virtio-blk device is present,
	 * so /blk IS the persistent disk -- no RAM fallback unless no disk.
	 */
	(void) vfs_mount("blockfs", "/blk");
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
	/* R-P43: a /blk/NAME path is a directory if the on-disk blockfs inode
	   is a dir (i_type==1); /blk itself is the blockfs root directory. */
	if (path != 0 && path[0] == '/' && path[1] == 'b' &&
	    path[2] == 'l' && path[3] == 'k' &&
	    (path[4] == 0 || path[4] == '/')) {
		extern int vfs_blockfs_isdir(const char *name);
		return (vfs_blockfs_isdir(path[4] == 0 ? "" : path + 5));
	}
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
			/* R-P51: free the dir entry; the inode's data buffer is
			   freed only when its last link goes away (nlink==0). */
			tmpfs_ino_unlink(tmpfs_tab[i].v_ino);
			tmpfs_tab[i].v_used = 0;
			tmpfs_tab[i].v_ino = -1;
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
 * R-P51: vfs_link -- REAL hard link `to` -> `from` (both tmpfs).  A tmpfs_tab
 * slot is now a directory entry (name + inode index); a hard link allocates a
 * 2nd dir entry that references the SAME inode as `from` and bumps the inode's
 * nlink.  Both names then share one buffer -- a write through one shows through
 * the other, stat reports nlink==2 + the same st_ino, and the file's data is
 * freed only when the last link is unlinked (nlink drops to 0).  This is the
 * illumos tmpfs VOP_LINK (tdirenter of a 2nd tdirent at the same tmpnode,
 * tn_nlink++), reduced to the flat inode table.
 * Returns 0 or a negative errno.
 */
int
vfs_link(const char *from, const char *to)
{
	int i, src = -1, free_slot = -1;
	if (mount_fstype(from) != VT_TMPFS || mount_fstype(to) != VT_TMPFS)
		return (VERR_EROFS);
	for (i = 0; i < NTMPFILE; i++) {
		if (tmpfs_tab[i].v_used && name_eq(tmpfs_tab[i].v_name, to))
			return (VERR_EEXIST);
		if (tmpfs_tab[i].v_used && tmpfs_tab[i].v_type == VT_TMPFS &&
		    name_eq(tmpfs_tab[i].v_name, from))
			src = i;
		if (!tmpfs_tab[i].v_used && free_slot < 0)
			free_slot = i;
	}
	if (src < 0)
		return (VERR_ENOENT);
	if (free_slot < 0)
		return (VERR_ENOSPC);
	if (tmpfs_tab[src].v_ino < 0)
		return (VERR_ENOENT);
	{
		vnode_t *dp = &tmpfs_tab[free_slot];
		int ino = tmpfs_tab[src].v_ino;
		int k;
		for (k = 0; k < 63 && to[k]; k++)
			tmpfs_names[free_slot][k] = to[k];
		tmpfs_names[free_slot][k] = 0;
		dp->v_op = &tmpfs_vnodeops;
		dp->v_type = VT_TMPFS;
		dp->v_rw_data = 0;
		dp->v_len = 0;
		dp->v_cap = 0;
		dp->v_name = tmpfs_names[free_slot];
		dp->v_used = 1;
		dp->v_ino = ino;		/* SHARE the source inode */
		tmpfs_ino[ino].i_nlink++;	/* a 2nd name -> nlink==2 */
		return (0);
	}
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
	if (vp->v_ino >= 0 && tmpfs_ino[vp->v_ino].i_used)
		tmpfs_ino[vp->v_ino].i_len = 0;	/* R-P51: truncate the inode */
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
#define	BDEV_NBLK	8192		/* logical fs capacity: 4 MiB / 512 = 8192 blocks (matches disk.img) */
#define	BDEV_RAM_NBLK	256		/* the RAM fallback disk: 128 KiB (no static 4 MiB BSS) */
#define	BLOCKFS_MAGIC	0x53464e42UL	/* "BNFS" -- solniX blockfs */
#define	BLOCKFS_NINODE	32	/* R-P55: 32 inodes for the root-pivot /bin+/sbin+/etc */

/*
 * R-P54 on-disk layout (crib: xv6 fs.c superblock/inode/bitmap + illumos ufs
 * cylinder-group free-block bitmap).  A file is no longer one block: an inode
 * carries NDIRECT direct block pointers + one SINGLY-INDIRECT block, and data
 * blocks are allocated from a FREE-BLOCK BITMAP, not a bump index.
 *
 *   blk 0        superblock
 *   blk 1..8     inode table (BLOCKFS_INO_NBLK blocks, 4 inodes/512B block)
 *   blk 9..10    free-block bitmap (BLOCKFS_BMAP_NBLK blocks, 1 bit/block)
 *   blk 11..     data blocks (balloc/bfree'd)
 */
#define	BLOCKFS_SB_BLK		0
#define	BLOCKFS_INO_BLK		1	/* first inode-table block */
#define	BLOCKFS_INO_NBLK	8	/* R-P55: 8 blocks * 4 inodes = 32 inodes */
#define	BLOCKFS_BMAP_BLK	9	/* first bitmap block (after the 8-block inode table) */
#define	BLOCKFS_BMAP_NBLK	2	/* 2 blocks * 4096 bits = 8192 blocks */
#define	BLOCKFS_DATA_BLK	11	/* first data block */
#define	NDIRECT			8	/* direct block pointers per inode */
#define	NINDIRECT		(BDEV_BSIZE / sizeof (unsigned long))

/* the RAM-backed block device: a small fallback disk (128 KiB) used ONLY when
   there is no virtio-blk disk.  The logical fs capacity is BDEV_NBLK (8192);
   balloc is clamped to the REAL device capacity at run time. */
static unsigned char bdev0[BDEV_RAM_NBLK][BDEV_BSIZE];

/*
 * R-P56: partition base LBA.  When disk.img carries an MBR partition table,
 * the blockfs root fs lives IN partition 1 (not at raw sector 0).  All blockfs
 * traffic routes through bdev_strategy, so a single offset here makes the whole
 * fs read/write from the partition.  0 means "no partition table -- fs at LBA 0"
 * (the RAM disk + the legacy raw-disk path).  Crib: the DOS/MBR partition table
 * (sector 0, 4x 16-byte entries at 0x1BE, LE start-LBA at entry+8, 0x55AA sig)
 * -- illumos usr/src/uts/common/sys/dktp/fdisk.h / cmlb partition mapping.
 */
unsigned long blockfs_part_base = 0;
int blockfs_part_is_gpt = 0;	/* R-P57: 1 if the base came from a GPT, 0 if MBR/none */
int blockfs_part_by_guid = 0;	/* R-P59: 1 if the root was matched by TYPE GUID (not position) */

/*
 * R-P59: the partition TYPE GUIDs the kernel accepts as "the root".  A GPT type
 * GUID is stored MIXED-ENDIAN per the UEFI spec (sec 5.3.1): the first three
 * fields (u32, u16, u16) are little-endian, the last two (u8[2], u8[6]) are
 * big-endian.  These 16-byte arrays are the ON-DISK byte order, so a raw
 * memcmp against the entry's +0..+15 bytes matches.
 *
 *  LINUX_ROOT_RV64 = 72EC70A6-CF74-40E6-BD49-4BDA08E8F224 (the arch-specific
 *  Linux root-partition GUID for riscv64, per the Discoverable Partitions Spec).
 *  SOLNIX_ROOT     = 2E54B353-1271-4842-806F-000000000002 (our own solnix-root
 *  type, laid by the build-kernel.sh GPT builder).
 * Matching by TYPE GUID (not the FIRST-non-empty entry) finds the root REGARDLESS
 * of its position in the entry array -- real GPT robustness.
 */
static const unsigned char ROOT_GUIDS[][16] = {
	/* 72EC70A6-CF74-40E6-BD49-4BDA08E8F224 (Linux riscv64 root, DPS) */
	{ 0xa6,0x70,0xec,0x72, 0x74,0xcf, 0xe6,0x40,
	  0xbd,0x49, 0x4b,0xda,0x08,0xe8,0xf2,0x24 },
	/* 2E54B353-1271-4842-806F-000000000002 (solnix-root) */
	{ 0x53,0xb3,0x54,0x2e, 0x71,0x12, 0x42,0x48,
	  0x80,0x6f, 0x00,0x00,0x00,0x00,0x00,0x02 },
};

static int
is_root_type_guid(const unsigned char *g)
{
	unsigned int t, k;
	for (t = 0; t < sizeof (ROOT_GUIDS) / 16; t++) {
		for (k = 0; k < 16; k++)
			if (g[k] != ROOT_GUIDS[t][k])
				break;
		if (k == 16)
			return (1);
	}
	return (0);
}

/*
 * blockfs_probe_partition -- read the disk's partition table off the live
 * virtio-blk disk and set blockfs_part_base to the root partition's starting
 * LBA.  Handles BOTH layouts, GPT first (the modern UEFI/RISC-V layout):
 *
 *   1. Read LBA 0.  If it holds a protective MBR (a single 0xEE-type entry),
 *      read the GPT header at LBA 1 (signature "EFI PART"), then the
 *      partition-entry array (starting LBA + entry size/count from the header)
 *      and take the entry whose TYPE GUID matches a known root GUID (R-P59 --
 *      Linux riscv64-root or solnix-root); if none match, fall back to the
 *      FIRST non-empty entry's first-LBA (R-P57 behaviour).  Matching by TYPE
 *      GUID finds the root REGARDLESS of its position in the array.
 *   2. Otherwise fall back to the R-P56 DOS/MBR path (partition 1 at 0x1BE,
 *      LE start-LBA at +8, 0x55AA signature).
 *
 * Called once, before the first blockfs mount, so every subsequent
 * bdev_strategy block is relative to the partition.  Returns the base LBA
 * (0 if no recognizable table).  Sets blockfs_part_is_gpt for the milestone.
 *
 * Crib: the UEFI spec sec 5.3 (GPT: protective MBR type 0xEE at 0x1BE, the GPT
 * header at LBA 1 with "EFI PART" magic, u32 num-part-entries @ +80, u32
 * size-of-entry @ +84, u64 partition-entry-LBA @ +72; each 128-byte entry has a
 * 16-byte type GUID @ +0 [all-zero = unused] and a u64 first-LBA @ +32) +
 * illumos usr/src/common/efi/efi_crc32.c / uts/common/sys/efi_partition.h.
 */
unsigned long
blockfs_probe_partition(void)
{
	extern int virtio_blk_present(void);
	extern int virtio_blk_strategy(unsigned long, unsigned char *, int);
	unsigned char sec[BDEV_BSIZE];
	unsigned char gpt[BDEV_BSIZE];
	unsigned long lba;
	unsigned char *pe;
	int is_gpt = 0;

	blockfs_part_base = 0;
	blockfs_part_is_gpt = 0;
	blockfs_part_by_guid = 0;
	if (!virtio_blk_present())
		return (0);
	if (virtio_blk_strategy(0, sec, 0) != 0)
		return (0);
	if (sec[510] != 0x55 || sec[511] != 0xAA)
		return (0);		/* neither MBR nor GPT (no boot sig) */

	pe = &sec[0x1BE];
	/* GPT? a protective-MBR entry has type 0xEE. */
	if (pe[4] == 0xEE)
		is_gpt = 1;

	if (is_gpt) {
		unsigned long pa_lba;	/* partition-entry-array LBA */
		unsigned int nentries, entsz;
		unsigned int ent_per_blk, e, blk;
		static const char sig[8] = { 'E','F','I',' ','P','A','R','T' };
		int i;

		if (virtio_blk_strategy(1, gpt, 0) != 0)
			return (0);
		for (i = 0; i < 8; i++)
			if (gpt[i] != (unsigned char)sig[i])
				return (0);	/* no valid GPT header */
		/* header: partition-entry-LBA @ +72 (u64), num @ +80, size @ +84 */
		pa_lba = (unsigned long)gpt[72] | ((unsigned long)gpt[73] << 8) |
		    ((unsigned long)gpt[74] << 16) | ((unsigned long)gpt[75] << 24) |
		    ((unsigned long)gpt[76] << 32) | ((unsigned long)gpt[77] << 40) |
		    ((unsigned long)gpt[78] << 48) | ((unsigned long)gpt[79] << 56);
		nentries = (unsigned int)gpt[80] | ((unsigned int)gpt[81] << 8) |
		    ((unsigned int)gpt[82] << 16) | ((unsigned int)gpt[83] << 24);
		entsz = (unsigned int)gpt[84] | ((unsigned int)gpt[85] << 8) |
		    ((unsigned int)gpt[86] << 16) | ((unsigned int)gpt[87] << 24);
		if (entsz == 0 || entsz > BDEV_BSIZE || nentries == 0)
			return (0);
		ent_per_blk = BDEV_BSIZE / entsz;
		/*
		 * R-P59: scan the entry array preferring an entry whose TYPE GUID
		 * (bytes +0..+15) is a known root GUID; remember the first non-empty
		 * entry as a fallback.  Matching by TYPE GUID finds the root no
		 * matter where it sits in the array -- so a decoy/boot partition can
		 * precede it and the kernel still lands on the real root.
		 */
		{
		unsigned long fallback_lba = 0;
		for (e = 0; e < nentries; e++) {
			unsigned char *ent;
			int nonzero = 0, k;
			unsigned long elba;
			blk = e / ent_per_blk;
			if (virtio_blk_strategy(pa_lba + blk, sec, 0) != 0)
				return (0);
			ent = &sec[(e % ent_per_blk) * entsz];
			for (k = 0; k < 16; k++)
				if (ent[k] != 0) { nonzero = 1; break; }
			if (!nonzero)
				continue;
			/* first-LBA @ +32 (u64 LE) */
			elba = (unsigned long)ent[32] | ((unsigned long)ent[33] << 8) |
			    ((unsigned long)ent[34] << 16) | ((unsigned long)ent[35] << 24) |
			    ((unsigned long)ent[36] << 32) | ((unsigned long)ent[37] << 40) |
			    ((unsigned long)ent[38] << 48) | ((unsigned long)ent[39] << 56);
			if (is_root_type_guid(ent)) {
				blockfs_part_base = elba;
				blockfs_part_is_gpt = 1;
				blockfs_part_by_guid = 1;
				return (elba);	/* matched by TYPE GUID -- done */
			}
			if (fallback_lba == 0)
				fallback_lba = elba;
		}
		if (fallback_lba != 0) {
			/* no typed root -- R-P57 first-non-empty fallback */
			blockfs_part_base = fallback_lba;
			blockfs_part_is_gpt = 1;
			return (fallback_lba);
		}
		}
		return (0);		/* GPT with no populated entry */
	}

	/* R-P56 DOS/MBR fallback: partition 1 at 0x1BE, LE start-LBA at +8. */
	if (pe[4] == 0)
		return (0);
	lba = (unsigned long)pe[8] | ((unsigned long)pe[9] << 8) |
	    ((unsigned long)pe[10] << 16) | ((unsigned long)pe[11] << 24);
	blockfs_part_base = lba;
	return (lba);
}

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
	extern int virtio_blk_present(void);
	extern int virtio_blk_strategy(unsigned long, unsigned char *, int);
	extern int dwmmc_present(void);
	extern int dwmmc_strategy(unsigned long, unsigned char *, int);
	extern int sdhci_present(void);
	extern int sdhci_strategy(unsigned long, unsigned char *, int);

	/*
	 * R-P52: when a REAL virtio-blk disk is live, route the block through it
	 * (a persistent qemu -drive image); otherwise fall back to the RAM disk
	 * (bdev0).  blockfs itself is unchanged -- it only ever calls here.
	 *
	 * R-P58: a dw-mmc SD/eMMC host is the real-board root medium (VisionFive 2
	 * / most dw-mshc SoCs).  Dispatch order = whichever DTB-discovered device
	 * is PRESENT: virtio-blk first (qemu-virt -- so qemu is regression-safe and
	 * ALWAYS takes this path, dwmmc_present() is 0 under qemu since there is no
	 * mmc DTB node), then dw-mmc (the board), then the RAM disk.  Same
	 * (blkno+part_base, buf, rw) shape for both real drivers.
	 */
	if (virtio_blk_present())
		return (virtio_blk_strategy(blkno + blockfs_part_base, buf, rw));
	if (dwmmc_present())
		return (dwmmc_strategy(blkno + blockfs_part_base, buf, rw));
	/*
	 * R-P62: SDHCI (the SpacemiT K1 root medium -- spacemit,k1-sdhci @
	 * 0xd4280000, a STANDARD SDHCI core, NOT dw-mmc).  DTB-selected: the FDT
	 * walker classifies the K1 mmc node FDT_MMC_SDHCI and binds sdhci_set_base;
	 * sdhci_present() is 0 under qemu-virt (no SDHCI node -> unbound), so qemu
	 * ALWAYS takes the virtio-blk path above and this arm is board-only.  Same
	 * (blkno+part_base, buf, rw) shape as the other real drivers.
	 */
	if (sdhci_present())
		return (sdhci_strategy(blkno + blockfs_part_base, buf, rw));

	if (blkno >= BDEV_RAM_NBLK)
		return (-1);
	if (rw == 0)
		for (i = 0; i < BDEV_BSIZE; i++)
			buf[i] = bdev0[blkno][i];
	else
		for (i = 0; i < BDEV_BSIZE; i++)
			bdev0[blkno][i] = buf[i];
	return (0);
}

/* on-disk inode (packed into the inode-table blocks).  R-P41: i_type marks a
   directory (1) vs a regular file (0); i_name holds the path RELATIVE to the
   blockfs root, so a nested leaf is stored as "sub/f".  R-P54: i_addr[] holds
   NDIRECT direct data-block numbers + i_indir points at a singly-indirect block
   (128 more pointers), so a file spans MANY blocks (xv6 fs.c dinode.addrs). */
struct blockfs_inode {
	unsigned long	i_magic;	/* BLOCKFS_MAGIC if in use, else 0 */
	unsigned long	i_size;		/* file size in bytes */
	unsigned long	i_type;		/* 0 = regular file, 1 = directory */
	unsigned long	i_addr[NDIRECT];/* direct data-block numbers (0 = hole) */
	unsigned long	i_indir;	/* singly-indirect block (0 = none) */
	char		i_name[32];	/* path relative to the blockfs root */
};
#define	INO_PER_BLK	(BDEV_BSIZE / sizeof (struct blockfs_inode))

/* superblock (block 0). */
struct blockfs_sb {
	unsigned long	s_magic;
	unsigned long	s_ninode;
	unsigned long	s_inoblk;	/* first block holding the inode table */
	unsigned long	s_version;	/* R-P54 layout marker (2) */
};

/*
 * R-P54 inode-table access.  The table now spans BLOCKFS_INO_NBLK blocks with
 * INO_PER_BLK inodes each, so inode k lives in block INO_BLK + k/INO_PER_BLK at
 * slot k%INO_PER_BLK.  iread/iwrite move ONE inode; used to avoid a full-table
 * rewrite for a single change (xv6 iupdate).
 */
static int
blockfs_iread(unsigned int k, struct blockfs_inode *out)
{
	unsigned char blk[BDEV_BSIZE];
	struct blockfs_inode *itab;
	if (k >= BLOCKFS_NINODE)
		return (-1);
	if (bdev_strategy(BLOCKFS_INO_BLK + k / INO_PER_BLK, blk, 0) != 0)
		return (-1);
	itab = (struct blockfs_inode *)blk;
	*out = itab[k % INO_PER_BLK];
	return (0);
}
static int
blockfs_iwrite(unsigned int k, const struct blockfs_inode *in)
{
	unsigned char blk[BDEV_BSIZE];
	struct blockfs_inode *itab;
	if (k >= BLOCKFS_NINODE)
		return (-1);
	if (bdev_strategy(BLOCKFS_INO_BLK + k / INO_PER_BLK, blk, 0) != 0)
		return (-1);
	itab = (struct blockfs_inode *)blk;
	itab[k % INO_PER_BLK] = *in;
	return (bdev_strategy(BLOCKFS_INO_BLK + k / INO_PER_BLK, blk, 1));
}

/*
 * R-P54 FREE-BLOCK BITMAP (crib: xv6 fs.c balloc/bfree; illumos ufs cg bitmap).
 * One bit per device block across BLOCKFS_BMAP_NBLK blocks; bit set == in use.
 * balloc scans for the first clear data-block bit, sets it, zeroes the block,
 * and returns its number (0 == out of space).  bfree clears the bit.
 * blockfs_bfree_count counts clear bits (for statvfs f_bfree).
 */
static int
bmap_get(unsigned long blkno, int *val)
{
	unsigned char blk[BDEV_BSIZE];
	unsigned long bmblk = BLOCKFS_BMAP_BLK + (blkno / 8) / BDEV_BSIZE;
	unsigned long byte = (blkno / 8) % BDEV_BSIZE;
	if (bdev_strategy(bmblk, blk, 0) != 0)
		return (-1);
	*val = (blk[byte] >> (blkno % 8)) & 1;
	return (0);
}
static int
bmap_set(unsigned long blkno, int val)
{
	unsigned char blk[BDEV_BSIZE];
	unsigned long bmblk = BLOCKFS_BMAP_BLK + (blkno / 8) / BDEV_BSIZE;
	unsigned long byte = (blkno / 8) % BDEV_BSIZE;
	unsigned char mask = (unsigned char)(1u << (blkno % 8));
	if (bdev_strategy(bmblk, blk, 0) != 0)
		return (-1);
	if (val)
		blk[byte] |= mask;
	else
		blk[byte] &= (unsigned char)~mask;
	return (bdev_strategy(bmblk, blk, 1));
}
static unsigned long
bdev_ncap(void)
{
	extern int virtio_blk_present(void);
	extern unsigned long virtio_blk_capacity(void);
	unsigned long c;
	if (virtio_blk_present()) {
		c = virtio_blk_capacity();
		if (c == 0 || c > BDEV_NBLK)
			c = BDEV_NBLK;
		return (c);
	}
	return (BDEV_RAM_NBLK);
}
static unsigned long
balloc(void)
{
	unsigned char zero[BDEV_BSIZE];
	unsigned long b, cap = bdev_ncap();
	int v;
	for (b = BLOCKFS_DATA_BLK; b < cap; b++) {
		if (bmap_get(b, &v) != 0)
			return (0);
		if (v == 0) {
			unsigned long i;
			if (bmap_set(b, 1) != 0)
				return (0);
			for (i = 0; i < BDEV_BSIZE; i++) zero[i] = 0;
			(void) bdev_strategy(b, zero, 1);
			return (b);
		}
	}
	return (0);			/* out of free blocks */
}
static void
bfree(unsigned long blkno)
{
	if (blkno >= BLOCKFS_DATA_BLK && blkno < bdev_ncap())
		(void) bmap_set(blkno, 0);
}
static unsigned long
blockfs_bfree_count(void)
{
	unsigned long b, free = 0, cap = bdev_ncap();
	int v;
	for (b = 0; b < cap; b++)
		if (bmap_get(b, &v) == 0 && v == 0)
			free++;
	return (free);
}

/*
 * bmap -- resolve file block number `fbn` (0-based) to a device block, like
 * xv6 fs.c bmap.  fbn < NDIRECT: the direct pointer i_addr[fbn].  Otherwise the
 * singly-indirect block i_indir at slot (fbn - NDIRECT).  If `alloc` and the
 * slot is a hole, balloc a block and record it (rewriting the inode/indirect
 * block as needed).  Returns the device block (0 == hole/no space).  On alloc,
 * *dirty is set so the caller persists inode k.
 */
static unsigned long
bmap(unsigned int k, struct blockfs_inode *ino, unsigned long fbn, int alloc,
    int *dirty)
{
	unsigned char blk[BDEV_BSIZE];
	unsigned long *ptrs, b;

	if (fbn < NDIRECT) {
		if (ino->i_addr[fbn] == 0 && alloc) {
			if ((b = balloc()) == 0)
				return (0);
			ino->i_addr[fbn] = b;
			*dirty = 1;
		}
		return (ino->i_addr[fbn]);
	}
	fbn -= NDIRECT;
	if (fbn >= NINDIRECT)
		return (0);		/* beyond one indirect block */
	if (ino->i_indir == 0) {
		if (!alloc)
			return (0);
		if ((b = balloc()) == 0)
			return (0);
		ino->i_indir = b;
		*dirty = 1;
	}
	if (bdev_strategy(ino->i_indir, blk, 0) != 0)
		return (0);
	ptrs = (unsigned long *)blk;
	if (ptrs[fbn] == 0) {
		if (!alloc)
			return (0);
		if ((b = balloc()) == 0)
			return (0);
		ptrs[fbn] = b;
		if (bdev_strategy(ino->i_indir, blk, 1) != 0)
			return (0);
	}
	(void) k;
	return (ptrs[fbn]);
}

/* free every data block an inode references (direct + indirect), for unlink. */
static void
blockfs_itrunc(struct blockfs_inode *ino)
{
	unsigned char blk[BDEV_BSIZE];
	unsigned long *ptrs, i;
	for (i = 0; i < NDIRECT; i++)
		if (ino->i_addr[i] != 0) {
			bfree(ino->i_addr[i]);
			ino->i_addr[i] = 0;
		}
	if (ino->i_indir != 0) {
		if (bdev_strategy(ino->i_indir, blk, 0) == 0) {
			ptrs = (unsigned long *)blk;
			for (i = 0; i < NINDIRECT; i++)
				if (ptrs[i] != 0)
					bfree(ptrs[i]);
		}
		bfree(ino->i_indir);
		ino->i_indir = 0;
	}
	ino->i_size = 0;
}

/*
 * blockfs_mkfs -- lay a fresh R-P54 blockfs onto the device: superblock, zeroed
 * inode-table blocks, and a free-block bitmap with the metadata blocks (SB +
 * inode table + bitmap) marked in-use.  Then create one file "hello" via the
 * real balloc/bmap path so a freshly-mkfs'd disk has a readable file.  All I/O
 * goes through bdev_strategy (the block layer).  Returns 0.
 */
static int
blockfs_mkfs(void)
{
	unsigned char blk[BDEV_BSIZE];
	struct blockfs_sb *sb = (struct blockfs_sb *)blk;
	struct blockfs_inode ino;
	unsigned long i, b, dblk;
	int dirty = 0;
	static const char fname[] = "hello";
	static const char fdata[] =
	    "solnix riscv64 blockfs (R-P38): read via a block vnode + "
	    "bdev_strategy, not ramfs.\n";

	/* superblock. */
	for (i = 0; i < BDEV_BSIZE; i++) blk[i] = 0;
	sb->s_magic = BLOCKFS_MAGIC;
	sb->s_ninode = BLOCKFS_NINODE;
	sb->s_inoblk = BLOCKFS_INO_BLK;
	sb->s_version = 3;
	if (bdev_strategy(BLOCKFS_SB_BLK, blk, 1) != 0)
		return (-1);

	/* zero the inode-table + bitmap blocks. */
	for (i = 0; i < BDEV_BSIZE; i++) blk[i] = 0;
	for (b = BLOCKFS_INO_BLK; b < BLOCKFS_DATA_BLK; b++)
		if (bdev_strategy(b, blk, 1) != 0)
			return (-1);

	/* mark the metadata blocks (0 .. DATA_BLK-1) in-use in the bitmap. */
	for (b = 0; b < BLOCKFS_DATA_BLK; b++)
		if (bmap_set(b, 1) != 0)
			return (-1);
	/*
	 * R-P55: reserve sectors 100/101 -- the R-P52.1 raw-sector marker +
	 * write-test blocks live there, outside the fs.  Now that the root
	 * fs populates real data blocks (balloc scans low-first and would
	 * otherwise reach sector 100), mark them in-use so the fs never
	 * allocates over the R-P52 raw-disk proof.
	 */
	(void) bmap_set(100, 1);
	(void) bmap_set(101, 1);

	/* inode 0 = "hello": allocate its data via balloc/bmap. */
	for (i = 0; i < sizeof (ino); i++) ((unsigned char *)&ino)[i] = 0;
	ino.i_magic = BLOCKFS_MAGIC;
	ino.i_type = 0;
	{
		unsigned long n = 0;
		while (fdata[n] != 0) n++;
		ino.i_size = n;
		for (i = 0; i < 31 && fname[i]; i++)
			ino.i_name[i] = fname[i];
		ino.i_name[i] = 0;
	}
	if ((dblk = bmap(0, &ino, 0, 1, &dirty)) == 0)
		return (-1);
	if (blockfs_iwrite(0, &ino) != 0)
		return (-1);
	for (i = 0; i < BDEV_BSIZE; i++) blk[i] = 0;
	for (i = 0; fdata[i] != 0 && i < BDEV_BSIZE; i++)
		blk[i] = (unsigned char)fdata[i];
	if (bdev_strategy(dblk, blk, 1) != 0)
		return (-1);
	return (0);
}

/*
 * blockfs_find -- scan the inode table (through blockfs_iread) for leaf `name`.
 * Returns the inode index, or -1.  Fills *size (the data block is now found via
 * bmap, so we return the inode index in *ino instead of a single block no.).
 */
static int
blockfs_find(const char *name, unsigned long *ino_out, unsigned long *size)
{
	struct blockfs_inode ino;
	unsigned int k;

	for (k = 0; k < BLOCKFS_NINODE; k++) {
		if (blockfs_iread(k, &ino) != 0)
			return (-1);
		if (ino.i_magic != BLOCKFS_MAGIC)
			continue;
		if (name_eq(ino.i_name, name)) {
			if (ino_out != 0) *ino_out = k;
			if (size != 0) *size = ino.i_size;
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
blockfs_create(const char *name, unsigned long *ino_out)
{
	struct blockfs_inode ino;
	unsigned int k;
	unsigned long i;

	/* already present? reuse its inode. */
	for (k = 0; k < BLOCKFS_NINODE; k++) {
		if (blockfs_iread(k, &ino) != 0)
			return (-1);
		if (ino.i_magic == BLOCKFS_MAGIC && name_eq(ino.i_name, name)) {
			if (ino_out != 0) *ino_out = k;
			return ((int)k);
		}
	}
	/* first free inode: NO data blocks yet (bmap allocates on write). */
	for (k = 0; k < BLOCKFS_NINODE; k++) {
		if (blockfs_iread(k, &ino) != 0)
			return (-1);
		if (ino.i_magic == BLOCKFS_MAGIC)
			continue;
		for (i = 0; i < sizeof (ino); i++)
			((unsigned char *)&ino)[i] = 0;
		ino.i_magic = BLOCKFS_MAGIC;
		ino.i_size = 0;
		ino.i_type = 0;
		for (i = 0; i < 31 && name[i]; i++)
			ino.i_name[i] = name[i];
		ino.i_name[i] = 0;
		if (blockfs_iwrite(k, &ino) != 0)	/* write-back */
			return (-1);
		if (ino_out != 0) *ino_out = k;
		return ((int)k);
	}
	return (-1);				/* inode table full */
}

/*
 * blockfs_mkdir -- R-P41.3: allocate a DIRECTORY inode named `name` (relative
 * to the blockfs root, e.g. "sub"), written back THROUGH bdev_strategy so the
 * directory persists across an unmount+remount.  A dir inode carries i_type==1
 * and no data block (its "contents" are the child inodes whose names are
 * "name/<leaf>").  Returns the inode index or -1.
 */
static int
blockfs_mkdir(const char *name)
{
	struct blockfs_inode ino;
	unsigned int k;
	unsigned long i;

	for (k = 0; k < BLOCKFS_NINODE; k++) {
		if (blockfs_iread(k, &ino) != 0)
			return (-1);
		if (ino.i_magic == BLOCKFS_MAGIC && name_eq(ino.i_name, name))
			return ((int)k);	/* already exists */
	}
	for (k = 0; k < BLOCKFS_NINODE; k++) {
		if (blockfs_iread(k, &ino) != 0)
			return (-1);
		if (ino.i_magic == BLOCKFS_MAGIC)
			continue;
		for (i = 0; i < sizeof (ino); i++)
			((unsigned char *)&ino)[i] = 0;
		ino.i_magic = BLOCKFS_MAGIC;
		ino.i_size = 0;
		ino.i_type = 1;			/* directory */
		for (i = 0; i < 31 && name[i]; i++)
			ino.i_name[i] = name[i];
		ino.i_name[i] = 0;
		if (blockfs_iwrite(k, &ino) != 0)
			return (-1);
		return ((int)k);
	}
	return (-1);
}

/*
 * blockfs_isdir -- is the relative name `name` a directory inode on disk?
 * blockfs_readdir -- return the `index`th direct-child leaf of directory `dir`
 * (relative name, "" == the blockfs root) into `out`; enumerates inodes whose
 * name is "dir/<leaf>" with no further '/'.  Both read the inode table THROUGH
 * bdev_strategy.  Returns 1/0 (readdir) or the type (isdir).
 */
static int
blockfs_isdir(const char *name)
{
	struct blockfs_inode ino;
	unsigned int k;
	if (name != 0 && name[0] == 0)
		return (1);			/* blockfs root is a directory */
	for (k = 0; k < BLOCKFS_NINODE; k++) {
		if (blockfs_iread(k, &ino) != 0)
			return (0);
		if (ino.i_magic == BLOCKFS_MAGIC && name_eq(ino.i_name, name))
			return (ino.i_type == 1);
	}
	return (0);
}

/* is the inode name `nm` a direct child of directory `dir` ("" == root)?
   fills *b = index of the leaf basename within nm.  root: nm has no '/'.  */
static int
blockfs_child_of(const char *nm, const char *dir, unsigned int *b)
{
	unsigned int i, dl = 0;
	while (dir[dl] != 0) dl++;
	if (dl == 0) {
		/* root: nm must have NO '/' (a top-level leaf/dir). */
		for (i = 0; nm[i] != 0; i++)
			if (nm[i] == '/')
				return (0);
		*b = 0;
		return (nm[0] != 0);
	}
	/* nm must start with dir + '/' and have no further '/'. */
	for (i = 0; i < dl; i++)
		if (nm[i] != dir[i])
			return (0);
	if (nm[dl] != '/')
		return (0);
	for (i = dl + 1; nm[i] != 0; i++)
		if (nm[i] == '/')
			return (0);
	if (nm[dl + 1] == 0)
		return (0);
	*b = dl + 1;
	return (1);
}

static int
blockfs_readdir(const char *dir, unsigned long index, char *out,
    unsigned long osz)
{
	struct blockfs_inode ino;
	unsigned int k;
	unsigned long seen = 0;

	for (k = 0; k < BLOCKFS_NINODE; k++) {
		unsigned int b = 0, j = 0;
		if (blockfs_iread(k, &ino) != 0)
			return (0);
		if (ino.i_magic != BLOCKFS_MAGIC)
			continue;
		if (!blockfs_child_of(ino.i_name, dir, &b))
			continue;
		if (seen == index) {
			while (ino.i_name[b + j] != 0 && j + 1 < osz) {
				out[j] = ino.i_name[b + j];
				j++;
			}
			out[j] = 0;
			return (1);
		}
		seen++;
	}
	return (0);
}

/* update a file's recorded size in the inode table (write-back). */
static int
blockfs_set_size(const char *name, unsigned long size)
{
	struct blockfs_inode ino;
	unsigned int k;

	for (k = 0; k < BLOCKFS_NINODE; k++) {
		if (blockfs_iread(k, &ino) != 0)
			return (-1);
		if (ino.i_magic == BLOCKFS_MAGIC && name_eq(ino.i_name, name)) {
			ino.i_size = size;
			return (blockfs_iwrite(k, &ino));
		}
	}
	return (-1);
}

/* a blockfs vnode's v_cap holds the INODE INDEX; multi-block read via bmap. */
static long
blockfs_vop_read(vnode_t *vp, char *ubuf, unsigned long off, unsigned long n)
{
	unsigned char blk[BDEV_BSIZE];
	struct blockfs_inode ino;
	unsigned long avail, done = 0;
	int dirty = 0;

	if (off >= vp->v_len)
		return (0);			/* EOF */
	avail = vp->v_len - off;
	if (n > avail)
		n = avail;
	if (blockfs_iread((unsigned int)vp->v_cap, &ino) != 0)
		return (-1);
	while (done < n) {
		unsigned long fbn = (off + done) / BDEV_BSIZE;
		unsigned long boff = (off + done) % BDEV_BSIZE;
		unsigned long chunk = BDEV_BSIZE - boff;
		unsigned long dblk, i;
		if (chunk > n - done)
			chunk = n - done;
		dblk = bmap((unsigned int)vp->v_cap, &ino, fbn, 0, &dirty);
		if (dblk == 0) {		/* a hole reads as zeros */
			for (i = 0; i < chunk; i++)
				ubuf[done + i] = 0;
		} else {
			if (bdev_strategy(dblk, blk, 0) != 0)
				return (-1);
			for (i = 0; i < chunk; i++)
				ubuf[done + i] = (char)blk[boff + i];
		}
		done += chunk;
	}
	return ((long)n);
}
static long
blockfs_vop_write(vnode_t *vp, const char *ubuf, unsigned long off,
    unsigned long n)
{
	unsigned char blk[BDEV_BSIZE];
	struct blockfs_inode ino;
	unsigned long done = 0, end = off + n;
	int dirty = 0;

	if (blockfs_iread((unsigned int)vp->v_cap, &ino) != 0)
		return (-1);
	while (done < n) {
		unsigned long fbn = (off + done) / BDEV_BSIZE;
		unsigned long boff = (off + done) % BDEV_BSIZE;
		unsigned long chunk = BDEV_BSIZE - boff;
		unsigned long dblk, i;
		if (chunk > n - done)
			chunk = n - done;
		dblk = bmap((unsigned int)vp->v_cap, &ino, fbn, 1, &dirty);
		if (dblk == 0)
			return (VERR_ENOSPC);	/* out of free blocks */
		if (bdev_strategy(dblk, blk, 0) != 0)	/* read-modify-write */
			return (-1);
		for (i = 0; i < chunk; i++)
			blk[boff + i] = (unsigned char)ubuf[done + i];
		if (bdev_strategy(dblk, blk, 1) != 0)	/* write-back */
			return (-1);
		done += chunk;
	}
	if (end > vp->v_len) {
		vp->v_len = end;
		ino.i_size = end;
		dirty = 1;
	}
	if (dirty)				/* persist new block ptrs + size */
		(void) blockfs_iwrite((unsigned int)vp->v_cap, &ino);
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

	if (!blockfs_fmt_done) {
		/*
		 * R-P52: on a REAL virtio-blk disk the superblock may already be
		 * there from a PRIOR qemu run -- read it first, and mkfs only if
		 * the magic is absent (a fresh image).  This is what makes a file
		 * survive a FULL qemu restart: boot 2 finds the existing fs and
		 * does NOT wipe it.  (The RAM disk always mkfs's, since its
		 * contents vanish at qemu exit anyway.)  R-P54: an OLD-layout image
		 * (s_version != 2) is also re-mkfs'd -- the R-P53 single-block
		 * layout has no bitmap, so balloc would read garbage.
		 */
		if (bdev_strategy(BLOCKFS_SB_BLK, blk, 0) != 0 ||
		    sb->s_magic != BLOCKFS_MAGIC || sb->s_version != 3) {
			if (blockfs_mkfs() != 0)
				return (-1);
		}
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
	extern int bsync(void);
	(void) bsync();			/* R-P54: flush dirty buffers to disk */
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
	unsigned long inum = 0;

	if (!blockfs_mounted)
		return (VERR_ENOENT);
	if (blockfs_create(name, &inum) < 0)
		return (VERR_ENOMEM);
	cvn.v_op = &blockfs_vnodeops;
	cvn.v_type = VT_RAMFS;
	cvn.v_len = 0;
	cvn.v_cap = inum;		/* the inode index (bmap resolves blocks) */
	cvn.v_name = name;		/* so vop_write can update i_size */
	cvn.v_used = 1;
	*out = &cvn;
	return (0);
}

/*
 * vfs_blockfs_unlink -- R-P54: remove leaf `name`, freeing its data blocks
 * (direct + indirect) back to the free-block bitmap via blockfs_itrunc, then
 * clearing the inode.  Proves f_bfree RECOVERS on delete (xv6 iput at
 * nlink==0 -> itrunc -> bfree).  Returns 0 or -ENOENT.
 */
int
vfs_blockfs_unlink(const char *name)
{
	struct blockfs_inode ino;
	unsigned int k;

	if (!blockfs_mounted)
		return (VERR_ENOENT);
	for (k = 0; k < BLOCKFS_NINODE; k++) {
		if (blockfs_iread(k, &ino) != 0)
			return (VERR_ENOENT);
		if (ino.i_magic == BLOCKFS_MAGIC && name_eq(ino.i_name, name)) {
			blockfs_itrunc(&ino);	/* free data + indirect blocks */
			ino.i_magic = 0;	/* free the inode slot */
			ino.i_name[0] = 0;
			return (blockfs_iwrite(k, &ino));
		}
	}
	return (VERR_ENOENT);
}

/*
 * vfs_blockfs_open -- resolve leaf `name` on the mounted blockfs to a transient
 * vnode whose vop_read/vop_write cross bdev_strategy.  Returns 0 or -errno.
 */
int
vfs_blockfs_open(const char *name, vnode_t **out)
{
	static vnode_t bvn;		/* one outstanding blockfs open */
	static char bvn_name[64];	/* R-P40: own the name (caller's may be transient) */
	unsigned long inum = 0, size = 0;
	int k;

	if (!blockfs_mounted)
		return (VERR_ENOENT);
	if (blockfs_find(name, &inum, &size) < 0)
		return (VERR_ENOENT);
	for (k = 0; name[k] != 0 && k < (int)sizeof (bvn_name) - 1; k++)
		bvn_name[k] = name[k];
	bvn_name[k] = 0;
	bvn.v_op = &blockfs_vnodeops;
	bvn.v_type = VT_RAMFS;		/* a plain file for fd purposes */
	bvn.v_len = size;
	bvn.v_cap = inum;		/* stash the inode index (bmap resolves blocks) */
	bvn.v_name = bvn_name;		/* so vop_write can update i_size */
	bvn.v_used = 1;
	*out = &bvn;
	return (0);
}

/* R-P41.3: a blockfs directory vnode -- a DISTINCT ops vector so vfs_readdir
   routes to blockfs_readdir (the on-disk child enumeration, read through
   bdev_strategy) instead of the ramfs/tmpfs scans. */
static const vnodeops_t blockfs_dir_vnodeops = {
	dir_vop_read, dir_vop_write, dir_vop_getattr
};
static char blockfs_dir_name[64];	/* the outstanding blockfs dir path */

/*
 * vfs_blockfs_mkdir -- R-P41.3: make an on-disk directory inode named `name`
 * (relative to the blockfs root), persisted through bdev_strategy.
 */
int
vfs_blockfs_mkdir(const char *name)
{
	if (!blockfs_mounted)
		return (VERR_ENOENT);
	if (blockfs_mkdir(name) < 0)
		return (VERR_ENOSPC);
	return (0);
}

/* R-P41.3: is `name` (relative) a blockfs directory? */
int
vfs_blockfs_isdir(const char *name)
{
	return (blockfs_mounted ? blockfs_isdir(name) : 0);
}

/*
 * R-P50: blockfs getattr -- fetch the on-disk inode's real size + type for
 * a relative name ("" == the blockfs root directory).  This is the per-entry
 * VOP_GETATTR the userland stat path was missing, so `ls -l /blk` / `stat`
 * report real mode/size instead of `?`.  *type is the kernel vtype code the
 * libc struct-stat cook maps to st_mode (0 regular file, 1 directory).  Reads
 * the inode table THROUGH bdev_strategy.  Returns 0 on hit, -ENOENT on miss.
 */
int
vfs_blockfs_getattr(const char *name, unsigned long *size, unsigned long *type)
{
	unsigned long dblk = 0, sz = 0;

	if (!blockfs_mounted)
		return (VERR_ENOENT);
	/* the blockfs root (bare /blk) and any dir inode: size 0, type dir. */
	if ((name != 0 && name[0] == 0) || blockfs_isdir(name)) {
		if (size != 0) *size = 0;
		if (type != 0) *type = 1;
		return (0);
	}
	if (blockfs_find(name, &dblk, &sz) < 0)
		return (VERR_ENOENT);
	if (size != 0) *size = sz;
	if (type != 0) *type = 0;		/* regular file */
	return (0);
}

/*
 * vfs_blockfs_opendir -- resolve directory `name` (relative to the blockfs
 * root) to a transient dir vnode whose getdents crosses blockfs_readdir.
 */
int
vfs_blockfs_opendir(const char *name, vnode_t **out)
{
	static vnode_t dvn;
	int k;
	if (!blockfs_mounted)
		return (VERR_ENOENT);
	if (!blockfs_isdir(name))
		return (VERR_ENOENT);
	for (k = 0; name[k] != 0 && k < (int)sizeof (blockfs_dir_name) - 1; k++)
		blockfs_dir_name[k] = name[k];
	blockfs_dir_name[k] = 0;
	dvn.v_op = &blockfs_dir_vnodeops;
	dvn.v_type = VT_DIR;
	dvn.v_len = 0;
	dvn.v_cap = BLOCKFS_DIR_TAG;	/* tag so vfs_readdir routes here */
	dvn.v_name = blockfs_dir_name;
	dvn.v_used = 1;
	*out = &dvn;
	return (0);
}

/* R-P41.3: enumerate a blockfs directory's children (called by vfs_readdir). */
int
vfs_blockfs_readdir(const char *dir, unsigned long index, char *out,
    unsigned long osz)
{
	return (blockfs_mounted ? blockfs_readdir(dir, index, out, osz) : 0);
}

/*
 * ==== R-P55: the ROOT-PIVOT support -- whole-file read/write on the disk ===
 *
 * vfs_blockfs_writefile -- create leaf `name` on the mounted blockfs and write
 * `len` bytes of `data` to it (multi-block, via blockfs_vop_write/bmap), then
 * update its recorded size.  Used by the boot-time mkfs-populate step that
 * copies the ramfs /bin + /sbin + /etc onto the disk so init/sh/coreutils can
 * exec OFF THE DISK.  CRIB: xv6 mkfs.c iappend (write a host file's bytes into
 * the fs image); here the kernel does it at boot from the ramfs archive.
 * Returns bytes written or -errno.
 */
long
vfs_blockfs_writefile(const char *name, const unsigned char *data,
    unsigned long len)
{
	vnode_t *vp = 0;
	long r;

	if (!blockfs_mounted)
		return (VERR_ENOENT);
	if (vfs_blockfs_create(name, &vp) != 0)
		return (VERR_ENOMEM);
	r = blockfs_vop_write(vp, (const char *)data, 0, len);
	if (r == (long)len)
		(void) blockfs_set_size(name, len);
	return (r);
}

/*
 * vfs_blockfs_readfile -- read the WHOLE file `name` off the mounted blockfs
 * into `buf` (up to `max` bytes).  This is what proc_execv calls to pull an ELF
 * image off the DISK into a contiguous buffer so do_exec can load it -- the
 * exec-off-the-disk path of the root-pivot.  Returns bytes read or -errno.
 */
long
vfs_blockfs_readfile(const char *name, unsigned char *buf, unsigned long max)
{
	vnode_t *vp = 0;
	unsigned long size = 0, inum = 0;
	long r;

	if (!blockfs_mounted)
		return (VERR_ENOENT);
	if (blockfs_find(name, &inum, &size) < 0)
		return (VERR_ENOENT);
	if (size > max)
		return (VERR_ENOMEM);
	if (vfs_blockfs_open(name, &vp) != 0)
		return (VERR_ENOENT);
	r = blockfs_vop_read(vp, (char *)buf, 0, size);
	return (r);
}

/* R-P55: does leaf `name` exist as a regular file on the mounted blockfs? */
int
vfs_blockfs_exists(const char *name)
{
	unsigned long inum = 0, size = 0;
	if (!blockfs_mounted)
		return (0);
	return (blockfs_find(name, &inum, &size) >= 0);
}

/*
 * ==== R-P55: the root device flag (VFS_MOUNTROOT / the root-pivot) =========
 *
 * rootfs_on_disk marks that the disk-backed blockfs has been pivoted to be the
 * REAL root: an exec of /sbin/init, /bin/sh, /bin/<util> resolves its ELF OFF
 * THE DISK (blockfs) rather than the ramfs.  vfs_rootfs_pivot() flips it after
 * the mkfs-populate step; proc_execv consults vfs_rootfs_on_disk().  This is
 * the illumos vfs_mountroot() step reduced to a flag + a prefix reroute.
 */
static int rootfs_on_disk;

void
vfs_rootfs_pivot(void)
{
	rootfs_on_disk = 1;
}

int
vfs_rootfs_on_disk(void)
{
	return (rootfs_on_disk);
}

/*
 * ==== R-P53: statvfs(2) + a mount-table dump ==============================
 *
 * vfs_statvfs -- df(1)-style capacity for the blockfs mount.  When a real
 * virtio-blk disk backs /blk, f_blocks is the disks REAL 512B-sector count

/*
 * ==== R-P53: statvfs(2) + a mount-table dump ==============================
 *
 * vfs_statvfs -- df(1)-style capacity for the blockfs mount.  When a real
 * virtio-blk disk backs /blk, f_blocks is the disk's REAL 512B-sector count
 * (virtio_blk_capacity(), 8192 for the 4 MiB image); otherwise it is the RAM
 * disk's BDEV_NBLK.  f_bfree/f_bavail subtract the blocks the on-disk inodes
 * currently occupy (superblock + inode table + one data block per used inode).
 * f_bsize is the block size.  Mirrors illumos VFS_STATVFS / statvfs(9E).
 */
int
vfs_statvfs(const char *path, unsigned long *bsize, unsigned long *blocks,
    unsigned long *bfree)
{
	extern int virtio_blk_present(void);
	extern unsigned long virtio_blk_capacity(void);
	unsigned long total, free;

	(void) path;
	/* R-P56: df reports the PARTITION capacity (the root fs lives in the
	   partition), i.e. the raw disk minus the partition base LBA -- not the
	   whole physical disk.  With no partition table blockfs_part_base==0 and
	   this is the raw capacity, exactly as before. */
	extern unsigned long blockfs_part_base;
	total = virtio_blk_present() ?
	    (virtio_blk_capacity() - blockfs_part_base) : (unsigned long)BDEV_NBLK;
	if (total == 0)
		total = (unsigned long)BDEV_NBLK;

	/* R-P54: f_bfree is the TRUE free-block count from the bitmap (balloc/
	   bfree), clamped to the device capacity. */
	free = blockfs_bfree_count();
	if (free > total)
		free = total;

	if (bsize != 0)  *bsize  = BDEV_BSIZE;
	if (blocks != 0) *blocks = total;
	if (bfree != 0)  *bfree  = free;
	return (0);
}

/*
 * vfs_mount_dump -- mount(1M)/mnttab-style listing: one line per active mount,
 * "PATH on FSTYPE" (blockfs annotated as the virtio-blk disk or the RAM disk).
 * out is filled NUL-terminated; returns the number of mount entries printed.
 */
int
vfs_mount_dump(char *out, unsigned long osz)
{
	extern int virtio_blk_present(void);
	unsigned long pos = 0;
	int i, n = 0;
	static const char *tname[] = { "ramfs", "tmpfs", "dir", "blockfs" };

	for (i = 0; i < NMOUNT; i++) {
		const char *ty, *bk;
		int t;
		if (!mount_tab[i].m_used)
			continue;
		t = (int)mount_tab[i].m_fstype;
		ty = (t >= 0 && t <= 3) ? tname[t] : "?";
		bk = "";
		if (mount_tab[i].m_fstype == VT_BLOCKFS)
			bk = virtio_blk_present() ?
			    " (virtio-blk disk)" : " (RAM disk)";
		{
			const char *p;
			for (p = mount_tab[i].m_path; *p && pos + 1 < osz; p++)
				out[pos++] = *p;
			{ const char *s = " on "; while (*s && pos+1<osz) out[pos++]=*s++; }
			for (p = ty; *p && pos + 1 < osz; p++) out[pos++] = *p;
			for (p = bk; *p && pos + 1 < osz; p++) out[pos++] = *p;
			if (pos + 1 < osz) out[pos++] = '\n';
		}
		n++;
	}
	if (pos < osz) out[pos] = 0;
	return (n);
}

/*
 * ==== R-P53: a small buffer cache over bdev_strategy =====================
 *
 * The classic Unix buffer cache (illumos bio.c getblk/bread/bwrite/bdwrite;
 * xv6 bio.c bget/bread/bwrite): a fixed pool of buffers keyed by block number.
 * bread returns a cached buffer on a hit (NO second disk op) and reads through
 * bdev_strategy on a miss; bwrite writes through immediately; bdwrite marks the
 * buffer dirty for a deferred write.  This sits ABOVE bdev_strategy (which now
 * routes to the virtio-blk disk), so a re-read of a hot block is served from
 * RAM -- real driver maturity over the R-P52 raw strategy path.
 */
#define	NBUF	16
struct buf {
	unsigned long	b_blkno;	/* block number */
	int		b_valid;	/* holds a cached block */
	int		b_dirty;	/* bdwrite: needs a flush */
	unsigned long	b_lru;		/* recency for eviction */
	unsigned char	b_data[BDEV_BSIZE];
};
static struct buf buf_pool[NBUF];
static unsigned long buf_clock;		/* LRU tick */
static unsigned long buf_hits;		/* cache hits (re-read served from RAM) */
static unsigned long buf_misses;	/* misses (went to the disk) */

/* getblk: find (or evict + claim) a buffer for blkno.  Returns the buf. */
static struct buf *
getblk(unsigned long blkno)
{
	int i, victim = 0;
	unsigned long oldest = ~0UL;
	for (i = 0; i < NBUF; i++)
		if (buf_pool[i].b_valid && buf_pool[i].b_blkno == blkno) {
			buf_pool[i].b_lru = ++buf_clock;
			return (&buf_pool[i]);		/* HIT */
		}
	/* miss: pick the LRU (prefer an empty slot). */
	for (i = 0; i < NBUF; i++) {
		if (!buf_pool[i].b_valid) { victim = i; break; }
		if (buf_pool[i].b_lru < oldest) { oldest = buf_pool[i].b_lru; victim = i; }
	}
	/* flush a dirty victim before reuse. */
	if (buf_pool[victim].b_valid && buf_pool[victim].b_dirty)
		(void) bdev_strategy(buf_pool[victim].b_blkno,
		    buf_pool[victim].b_data, 1);
	buf_pool[victim].b_blkno = blkno;
	buf_pool[victim].b_valid = 0;
	buf_pool[victim].b_dirty = 0;
	buf_pool[victim].b_lru = ++buf_clock;
	return (&buf_pool[victim]);
}

/* bread: return block blkno in *out (BDEV_BSIZE bytes); cache hit avoids disk. */
int
bread(unsigned long blkno, unsigned char *out)
{
	struct buf *b = getblk(blkno);
	unsigned long i;
	if (b->b_valid) {
		buf_hits++;
	} else {
		if (bdev_strategy(blkno, b->b_data, 0) != 0)
			return (-1);
		b->b_valid = 1;
		buf_misses++;
	}
	for (i = 0; i < BDEV_BSIZE; i++)
		out[i] = b->b_data[i];
	return (0);
}

/* bwrite: write-through -- update the cache AND the disk now. */
int
bwrite(unsigned long blkno, const unsigned char *in)
{
	struct buf *b = getblk(blkno);
	unsigned long i;
	for (i = 0; i < BDEV_BSIZE; i++)
		b->b_data[i] = in[i];
	b->b_valid = 1;
	b->b_dirty = 0;
	return (bdev_strategy(blkno, b->b_data, 1));
}

/* bdwrite: delayed write -- update the cache, mark dirty, flush at eviction. */
int
bdwrite(unsigned long blkno, const unsigned char *in)
{
	struct buf *b = getblk(blkno);
	unsigned long i;
	for (i = 0; i < BDEV_BSIZE; i++)
		b->b_data[i] = in[i];
	b->b_valid = 1;
	b->b_dirty = 1;
	return (0);
}

/*
 * bsync -- R-P54 DURABILITY: flush every dirty buffer to the disk via
 * bdev_strategy, then clear the dirty flag (illumos bflush / fsflush; xv6 has
 * no separate delayed-write cache, but this is the sync(2)/unmount flush).
 * Returns the number of buffers written back.
 */
int
bsync(void)
{
	int i, n = 0;
	for (i = 0; i < NBUF; i++)
		if (buf_pool[i].b_valid && buf_pool[i].b_dirty) {
			(void) bdev_strategy(buf_pool[i].b_blkno,
			    buf_pool[i].b_data, 1);
			buf_pool[i].b_dirty = 0;
			n++;
		}
	return (n);
}

unsigned long bcache_hits(void)   { return (buf_hits); }
unsigned long bcache_misses(void) { return (buf_misses); }

/* R-P54: an exported, cache-BYPASSING block transfer (for the sync proof to
   re-read a block straight off the disk).  rw==0 read, rw==1 write. */
int
bdev_strategy_ext(unsigned long blkno, unsigned char *buf, int rw)
{
	return (bdev_strategy(blkno, buf, rw));
}
