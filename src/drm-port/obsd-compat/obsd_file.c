/*
 * obsd_file.c -- OpenBSD struct file (dma-buf, sync_file) as real illumos fds.
 *
 * drm_linux.c builds a dma-buf as fnew() + fdalloc() + fdinsert() and finds
 * one again with fd_getfile(); OpenBSD's fileops then do close/seek/stat.
 * Here each OpenBSD file owns a slot; the fd is an illumos file_t over a spec
 * vnode of the i915 node at minor slot<<16 | inst<<8 | I915_IL_DMABUF
 * (i915_drmioc.h). That is the falloc + spec-vnode design of
 * src/drm-port/src/drm_prime.c (C1c): the fd passes over SCM_RIGHTS like any
 * fd, mmap goes to i915's devmap, the last close to i915's close(9E), and
 * lseek(SEEK_END) reads the "Size" property (specfs spec_size).
 * References: f_count counts OpenBSD holders (FREF/FRELE). As in OpenBSD,
 * fdinsert takes no reference of its own: the fd takes over the caller's
 * (fnew's for a new file, get_dma_buf's for another fd of one dma-buf), and
 * obsd_file_opens counts them. specfs calls close(9E) once, at the last
 * close of the slot's dev_t with no mapping left, and that drops all of
 * them (obsd_file_lastclose). An FREF here leaked every exported sync_file
 * and dma-buf: the 4095 slots filled and cosmic-comp lost its outputs.
 */
#include <obsd_prelude.h>
#include <sys/id_space.h>
#include <sys/fs/snode.h>
#include "obsd_kern.h"

#define	OBSD_FILE_SLOTS	4096
#define	OBSD_DMABUF_KIND	192u	/* i915_drmioc.h I915_IL_DMABUF */

static kmutex_t obsd_file_lock;
static struct file *obsd_file_slot[OBSD_FILE_SLOTS];
static uint_t obsd_file_opens[OBSD_FILE_SLOTS];	/* fdinsert refs */
static id_space_t *obsd_file_ids;
static dev_info_t *obsd_file_dip;
static major_t obsd_file_major;
static int obsd_file_inst;
static char obsd_file_path[MAXPATHLEN];	/* the i915 node's /devices path */

/* i915 attach: where dma-buf minors live. Called once, before any export. */
void
obsd_dmabuf_register(dev_info_t *dip, major_t maj, int inst)
{
	mutex_init(&obsd_file_lock, NULL, MUTEX_DRIVER, NULL);
	obsd_file_ids = id_space_create("obsd_file", 1, OBSD_FILE_SLOTS);
	obsd_file_dip = dip;
	(void) ddi_pathname(dip, obsd_file_path);
	obsd_file_major = maj;
	obsd_file_inst = inst;
}

static uint32_t
obsd_file_slotof(struct file *fp)
{
	return ((uint32_t)(uintptr_t)fp->f_iflags);
}

struct file *
fnew(struct proc *p)
{
	struct file *fp;
	id_t id;

	(void) p;
	if (obsd_file_ids == NULL ||
	    (id = id_alloc_nosleep(obsd_file_ids)) == -1)
		return (NULL);
	fp = kmem_zalloc(sizeof (*fp), KM_SLEEP);
	mtx_init(&fp->f_mtx, IPL_NONE);
	fp->f_count = 1;
	fp->f_iflags = (u_int)id;	/* the slot (OpenBSD's FIF_* unused) */
	mutex_enter(&obsd_file_lock);
	obsd_file_slot[id] = fp;
	mutex_exit(&obsd_file_lock);
	return (fp);
}

/* The last reference runs the OpenBSD close (dmabuf_close: GEM ref). */
int
obsd_frele(struct file *fp, struct proc *p)
{
	uint32_t slot = obsd_file_slotof(fp);
	int err = 0;

	/* under the lock, so obsd_file_get never revives a dying file */
	mutex_enter(&obsd_file_lock);
	if (atomic_dec_uint_nv(&fp->f_count) != 0) {
		mutex_exit(&obsd_file_lock);
		return (0);
	}
	obsd_file_slot[slot] = NULL;
	mutex_exit(&obsd_file_lock);
	if (fp->f_ops != NULL && fp->f_ops->fo_close != NULL)
		err = fp->f_ops->fo_close(fp, p);
	id_free(obsd_file_ids, (id_t)slot);
	mutex_destroy(&fp->f_mtx);
	kmem_free(fp, sizeof (*fp));
	return (err);
}

/* slot -> file with a reference (FRELE it), or NULL. */
struct file *
obsd_file_get(uint32_t slot)
{
	struct file *fp = NULL;

	if (slot == 0 || slot >= OBSD_FILE_SLOTS)
		return (NULL);
	mutex_enter(&obsd_file_lock);
	if ((fp = obsd_file_slot[slot]) != NULL)
		FREF(fp);
	mutex_exit(&obsd_file_lock);
	return (fp);
}

/*
 * The fd: fdalloc reserves the number (ufalloc); fdinsert, OpenBSD's
 * publish step, opens the slot's vnode, wraps it in a file_t and setf()s it.
 */
int
fdalloc(struct proc *p, int want, int *fdp)
{
	(void) p; (void) want;
	if ((*fdp = ufalloc(0)) == -1)
		return (EMFILE);
	return (0);
}

/* fdalloc'ed but never inserted (an error path): give the number back. */
void
fdremove(struct filedesc *fdp, int fd)
{
	(void) fdp;
	setf(fd, NULL);
}

void
fdinsert(struct filedesc *fdp, int fd, int flags, struct file *fp)
{
	uint32_t slot = obsd_file_slotof(fp);
	vnode_t *vp;
	file_t *ifp;
	char path[128];		/* "/devices/pci@0,0/display@2:dmabufN" */
	int err;

	(void) fdp;
	vp = makespecvp(makedevice(obsd_file_major,
	    (slot << 16) | ((uint32_t)obsd_file_inst << 8) | OBSD_DMABUF_KIND),
	    VCHR);
	spec_assoc_vp_with_devi(vp, obsd_file_dip);
	/* specfind (segdev_create, mmap) skips shadow snodes with no v_path:
	 * a NULL there was the #pf of vmdump.1. Name it like a /devices node. */
	(void) snprintf(path, sizeof (path), "/devices%s:dmabuf%u",
	    obsd_file_path, slot);
	vn_setpath_str(vp, path, strlen(path));
	if ((err = VOP_OPEN(&vp, FREAD | FWRITE, CRED(), NULL)) != 0 ||
	    (err = falloc(vp, FREAD | FWRITE, &ifp, NULL)) != 0) {
		/* shortcut: the OpenBSD caller cannot see this failure;
		 * the fd number is released and the export stays unreachable. */
		cmn_err(CE_WARN, "!obsd_file: slot %u open failed: %d",
		    slot, err);
		VN_RELE(vp);
		(void) obsd_frele(fp, curproc);	/* the fd would have owned it */
		setf(fd, NULL);
		return;
	}
	/* counted only once open: a close(9E) of this slot still running
	 * (spec_open waited for it) must not drain this fd's reference */
	mutex_enter(&obsd_file_lock);
	obsd_file_opens[slot]++;	/* the caller's reference, now the fd's */
	mutex_exit(&obsd_file_lock);
	mutex_exit(&ifp->f_tlock);
	setf(fd, ifp);
	if (flags & UF_EXCLOSE)
		f_setfd_or(fd, FD_CLOEXEC);
}

/* fd -> the OpenBSD file behind it, referenced; NULL if not one of ours. */
struct file *
fd_getfile(struct filedesc *fdp, int fd)
{
	struct file *fp = NULL;
	file_t *ifp;
	vnode_t *vp;
	minor_t m;

	(void) fdp;
	if ((ifp = getf(fd)) == NULL)
		return (NULL);
	vp = ifp->f_vnode;
	if (vp != NULL && vp->v_type == VCHR &&
	    getmajor(vp->v_rdev) == obsd_file_major &&
	    ((m = getminor(vp->v_rdev)) & 0xffu) == OBSD_DMABUF_KIND)
		fp = obsd_file_get(m >> 16);
	releasef(fd);
	return (fp);
}

void fdexpand(struct proc *p) { (void) p; }
void fdplock(struct filedesc *fdp) { (void) fdp; }
void fdpunlock(struct filedesc *fdp) { (void) fdp; }

/* close(9E) of a slot: every fd and mapping of it is gone. */
void
obsd_file_lastclose(uint32_t slot)
{
	struct file *fp;
	uint_t n;

	if ((fp = obsd_file_get(slot)) == NULL)
		return;
	mutex_enter(&obsd_file_lock);
	n = obsd_file_opens[slot];
	obsd_file_opens[slot] = 0;
	mutex_exit(&obsd_file_lock);
	while (n-- > 0)
		(void) obsd_frele(fp, curproc);
	(void) obsd_frele(fp, curproc);		/* obsd_file_get's */
}
