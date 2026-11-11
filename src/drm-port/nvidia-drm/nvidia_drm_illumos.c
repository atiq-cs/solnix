/*
 * SPDX-FileCopyrightText: Copyright (c) 2026 solnix contributors
 * SPDX-License-Identifier: MIT
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

/*
 * nvidia_drm_illumos.c -- the illumos module shell of nvidia-drm, in place of
 * nvidia-drm-linux.c (D2.1 of the RTX 3080 Ti track).
 *
 * nvidia_drm is a pseudo driver, like nvidia_modeset: nvidia_drm.conf makes
 * one node under /pseudo. Its attach runs nv_drm_init(), which takes NVKMS's
 * KAPI table from nvidia_modeset (nvKmsKapiGetFunctionsTable) and has NVKMS
 * enumerate the GPUs; for each one nvidia-drm calls back
 * nv_drm_sunos_dev_alloc() here, which builds the OpenBSD drm_device the way
 * OpenBSD's drm_attach() would (OpenBSD's drm has no drm_dev_alloc()), and
 * then registers it. The node then carries a card and a renderD minor per
 * GPU, ddi_display:drm, which the solnix devlink line names /dev/dri/<minor>.
 *
 * The character device entry points are i915_illumos.c's: a clone minor per
 * open, drmopen/drmclose/drmread/drmioctl of OpenBSD's drm core with the
 * OpenBSD minor (i915_drmioc.h), and the Linux ioctl encoding of solnix's
 * libdrm translated to OpenBSD's. Not here yet: mmap (devmap, D2.3), dma-buf
 * fds (D2.4); both fail with an error.
 *
 * Order and the GPU: attach touches no GPU. It makes one minor, "ctl"
 * (ddi_pseudo, root only); the NVKMS/DRM start (nv_drm_init, whose
 * enumeration opens each GPU through NVKMS: RmInitAdapter and the GSP boot on
 * a GPU that is down) runs at the first open of ctl. A boot that configures
 * the pseudo node therefore cannot start a GPU before site/solnix-nvidia,
 * which opens ctl after its guarded first probe. nvidia_modeset fails to load
 * before nvidia's RM is up (0001 patch of nvidia-oss), and this module NEEDs
 * it. A start that registers no GPU fails the open (ENXIO); a later open
 * tries again. With patches/0002 the GPU's NVKMS device is released once the
 * start is over, and taken again by each card/renderD open.
 */

#include <sys/types.h>
#include <sys/modctl.h>
#include <sys/conf.h>
#include <sys/stat.h>
#include <sys/ddidevmap.h>
#include <sys/id_space.h>
#include <sys/gfx_private.h>
#include <obsd_prelude.h>
#include "i915_drmioc.h"
#include "nvidia_drm_illumos.h"

/* nvidia-drm.c */
extern int nv_drm_init(void);
extern void nv_drm_exit(void);

/* OpenBSD's drm entry points (drm_drv.c, drm_ioctl.c). */
extern int drmopen(dev_t, int, int, struct proc *);
extern int drmclose(dev_t, int, int, struct proc *);
extern int drmread(dev_t, struct uio *, int);
extern int drmioctl(dev_t, u_long, caddr_t, int, struct proc *);

/*
 * Minor layout of i915_drmioc.h: clone << 16 | inst << 8 | kind. Here "inst"
 * is the GPU's index in nvd_gpus, not the DDI instance (there is one node).
 */
#define	NVD_MAXGPU	4
#define	NVD_CTL_MINOR	0xffu	/* kind 255, inst 0, clone 0: the ctl node */

struct nvd_gpu {
	struct drm_device	*g_drm;
	int			g_drmunit;	/* this module's drm_cd unit */
	dev_info_t		*g_gpu_dip;	/* the nvidia PCI node */
};

/*
 * The drm core linked here is private (nvidia-drm.mapfile), so its units
 * start at 0 whatever i915 has. The minor NAMES are global (/dev/dri/<name>),
 * so they count from "drm-card-base" (nvidia_drm.conf, default 1: i915 is
 * card0 and renderD128 on the X1E).
 */
static int		nvd_card_base = 1;

static dev_info_t	*nvd_dip;
static kmutex_t		nvd_lock;
static struct nvd_gpu	nvd_gpus[NVD_MAXGPU];
static int		nvd_ngpus;
static int		nvd_up;		/* started: GPUs registered, minors made */
static int		nvd_inited;	/* nv_drm_init() ran: NVKMS holds our callbacks */
static id_space_t	*nvd_clones;

/* ------------------------------------------------- drm_device for a GPU */
/*
 * Called by nvidia-drm-drv.c nv_drm_register_drm_device() from inside
 * nv_drm_init() (attach, nvd_lock held by this thread). os_device_ptr is the
 * nvidia node (kernel-illumos nvidia_modeset_interface.c). config_found_sm
 * (obsd_glue.c) runs OpenBSD's drm_attach(), which allocates the drm_device
 * and its minors and registers the unit in drm_cd; the pci_attach_args give
 * drm_attach the PCI identity it copies into dev->pdev.
 */
struct nvd_attach {
	struct obsd_pci_chipset	a_pc;
	struct obsd_bus_space	a_memt;
	struct bus_dma_tag	a_dmat;
	struct pci_attach_args	a_pa;
	struct device		a_parent;
	ddi_acc_handle_t	a_cfg;
};

extern struct drm_device *drm_attach_pci(const struct drm_driver *,
    struct pci_attach_args *, int, int, struct device *, struct drm_device *);

static int
nvd_bdf(dev_info_t *dip, int *bus, int *dev, int *fn)
{
	int *reg;
	uint_t n;

	if (ddi_prop_lookup_int_array(DDI_DEV_T_ANY, dip, DDI_PROP_DONTPASS,
	    "reg", &reg, &n) != DDI_PROP_SUCCESS || n < 5)
		return (DDI_FAILURE);
	*bus = (reg[0] >> 16) & 0xff;
	*dev = (reg[0] >> 11) & 0x1f;
	*fn = (reg[0] >> 8) & 0x7;
	ddi_prop_free(reg);
	return (DDI_SUCCESS);
}

struct drm_device *
nv_drm_sunos_dev_alloc(const struct drm_driver *driver,
    const struct NvKmsKapiGpuInfo *gpu_info)
{
	dev_info_t *gdip = nv_drm_sunos_gpu_dip(gpu_info);
	struct nvd_attach *a;
	struct drm_device *drm;
	int bus, d, fn, slot;

	/*
	 * Only nvd_start's nv_drm_init() enumerates; a later NVKMS probe
	 * callback (a GPU that appears after the start) would get no minor nodes.
	 * shortcut: one enumeration at the start, upgrade if hotplugged GPUs matter.
	 */
	if (nvd_dip == NULL || nvd_up)
		return (NULL);
	if (gdip == NULL || nvd_ngpus == NVD_MAXGPU ||
	    nvd_bdf(gdip, &bus, &d, &fn) != DDI_SUCCESS)
		return (NULL);
	slot = nvd_ngpus;
	a = kmem_zalloc(sizeof (*a), KM_SLEEP);
	if (pci_config_setup(gdip, &a->a_cfg) != DDI_SUCCESS) {
		kmem_free(a, sizeof (*a));
		return (NULL);
	}
	a->a_pc.pc_dip = gdip;
	a->a_pc.pc_cfg = a->a_cfg;
	a->a_pc.pc_self = pci_make_tag(NULL, bus, d, fn);
	a->a_memt.bs_dip = gdip;
	a->a_dmat.dt_dip = gdip;
	a->a_pa.pa_pc = &a->a_pc;
	a->a_pa.pa_memt = &a->a_memt;
	a->a_pa.pa_iot = &a->a_memt;
	a->a_pa.pa_dmat = &a->a_dmat;
	a->a_pa.pa_tag = a->a_pc.pc_self;
	a->a_pa.pa_bus = bus;
	a->a_pa.pa_device = d;
	a->a_pa.pa_function = fn;
	a->a_pa.pa_id = pci_conf_read(&a->a_pc, a->a_pa.pa_tag, PCI_ID_REG);
	a->a_pa.pa_class = pci_conf_read(&a->a_pc, a->a_pa.pa_tag,
	    PCI_CLASS_REG);
	(void) snprintf(a->a_parent.dv_xname, sizeof (a->a_parent.dv_xname),
	    "nvidia%d", ddi_get_instance(gdip));
	a->a_parent.dv_private = gdip;

	/* not the primary display: i915 drives the panel */
	drm = drm_attach_pci(driver, &a->a_pa, 0, 0, &a->a_parent, NULL);
	/* drm_attach clears dev_private when it fails part way */
	if (drm == NULL || !nv_drm_sunos_drm_attached(drm)) {
		cmn_err(CE_WARN, "nvidia_drm: drm attach failed for %s",
		    a->a_parent.dv_xname);
		/* NOTE: like i915, a failed OpenBSD attach is not undone */
		return (NULL);
	}
	nvd_gpus[slot].g_drm = drm;
	nvd_gpus[slot].g_gpu_dip = gdip;
	nvd_gpus[slot].g_drmunit = nv_drm_sunos_drm_unit(drm);
	nvd_ngpus++;
	return (drm);
}

/*
 * ioremap_wc for nvidia-drm-gem-nvkms-memory.c: the BAR1 range NVKMS
 * mapMemory(KERNEL) returns, write-combined, through gfx_private as
 * nvidia's os_map_kernel_space does.
 */
struct nvd_wcmap {
	struct nvd_wcmap	*w_next;
	void			*w_va;
	size_t			w_size;
};
static struct nvd_wcmap	*nvd_wcmaps;
static kmutex_t		nvd_wclock;

void *
nv_drm_sunos_ioremap_wc(uint64_t pa, size_t size)
{
	struct nvd_wcmap *w;
	void *va;

	if (pa == 0 || size == 0)
		return (NULL);
	va = gfxp_map_kernel_space(pa, size, GFXP_MEMORY_WRITECOMBINED);
	if (va == NULL)
		return (NULL);
	w = kmem_zalloc(sizeof (*w), KM_SLEEP);
	w->w_va = va;
	w->w_size = size;
	mutex_enter(&nvd_wclock);
	w->w_next = nvd_wcmaps;
	nvd_wcmaps = w;
	mutex_exit(&nvd_wclock);
	return (va);
}

/* iounmap has no size: it is the one ioremap_wc recorded. */
void
nv_drm_sunos_iounmap(void *va)
{
	struct nvd_wcmap **wp, *w = NULL;

	mutex_enter(&nvd_wclock);
	for (wp = &nvd_wcmaps; *wp != NULL; wp = &(*wp)->w_next) {
		if ((*wp)->w_va == va) {
			w = *wp;
			*wp = w->w_next;
			break;
		}
	}
	mutex_exit(&nvd_wclock);
	if (w == NULL) {
		cmn_err(CE_WARN, "nvidia_drm: iounmap of an unknown mapping %p",
		    va);
		return;
	}
	gfxp_unmap_kernel_space(w->w_va, w->w_size);
	kmem_free(w, sizeof (*w));
}

/* ------------------------------------------------------------- DDI */
/*
 * The NVKMS/DRM start, at an open of ctl (nvd_lock held). 0, or ENXIO.
 */
static int
nvd_start(void)
{
	dev_info_t *dip = nvd_dip;
	int g, err;

	ASSERT(MUTEX_HELD(&nvd_lock));
	if (nvd_up)
		return (0);
	if (nvd_inited)
		return (ENXIO);	/* GPUs registered but minor nodes failed */
	err = nv_drm_init();
	nvd_inited = (err == 0);
	if (err != 0 || nvd_ngpus == 0) {
		cmn_err(CE_WARN, "nvidia_drm: nv_drm_init: %d, %d GPU(s)", err,
		    nvd_ngpus);
		if (err == 0) {
			nv_drm_exit();
			nvd_inited = 0;
		}
		nvd_ngpus = 0;
		return (ENXIO);
	}
	nvd_up = 1;
	for (g = 0; g < nvd_ngpus; g++) {
		char card[16], render[16];
		int u = nvd_gpus[g].g_drmunit;

		(void) snprintf(card, sizeof (card), "card%d", nvd_card_base + g);
		(void) snprintf(render, sizeof (render), "renderD%d",
		    128 + nvd_card_base + g);
		if (u < 0 ||
		    ddi_create_minor_node(dip, card, S_IFCHR,
		    I915_IL_MINOR(g, I915_IL_CARD, 0), DDI_NT_DISPLAY_DRM, 0) !=
		    DDI_SUCCESS ||
		    ddi_create_minor_node(dip, render, S_IFCHR,
		    I915_IL_MINOR(g, I915_IL_RENDER, 0), DDI_NT_DISPLAY_DRM, 0) !=
		    DDI_SUCCESS) {
			cmn_err(CE_WARN, "nvidia_drm: minor nodes for GPU %d "
			    "(drm unit %d)", g, u);
			/* nvidia-drm devices stay registered: see detach */
			nvd_up = 0;
			return (ENXIO);
		}
		cmn_err(CE_CONT, "?nvidia_drm: GPU %d: %s, %s\n", g, card,
		    render);
	}
	return (0);
}

static int
nvd_attach(dev_info_t *dip, ddi_attach_cmd_t cmd)
{
	if (cmd != DDI_ATTACH || nvd_dip != NULL)
		return (DDI_FAILURE);
	mutex_enter(&nvd_lock);
	nvd_card_base = ddi_prop_get_int(DDI_DEV_T_ANY, dip, DDI_PROP_DONTPASS,
	    "drm-card-base", 1);
	if (ddi_create_minor_node(dip, "ctl", S_IFCHR, NVD_CTL_MINOR,
	    DDI_PSEUDO, 0) != DDI_SUCCESS) {
		mutex_exit(&nvd_lock);
		return (DDI_FAILURE);
	}
	nvd_dip = dip;
	mutex_exit(&nvd_lock);
	ddi_report_dev(dip);
	return (DDI_SUCCESS);
}

/*
 * NOTE: no detach once attached, as i915: nv_drm_exit() unregisters the drm
 * devices, but OpenBSD's drm_attach() state (drm_cd units, the drm core's
 * global init) has no matching teardown here yet. The module stays held.
 */
static int
nvd_detach(dev_info_t *dip, ddi_detach_cmd_t cmd)
{
	(void) dip; (void) cmd;
	return (DDI_FAILURE);
}

static int
nvd_getinfo(dev_info_t *dip, ddi_info_cmd_t cmd, void *arg, void **res)
{
	(void) dip; (void) arg;
	switch (cmd) {
	case DDI_INFO_DEVT2DEVINFO:
		if (nvd_dip == NULL)
			return (DDI_FAILURE);
		*res = nvd_dip;
		return (DDI_SUCCESS);
	case DDI_INFO_DEVT2INSTANCE:
		*res = (void *)0;
		return (DDI_SUCCESS);
	default:
		return (DDI_FAILURE);
	}
}

/* ------------------------------------------------------------- cdev */
static struct nvd_gpu *
nvd_gpu(dev_t dev)
{
	uint32_t g = I915_IL_INST(getminor(dev));

	if (!nvd_up || getminor(dev) == NVD_CTL_MINOR ||
	    g >= (uint32_t)nvd_ngpus)
		return (NULL);
	return (&nvd_gpus[g]);
}

/* The dev_t the drm core sees: same major, the OpenBSD minor. */
static dev_t
nvd_odev(struct nvd_gpu *g, dev_t dev)
{
	return (makedevice(getmajor(dev),
	    i915_il_ominor(getminor(dev), (uint32_t)g->g_drmunit)));
}

static int
nvd_open(dev_t *devp, int flag, int otyp, cred_t *cr)
{
	struct nvd_gpu *g;
	minor_t m = getminor(*devp);
	id_t clone;
	dev_t ndev;
	int err;

	if (otyp != OTYP_CHR)
		return (ENXIO);
	if (m == NVD_CTL_MINOR) {
		/* the start: root only (drv_priv; the card/renderD minors are 0666) */
		if ((err = drv_priv(cr)) != 0)
			return (err);
		mutex_enter(&nvd_lock);
		err = nvd_start();
		mutex_exit(&nvd_lock);
		return (err);
	}
	if ((g = nvd_gpu(*devp)) == NULL)
		return (ENXIO);
	if (I915_IL_CLONE(m) != 0)
		return (ENXIO);		/* clones are never opened by name */
	if (I915_IL_KIND(m) != I915_IL_CARD && I915_IL_KIND(m) != I915_IL_RENDER)
		return (ENXIO);		/* no text or dma-buf minors (D2.4) */
	if ((clone = id_alloc_nosleep(nvd_clones)) == -1)
		return (EBUSY);
	ndev = makedevice(getmajor(*devp),
	    I915_IL_MINOR(I915_IL_INST(m), I915_IL_KIND(m), clone));
	mutex_enter(&nvd_lock);
	err = drmopen(nvd_odev(g, ndev), (flag & FEXCL) ? O_EXCL : 0, S_IFCHR,
	    curproc);
	mutex_exit(&nvd_lock);
	if (err != 0) {
		id_free(nvd_clones, clone);
		return (err);
	}
	*devp = ndev;
	return (0);
}

static int
nvd_close(dev_t dev, int flag, int otyp, cred_t *cr)
{
	struct nvd_gpu *g = nvd_gpu(dev);
	minor_t m = getminor(dev);
	dev_t odev;
	int err;

	(void) flag; (void) otyp; (void) cr;
	if (m == NVD_CTL_MINOR)
		return (0);
	if (g == NULL)
		return (ENXIO);
	if (I915_IL_CLONE(m) == 0)
		return (0);
	odev = nvd_odev(g, dev);
	mutex_enter(&nvd_lock);
	nv_drm_sunos_pollhead_clean(odev);
	err = drmclose(odev, 0, S_IFCHR, curproc);
	mutex_exit(&nvd_lock);
	id_free(nvd_clones, (id_t)I915_IL_CLONE(m));
	return (err);
}

static int
nvd_read(dev_t dev, struct uio *uio, cred_t *cr)
{
	struct nvd_gpu *g = nvd_gpu(dev);

	(void) cr;
	if (g == NULL || I915_IL_CLONE(getminor(dev)) == 0)
		return (ENXIO);
	return (drmread(nvd_odev(g, dev), uio,
	    (uio->uio_fmode & (FNDELAY | FNONBLOCK)) ? IO_NDELAY : 0));
}

static int
nvd_chpoll(dev_t dev, short events, int anyyet, short *reventsp,
    struct pollhead **phpp)
{
	struct nvd_gpu *g = nvd_gpu(dev);

	if (g == NULL || I915_IL_CLONE(getminor(dev)) == 0)
		return (ENXIO);
	return (nv_drm_sunos_chpoll(nvd_odev(g, dev), events, anyyet,
	    reventsp, phpp));
}

/* As i915_il_ioctl: copy the Linux-encoded DRM argument in and out. */
static int
nvd_ioctl(dev_t dev, int cmd, intptr_t arg, int mode, cred_t *cr, int *rval)
{
	struct nvd_gpu *g = nvd_gpu(dev);
	struct i915_ioc x;
	caddr_t buf = NULL;
	int err;

	(void) cr;
	if (g == NULL || I915_IL_CLONE(getminor(dev)) == 0)
		return (ENXIO);
	if (i915_ioc_xlate((uint32_t)cmd, &x) != 0)
		return (ENOTTY);
	*rval = 0;
	if (x.size != 0) {
		buf = kmem_zalloc(x.size, KM_SLEEP);
		if (x.in && ddi_copyin((void *)arg, buf, x.size, mode) != 0) {
			kmem_free(buf, x.size);
			return (EFAULT);
		}
	}
	err = drmioctl(nvd_odev(g, dev), x.ocmd, buf, 0, curproc);
	if (err == ERESTART || err == EJUSTRETURN)
		err = EINTR;		/* illumos restarts nothing for drivers */
	if (err == 0 && x.out && ddi_copyout(buf, (void *)arg, x.size, mode))
		err = EFAULT;
	if (buf != NULL)
		kmem_free(buf, x.size);
	return (err);
}

/* STUB until D2.3: GEM mmap (dumb buffers) needs an NVKMS devmap path. */
static int
nvd_devmap(dev_t dev, devmap_cookie_t dhp, offset_t off, size_t len,
    size_t *maplen, uint_t model)
{
	(void) dev; (void) dhp; (void) off; (void) len; (void) maplen;
	(void) model;
	return (ENOTSUP);
}

static struct cb_ops nvd_cb_ops = {
	.cb_open = nvd_open,
	.cb_close = nvd_close,
	.cb_strategy = nodev,
	.cb_print = nodev,
	.cb_dump = nodev,
	.cb_read = nvd_read,
	.cb_write = nodev,
	.cb_ioctl = nvd_ioctl,
	.cb_devmap = nvd_devmap,
	.cb_mmap = nodev,
	.cb_segmap = ddi_devmap_segmap,
	.cb_chpoll = nvd_chpoll,
	.cb_prop_op = ddi_prop_op,
	.cb_str = NULL,
	.cb_flag = D_NEW | D_MP | D_64BIT | D_DEVMAP,
	.cb_rev = CB_REV,
	.cb_aread = nodev,
	.cb_awrite = nodev,
};

static struct dev_ops nvd_dev_ops = {
	.devo_rev = DEVO_REV,
	.devo_refcnt = 0,
	.devo_getinfo = nvd_getinfo,
	.devo_identify = nulldev,
	.devo_probe = nulldev,
	.devo_attach = nvd_attach,
	.devo_detach = nvd_detach,
	.devo_reset = nodev,
	.devo_cb_ops = &nvd_cb_ops,
	.devo_bus_ops = NULL,
	.devo_power = NULL,
	.devo_quiesce = ddi_quiesce_not_needed,
};

/*
 * drv/nvidia_modeset: NVKMS (nvKmsKapiGetFunctionsTable, the KAPI F16/F32
 * helpers) and, through its own NEEDED, drv/nvidia. misc/gfx_private: the
 * write-combined kernel mappings.
 */
char _depends_on[] = "drv/nvidia_modeset misc/gfx_private";

static struct modldrv nvd_modldrv = {
	&mod_driverops,
	"nvidia-drm (NVKMS over OpenBSD drm)",
	&nvd_dev_ops,
};

static struct modlinkage nvd_modlinkage = {
	MODREV_1, { &nvd_modldrv, NULL }
};

int
_init(void)
{
	int err;

	mutex_init(&nvd_lock, NULL, MUTEX_DRIVER, NULL);
	mutex_init(&nvd_wclock, NULL, MUTEX_DRIVER, NULL);
	obsd_compat_init();
	nvd_clones = id_space_create("nvidia_drm_clone", 1,
	    I915_IL_CLONE_MAX + 1);
	if ((err = mod_install(&nvd_modlinkage)) != 0) {
		id_space_destroy(nvd_clones);
		obsd_compat_fini();
		mutex_destroy(&nvd_wclock);
		mutex_destroy(&nvd_lock);
	}
	return (err);
}

int
_fini(void)
{
	int err;

	/* NVKMS calls back into nvidia-drm (callbacks, drm devices) */
	if (nvd_inited)
		return (EBUSY);
	if ((err = mod_remove(&nvd_modlinkage)) != 0)
		return (err);
	id_space_destroy(nvd_clones);
	obsd_compat_fini();
	mutex_destroy(&nvd_wclock);
	mutex_destroy(&nvd_lock);
	return (0);
}

int
_info(struct modinfo *mi)
{
	return (mod_info(&nvd_modlinkage, mi));
}
