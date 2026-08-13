/*
 * drm_core.c - illumos DRM core: char-device registration + ioctl dispatch.
 *
 * This is the C1a keystone: the smallest load-bearing DRM piece compiling
 * against illumos kernel headers. It maps NetBSD's drm2 glue onto illumos DDI:
 *
 *   NetBSD sys/external/bsd/drm2/drm/drm_cdevsw.c   -> this file
 *     struct cdevsw drm_cdevsw {.d_open,.d_mmap}    -> struct cb_ops {cb_open,cb_devmap}
 *     struct fileops drm_fileops {.fo_ioctl,...}    -> cb_ops {cb_ioctl,cb_close,cb_chpoll}
 *     drm_ioctl_shim() dispatch                     -> drm_ioctl() switch below
 *     /dev/dri/card* + render* (NetBSD cdevsw+devsw) -> ddi_create_minor_node()
 *   NetBSD drm_module.c (modcmd MODULE(...))        -> _init/_fini/_info + modlinkage
 *   NetBSD dev->driver->{name,date,desc}            -> drm_virtio_driver below
 *
 * First target driver identity = virtio-gpu (QEMU -device virtio-gpu; no real
 * GPU). The version ioctl reports "virtio_gpu" so libdrm probes match, exactly
 * as they would against a Linux/NetBSD virtio-gpu drm node.
 *
 * COMPILE-ONLY milestone: this registers the node + answers VERSION + GEM
 * create/map/destroy/close as functional stubs. It is not wired to real
 * virtio-gpu hardware and does not modeset (that is C1b).
 */

#include <sys/types.h>
#include <sys/modctl.h>
#include <sys/conf.h>
#include <sys/devops.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <sys/errno.h>
#include <sys/open.h>
#include <sys/cred.h>
#include <sys/ksynch.h>
#include <sys/cmn_err.h>

#include "uapi/drm/drm.h"
#include "drm_internal.h"

#define	DRM_DRIVER_NAME	"drm"

/*
 * Minor-node layout. Linux/NetBSD split the DRM minor space into card nodes
 * (primary, modeset-capable) and render nodes (renderD*, compute/GEM-only).
 * We give one of each per instance; the minor number encodes which.
 */
#define	DRM_MINOR_CARD		0	/* /dev/dri/card0    */
#define	DRM_MINOR_RENDER	128	/* /dev/dri/renderD128 */

/* per-instance soft state */
static void *drm_state;

/* virtio-gpu-shaped driver identity reported by DRM_IOCTL_VERSION. */
static const struct drm_driver drm_virtio_driver = {
	.name = "virtio_gpu",
	.date = "0",
	.desc = "virtio GPU (illumos DRM core stub)",
	.major = 0,
	.minor = 1,
	.patchlevel = 0,
};

/*
 * drm_copy_field - DRM_IOCTL_VERSION string-field contract, reproduced from
 * NetBSD/Linux drm_ioctl.c drm_copy_field(): report the true length in *len,
 * copy min(len, buflen) bytes to the user buffer if present.
 */
static int
drm_copy_field(char *ubuf, drm_kernel_size_t *ubuflen, const char *value,
    int mode)
{
	size_t len = strlen(value);
	size_t n = (len > *ubuflen) ? *ubuflen : len;

	*ubuflen = len;
	if (n != 0 && ubuf != NULL) {
		if (ddi_copyout((void *)value, ubuf, n, mode) != 0)
			return (EFAULT);
	}
	return (0);
}

/* DRM_IOCTL_VERSION - mirrors NetBSD/Linux drm_version(). */
int
drm_version_ioctl(struct drm_device *dev, intptr_t arg, int mode)
{
	struct drm_version v;
	const struct drm_driver *drv = dev->driver;
	int err;

	if (ddi_copyin((void *)arg, &v, sizeof (v), mode) != 0)
		return (EFAULT);

	v.version_major = drv->major;
	v.version_minor = drv->minor;
	v.version_patchlevel = drv->patchlevel;
	err = drm_copy_field(v.name, &v.name_len, drv->name, mode);
	if (err == 0)
		err = drm_copy_field(v.date, &v.date_len, drv->date, mode);
	if (err == 0)
		err = drm_copy_field(v.desc, &v.desc_len, drv->desc, mode);
	if (err != 0)
		return (err);

	if (ddi_copyout(&v, (void *)arg, sizeof (v), mode) != 0)
		return (EFAULT);
	return (0);
}

/* ---- cb_ops entry points ---- */

static int
drm_open(dev_t *devp, int flag, int otyp, cred_t *credp)
{
	minor_t m = getminor(*devp);
	struct drm_device *dev;

	if (otyp != OTYP_CHR)
		return (EINVAL);
	/* instance is folded into the minor via the ddi minor node id */
	dev = ddi_get_soft_state(drm_state, 0);
	if (dev == NULL)
		return (ENXIO);
	(void) m; (void) flag; (void) credp;
	return (0);
}

static int
drm_close(dev_t dev, int flag, int otyp, cred_t *credp)
{
	(void) dev; (void) flag; (void) otyp; (void) credp;
	return (0);
}

/*
 * drm_ioctl - the DRM ioctl dispatch. NetBSD routes fo_ioctl -> drm_ioctl_shim
 * -> drm_ioctl(); illumos routes cb_ioctl here. We switch on the DRM command
 * number and delegate to the core/GEM handlers. Handlers return positive
 * illumos errnos (the boundary; the cribbed Linux core uses -errno internally).
 */
static int
drm_ioctl(dev_t d, int cmd, intptr_t arg, int mode, cred_t *credp, int *rvalp)
{
	struct drm_device *dev = ddi_get_soft_state(drm_state, 0);
	int err;

	(void) d; (void) credp;
	if (dev == NULL)
		return (ENXIO);
	*rvalp = 0;

	switch ((unsigned)cmd) {
	case DRM_IOCTL_VERSION:
		err = drm_version_ioctl(dev, arg, mode);
		break;
	case DRM_IOCTL_GEM_CLOSE:
		err = drm_gem_close_ioctl(dev, arg, mode);
		break;
	case DRM_IOCTL_MODE_CREATE_DUMB:
		err = drm_gem_create_dumb(dev, arg, mode);
		break;
	case DRM_IOCTL_MODE_MAP_DUMB:
		err = drm_gem_map_dumb(dev, arg, mode);
		break;
	case DRM_IOCTL_MODE_DESTROY_DUMB:
		err = drm_gem_destroy_dumb(dev, arg, mode);
		break;
	default:
		err = ENOTTY;	/* unimplemented DRM ioctl */
		break;
	}
	return (err);
}

static struct cb_ops drm_cb_ops = {
	.cb_open = drm_open,
	.cb_close = drm_close,
	.cb_strategy = nodev,
	.cb_print = nodev,
	.cb_dump = nodev,
	.cb_read = nodev,
	.cb_write = nodev,
	.cb_ioctl = drm_ioctl,
	.cb_devmap = nodev,	/* C1b: GEM mmap via devmap(9E) */
	.cb_mmap = nodev,
	.cb_segmap = nodev,
	.cb_chpoll = nochpoll,	/* C1b: DRM event queue -> pollwakeup */
	.cb_prop_op = ddi_prop_op,
	.cb_str = NULL,
	.cb_flag = D_NEW | D_MP | D_DEVMAP,
	.cb_rev = CB_REV,
	.cb_aread = nodev,
	.cb_awrite = nodev,
};

/* ---- dev_ops entry points ---- */

static int
drm_attach(dev_info_t *dip, ddi_attach_cmd_t cmd)
{
	struct drm_device *dev;
	int inst = ddi_get_instance(dip);

	if (cmd != DDI_ATTACH)
		return (DDI_FAILURE);
	if (ddi_soft_state_zalloc(drm_state, inst) != DDI_SUCCESS)
		return (DDI_FAILURE);
	dev = ddi_get_soft_state(drm_state, inst);
	dev->dip = dip;
	dev->driver = &drm_virtio_driver;
	dev->next_mmap_offset = 0;
	mutex_init(&dev->lock, NULL, MUTEX_DRIVER, NULL);
	idr_init(&dev->gem_handles);

	/*
	 * Create the DRI minor nodes. Linux/NetBSD expose /dev/dri/card0 and
	 * /dev/dri/renderD128; illumos maps these via ddi_create_minor_node,
	 * and a devfsadm rule (shipped separately, see DESIGN.md) links them
	 * under /dev/dri/. The node names here match the DRM convention.
	 */
	if (ddi_create_minor_node(dip, "card0", S_IFCHR,
	    DRM_MINOR_CARD, DDI_NT_DISPLAY, 0) != DDI_SUCCESS)
		goto fail;
	if (ddi_create_minor_node(dip, "renderD128", S_IFCHR,
	    DRM_MINOR_RENDER, DDI_NT_DISPLAY, 0) != DDI_SUCCESS)
		goto fail;

	ddi_report_dev(dip);
	return (DDI_SUCCESS);

fail:
	ddi_remove_minor_node(dip, NULL);
	idr_destroy(&dev->gem_handles);
	mutex_destroy(&dev->lock);
	ddi_soft_state_free(drm_state, inst);
	return (DDI_FAILURE);
}

static int
drm_detach(dev_info_t *dip, ddi_detach_cmd_t cmd)
{
	int inst = ddi_get_instance(dip);
	struct drm_device *dev;

	if (cmd != DDI_DETACH)
		return (DDI_FAILURE);
	dev = ddi_get_soft_state(drm_state, inst);
	if (dev != NULL) {
		ddi_remove_minor_node(dip, NULL);
		idr_destroy(&dev->gem_handles);
		mutex_destroy(&dev->lock);
		ddi_soft_state_free(drm_state, inst);
	}
	return (DDI_SUCCESS);
}

static int
drm_getinfo(dev_info_t *dip, ddi_info_cmd_t cmd, void *arg, void **result)
{
	struct drm_device *dev;

	(void) dip;
	switch (cmd) {
	case DDI_INFO_DEVT2DEVINFO:
		dev = ddi_get_soft_state(drm_state, 0);
		if (dev == NULL)
			return (DDI_FAILURE);
		*result = dev->dip;
		return (DDI_SUCCESS);
	case DDI_INFO_DEVT2INSTANCE:
		*result = (void *)0;
		return (DDI_SUCCESS);
	default:
		return (DDI_FAILURE);
	}
}

static struct dev_ops drm_dev_ops = {
	.devo_rev = DEVO_REV,
	.devo_refcnt = 0,
	.devo_getinfo = drm_getinfo,
	.devo_identify = nulldev,
	.devo_probe = nulldev,
	.devo_attach = drm_attach,
	.devo_detach = drm_detach,
	.devo_reset = nodev,
	.devo_cb_ops = &drm_cb_ops,
	.devo_bus_ops = NULL,
	.devo_power = NULL,
	.devo_quiesce = ddi_quiesce_not_needed,
};

/* ---- module linkage ---- */

static struct modldrv drm_modldrv = {
	&mod_driverops,
	"illumos DRM core + GEM stub (C1a, virtio-gpu target)",
	&drm_dev_ops,
};

static struct modlinkage drm_modlinkage = {
	MODREV_1,
	{ &drm_modldrv, NULL }
};

int
_init(void)
{
	int err;

	if ((err = ddi_soft_state_init(&drm_state,
	    sizeof (struct drm_device), 1)) != 0)
		return (err);
	if ((err = mod_install(&drm_modlinkage)) != 0)
		ddi_soft_state_fini(&drm_state);
	return (err);
}

int
_fini(void)
{
	int err;

	if ((err = mod_remove(&drm_modlinkage)) != 0)
		return (err);
	ddi_soft_state_fini(&drm_state);
	return (0);
}

int
_info(struct modinfo *mi)
{
	return (mod_info(&drm_modlinkage, mi));
}
