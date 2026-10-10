/*
 * i915_illumos.c -- the illumos driver entry points for OpenBSD's inteldrm
 * (drm/i915), rung R1 of docs/x1-gpu-route.md.
 *
 * What it does:
 *   _init/_fini/_info: modlinkage for the "i915" driver; _init brings up
 *     the OpenBSD compat layer (obsd_compat_init).
 *   attach (DDI): pci_config_setup, match the device with i915_pciid.c,
 *     then the console first: gfxp_fb_attach (gfx_private, exactly what
 *     vgatext does) and the "text-0" minor, created FIRST because tem
 *     opens the first minor of the console node (docs/x1-gpu-route.md 5.6
 *     F1). The firmware mode is kept; nothing touches the GPU yet.
 *   first open of card0 or renderD128: the OpenBSD inteldrm attach
 *     (inteldrm_ca.ca_match / ca_attach, i915_driver.c: BAR0, MSI,
 *     drm_attach_pci, then inteldrm_attachhook -> i915_driver_probe, the
 *     modeset). Deferred so a boot that only uses the console never
 *     modesets. Its wsdisplay step is a STUB (obsd_glue.c rasops_init);
 *     the console stays on gfxp_fb.
 *   cdev: clone minors per open (i915_drmioc.h layout) into drmopen/
 *     drmclose/drmread/drmioctl; ioctls decoded from the Linux _IOC
 *     encoding solnix userland uses and re-encoded for drm (F4); the
 *     argument copied in/out here, as OpenBSD's sys_ioctl does; poll over
 *     the drm_file's selinfo; devmap of dumb buffers (F6/F7).
 *   console: KD_GRAPHICS on the text minor while a DRM master exists,
 *     KD_TEXT (after drm_client_dev_restore) when it goes, the way Xorg
 *     drives vgatext with KDSETMODE.
 *   detach: refused (inteldrm has no teardown; OpenBSD's inteldrm_detach
 *     returns 0 without undoing anything); DDI_SUSPEND/RESUME: refused.
 *
 * NOT LOADED. This file builds into the i915 module; loading it needs the
 * crash dump device the maintainer has not approved, and binding it needs
 * an alias for pciex8086,3e9b that nothing installs. See ATTACH-PLAN.md.
 */
#include <sys/types.h>
#include <sys/modctl.h>
#include <sys/conf.h>
#include <sys/stat.h>
#include <sys/kd.h>
#include <sys/gfx_private.h>
#include <sys/ddidevmap.h>
#include <sys/id_space.h>
#include <obsd_prelude.h>
#include "i915_pciid.h"
#include "i915_drmioc.h"
#include "i915_drmglue.h"

/* OpenBSD's inteldrm autoconf glue (i915_driver.c). */
extern const struct cfattach inteldrm_ca;
extern int inteldrm_fatal_error;

struct i915_il {
	dev_info_t		*il_dip;
	ddi_acc_handle_t	il_cfg;
	struct obsd_pci_chipset	il_pc;
	struct obsd_bus_space	il_memt, il_iot;
	struct bus_dma_tag	il_dmat;
	struct pci_attach_args	il_pa;
	struct device		il_parent;	/* the "pci" parent */
	struct device		*il_self;	/* drm_i915_private */
	int			il_bus, il_dev, il_fn;
	const struct i915_pciid_info *il_id;
	gfxp_fb_softc_ptr_t	il_gfxp;	/* the text-0 console */
	kmutex_t		il_lock;	/* drm attach, console mode */
	int			il_drm_state;	/* 0 not tried, 1 up, -1 failed */
	int			il_drmunit;	/* drm_cd unit */
	int			il_graphics;	/* text-0 in KD_GRAPHICS for drm */
};

/* Clone indices for card/render opens, shared by every instance. */
static id_space_t *i915_il_clones;


static void *i915_il_state;

/* PCI bus/dev/fn of the node, from the first "reg" entry's phys.hi. */
static int
i915_il_bdf(dev_info_t *dip, int *bus, int *dev, int *fn)
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

static int
i915_il_attach(dev_info_t *dip, ddi_attach_cmd_t cmd)
{
	struct i915_il *il;
	const struct i915_pciid_info *id;
	uint16_t ven, dev;
	uint32_t class;
	int inst = ddi_get_instance(dip), bus, d, fn;

	if (cmd != DDI_ATTACH)
		return (DDI_FAILURE);
	if (ddi_soft_state_zalloc(i915_il_state, inst) != DDI_SUCCESS)
		return (DDI_FAILURE);
	il = ddi_get_soft_state(i915_il_state, inst);
	il->il_dip = dip;
	if (pci_config_setup(dip, &il->il_cfg) != DDI_SUCCESS)
		goto fail;
	ven = pci_config_get16(il->il_cfg, PCI_ID_REG);
	dev = pci_config_get16(il->il_cfg, PCI_ID_REG + 2);
	class = pci_config_get32(il->il_cfg, PCI_CLASS_REG) >> 8;
	id = i915_pciid_match(ven, dev, class);
	if (id == NULL) {
		cmn_err(CE_NOTE, "!i915%d: %04x:%04x class %06x: not a "
		    "supported Intel GPU", inst, ven, dev, class);
		goto fail;
	}
	if (i915_il_bdf(dip, &bus, &d, &fn) != DDI_SUCCESS)
		goto fail;

	il->il_bus = bus;
	il->il_dev = d;
	il->il_fn = fn;
	il->il_id = id;
	mutex_init(&il->il_lock, NULL, MUTEX_DRIVER, NULL);
	il->il_drmunit = -1;

	/*
	 * The console text minor first (F1): gfxp_fb_attach finds out from
	 * the boot framebuffer whether this device is the console and maps
	 * the firmware framebuffer, as vgatext does.
	 */
	il->il_gfxp = gfxp_fb_softc_alloc();
	if (il->il_gfxp == NULL ||
	    gfxp_fb_attach(dip, DDI_ATTACH, il->il_gfxp) != DDI_SUCCESS)
		goto fail;
	if (ddi_create_minor_node(dip, "text-0", S_IFCHR,
	    I915_IL_MINOR(inst, I915_IL_TEXT, 0), DDI_NT_DISPLAY, 0) !=
	    DDI_SUCCESS ||
	    ddi_create_minor_node(dip, "card0", S_IFCHR,
	    I915_IL_MINOR(inst, I915_IL_CARD, 0), DDI_NT_DISPLAY_DRM, 0) !=
	    DDI_SUCCESS ||
	    ddi_create_minor_node(dip, "renderD128", S_IFCHR,
	    I915_IL_MINOR(inst, I915_IL_RENDER, 0), DDI_NT_DISPLAY_DRM, 0) !=
	    DDI_SUCCESS)
		goto fail_minor;
	cmn_err(CE_CONT, "?i915%d: %s gen%u gt%u, console on gfxp_fb; "
	    "OpenBSD inteldrm attach on first open\n", inst, id->platform,
	    id->gen, id->gt);
	ddi_report_dev(dip);
	return (DDI_SUCCESS);

fail_minor:
	ddi_remove_minor_node(dip, NULL);
	(void) gfxp_fb_detach(dip, DDI_DETACH, il->il_gfxp);
fail:
	if (il->il_gfxp != NULL)
		gfxp_fb_softc_free(il->il_gfxp);
	if (il->il_cfg != NULL)
		pci_config_teardown(&il->il_cfg);
	ddi_soft_state_free(i915_il_state, inst);
	return (DDI_FAILURE);
}

/*
 * The OpenBSD inteldrm attach, run once from the first open of card0 or
 * renderD128 with il_lock held. 0, or ENXIO if it failed (it is not tried
 * again: OpenBSD sets inteldrm_fatal_error and refuses every later match).
 */
static int
i915_il_drm_attach(struct i915_il *il)
{
	dev_info_t *dip = il->il_dip;
	int inst = ddi_get_instance(dip);
	struct pci_attach_args *pa;
	struct device *self;

	if (il->il_drm_state != 0)
		return (il->il_drm_state > 0 ? 0 : ENXIO);
	il->il_drm_state = -1;
	il->il_pc.pc_dip = dip;
	il->il_pc.pc_cfg = il->il_cfg;
	il->il_pc.pc_self = pci_make_tag(NULL, il->il_bus, il->il_dev,
	    il->il_fn);
	il->il_memt.bs_dip = dip;
	il->il_iot.bs_dip = dip;
	il->il_iot.bs_io = 1;
	il->il_dmat.dt_dip = dip;
	pa = &il->il_pa;
	pa->pa_pc = &il->il_pc;
	pa->pa_memt = &il->il_memt;
	pa->pa_iot = &il->il_iot;
	pa->pa_dmat = &il->il_dmat;
	pa->pa_tag = il->il_pc.pc_self;
	pa->pa_bus = il->il_bus;
	pa->pa_device = il->il_dev;
	pa->pa_function = il->il_fn;
	pa->pa_id = pci_conf_read(pa->pa_pc, pa->pa_tag, PCI_ID_REG);
	pa->pa_class = pci_conf_read(pa->pa_pc, pa->pa_tag, PCI_CLASS_REG);
	pa->pa_flags = PCI_FLAGS_MEM_ENABLED | PCI_FLAGS_MSI_ENABLED;
	pa->pa_memex = NULL;		/* no MCHBAR allocation (obsd_glue.c) */
	(void) snprintf(il->il_parent.dv_xname, sizeof (il->il_parent.dv_xname),
	    "pci%d", il->il_bus);
	il->il_parent.dv_private = dip;

	if (inteldrm_ca.ca_match(&il->il_parent, NULL, pa) == 0) {
		cmn_err(CE_NOTE, "!i915%d: inteldrm_match refused", inst);
		return (ENXIO);
	}
	/* autoconf: the softc is the OpenBSD struct drm_i915_private. */
	self = kmem_zalloc(inteldrm_ca.ca_devsize, KM_SLEEP);
	self->dv_unit = inst;
	self->dv_parent = &il->il_parent;
	self->dv_private = dip;
	(void) snprintf(self->dv_xname, sizeof (self->dv_xname), "inteldrm%d",
	    inst);
	il->il_self = self;
	inteldrm_ca.ca_attach(&il->il_parent, self, pa);
	/*
	 * NOTE: inteldrm has no teardown that undoes a partial attach
	 * (OpenBSD's inteldrm_detach is empty). What it allocated stays
	 * allocated and the module stays held (detach is refused), which
	 * keeps its text alive for the interrupt handlers and taskq entries
	 * it registered.
	 */
	if (inteldrm_fatal_error ||
	    (il->il_drmunit = i915_glue_drm_unit(self)) < 0) {
		cmn_err(CE_WARN, "i915%d: inteldrm attach failed; the console "
		    "stays on the firmware framebuffer", inst);
		return (ENXIO);
	}
	il->il_drm_state = 1;
	return (0);
}

static int
i915_il_detach(dev_info_t *dip, ddi_detach_cmd_t cmd)
{
	(void) dip;
	(void) cmd;
	/* see the header: no OpenBSD teardown to call */
	return (DDI_FAILURE);
}

static int
i915_il_getinfo(dev_info_t *dip, ddi_info_cmd_t cmd, void *arg, void **res)
{
	struct i915_il *il;
	int inst = (int)I915_IL_INST(getminor((dev_t)arg));

	(void) dip;
	switch (cmd) {
	case DDI_INFO_DEVT2DEVINFO:
		il = ddi_get_soft_state(i915_il_state, inst);
		if (il == NULL)
			return (DDI_FAILURE);
		*res = il->il_dip;
		return (DDI_SUCCESS);
	case DDI_INFO_DEVT2INSTANCE:
		*res = (void *)(uintptr_t)inst;
		return (DDI_SUCCESS);
	default:
		return (DDI_FAILURE);
	}
}

/* ------------------------------------------------------------- cdev */
/* OpenBSD's drm entry points (drm_drv.c, drm_ioctl.c). */
extern int drmopen(dev_t, int, int, struct proc *);
extern int drmclose(dev_t, int, int, struct proc *);
extern int drmread(dev_t, struct uio *, int);
extern int drmioctl(dev_t, u_long, caddr_t, int, struct proc *);

static struct i915_il *
i915_il_get(dev_t dev)
{
	return (ddi_get_soft_state(i915_il_state,
	    (int)I915_IL_INST(getminor(dev))));
}

/* The dev_t drm sees: same major, the OpenBSD minor (i915_drmioc.h). */
static dev_t
i915_il_odev(struct i915_il *il, dev_t dev)
{
	return (makedevice(getmajor(dev),
	    i915_il_ominor(getminor(dev), (uint32_t)il->il_drmunit)));
}

/*
 * Keep the text console out of the way while a DRM master owns the
 * display (F1): KD_GRAPHICS stops tem drawing into the firmware
 * framebuffer (gfxp_bitmap then only updates its shadow copy); KD_TEXT,
 * after drm_client_dev_restore has put the kernel configuration back,
 * repaints the console from that shadow. Called with il_lock held after
 * every open, close and SET/DROP_MASTER. gfxp_fb ignores the request when
 * this device is not the console.
 */
static void
i915_il_console_sync(struct i915_il *il, dev_t odev)
{
	int master = i915_glue_has_master(odev), rval;

	if (master == il->il_graphics)
		return;
	if (!master)
		i915_glue_restore(odev);
	if (gfxp_fb_ioctl(odev, KDSETMODE, master ? KD_GRAPHICS : KD_TEXT,
	    FKIOCTL, kcred, &rval, il->il_gfxp) == 0)
		il->il_graphics = master;
}

static int
i915_il_open(dev_t *devp, int flag, int otyp, cred_t *cr)
{
	struct i915_il *il = i915_il_get(*devp);
	minor_t m = getminor(*devp);
	id_t clone;
	dev_t ndev;
	int err;

	if (il == NULL || otyp != OTYP_CHR)
		return (ENXIO);
	if (I915_IL_CLONE(m) != 0)
		return (ENXIO);		/* clones are never opened by name */
	if (I915_IL_KIND(m) == I915_IL_TEXT)
		return (gfxp_fb_open(devp, flag, otyp, cr, il->il_gfxp));
	if (I915_IL_KIND(m) != I915_IL_CARD && I915_IL_KIND(m) != I915_IL_RENDER)
		return (ENXIO);

	mutex_enter(&il->il_lock);
	if ((err = i915_il_drm_attach(il)) != 0)
		goto out;
	if ((clone = id_alloc_nosleep(i915_il_clones)) == -1) {
		err = EBUSY;
		goto out;
	}
	ndev = makedevice(getmajor(*devp),
	    I915_IL_MINOR(I915_IL_INST(m), I915_IL_KIND(m), clone));
	/* O_EXCL: drmopen refuses exclusive opens (EBUSY), as on OpenBSD */
	err = drmopen(i915_il_odev(il, ndev), (flag & FEXCL) ? O_EXCL : 0,
	    S_IFCHR, curproc);
	if (err != 0) {
		id_free(i915_il_clones, clone);
		goto out;
	}
	*devp = ndev;
	i915_il_console_sync(il, i915_il_odev(il, ndev));
out:
	mutex_exit(&il->il_lock);
	return (err);
}

static int
i915_il_close(dev_t dev, int flag, int otyp, cred_t *cr)
{
	struct i915_il *il = i915_il_get(dev);
	minor_t m = getminor(dev);
	dev_t odev;
	int err;

	if (il == NULL)
		return (ENXIO);
	if (I915_IL_KIND(m) == I915_IL_TEXT)
		return (gfxp_fb_close(dev, flag, otyp, cr, il->il_gfxp));
	if (I915_IL_CLONE(m) == 0 || il->il_drm_state <= 0)
		return (0);
	odev = i915_il_odev(il, dev);
	mutex_enter(&il->il_lock);
	i915_glue_pollhead_clean(odev);
	err = drmclose(odev, 0, S_IFCHR, curproc);
	id_free(i915_il_clones, (id_t)I915_IL_CLONE(m));
	i915_il_console_sync(il, odev);
	mutex_exit(&il->il_lock);
	return (err);
}

/* drm clones only; the text minor and the bare nodes have no drm_file. */
static struct i915_il *
i915_il_drmfile(dev_t dev)
{
	struct i915_il *il = i915_il_get(dev);

	if (il == NULL || il->il_drm_state <= 0 ||
	    I915_IL_CLONE(getminor(dev)) == 0 ||
	    I915_IL_KIND(getminor(dev)) == I915_IL_TEXT)
		return (NULL);
	return (il);
}

static int
i915_il_read(dev_t dev, struct uio *uio, cred_t *cr)
{
	struct i915_il *il = i915_il_drmfile(dev);

	(void) cr;
	if (il == NULL)
		return (ENXIO);
	return (drmread(i915_il_odev(il, dev), uio,
	    (uio->uio_fmode & (FNDELAY | FNONBLOCK)) ? IO_NDELAY : 0));
}

static int
i915_il_chpoll(dev_t dev, short events, int anyyet, short *reventsp,
    struct pollhead **phpp)
{
	struct i915_il *il = i915_il_drmfile(dev);

	if (il == NULL)
		return (ENXIO);
	return (i915_glue_chpoll(i915_il_odev(il, dev), events, anyyet,
	    reventsp, phpp));
}

/*
 * ioctl: a DRM command from solnix userland is Linux-encoded (F4);
 * i915_ioc_xlate gives the OpenBSD command and the copy directions, and
 * this function does what OpenBSD's sys_ioctl does around a driver ioctl:
 * a zeroed kernel buffer of the encoded size, copyin before, copyout after
 * success. Everything that is not a DRM ('d') command goes to gfxp_fb on
 * the text minor and is ENOTTY on the drm minors.
 */
static int
i915_il_ioctl(dev_t dev, int cmd, intptr_t arg, int mode, cred_t *cr,
    int *rval)
{
	struct i915_il *il = i915_il_get(dev);
	struct i915_ioc x;
	dev_t odev;
	caddr_t buf = NULL;
	int err, master_cmd;

	if (il == NULL)
		return (ENXIO);
	if (I915_IL_KIND(getminor(dev)) == I915_IL_TEXT)
		return (gfxp_fb_ioctl(dev, cmd, arg, mode, cr, rval,
		    il->il_gfxp));
	if (i915_il_drmfile(dev) == NULL)
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
	odev = i915_il_odev(il, dev);
	err = drmioctl(odev, x.ocmd, buf, 0, curproc);
	if (err == ERESTART || err == EJUSTRETURN)
		err = EINTR;		/* illumos restarts nothing for drivers */
	if (err == 0 && x.out && ddi_copyout(buf, (void *)arg, x.size, mode))
		err = EFAULT;
	if (buf != NULL)
		kmem_free(buf, x.size);
	master_cmd = (x.ocmd & 0xffffu) == 0x641e ||	/* SET_MASTER */
	    (x.ocmd & 0xffffu) == 0x641f;		/* DROP_MASTER */
	if (master_cmd) {
		mutex_enter(&il->il_lock);
		i915_il_console_sync(il, odev);
		mutex_exit(&il->il_lock);
	}
	return (err);
}

/*
 * devmap (F6/F7): the text minor maps the firmware framebuffer through
 * gfxp_fb (what vgatext serves). A drm clone maps a dumb buffer by the
 * offset MAP_DUMB returned: the object pinned into a contiguous
 * write-combined kernel mapping, handed to segdev as a KMEM_NON_PAGEABLE
 * umem cookie (gfxp_umem_cookie_init) with write-combining. The pin and
 * the cookie belong to the mapping and are dropped in devmap_unmap.
 */
struct i915_il_map {
	ddi_umem_cookie_t	m_cookie;
	void			*m_obj;
	size_t			m_size;
	volatile uint32_t	m_refs;		/* devmap handles sharing it */
};

static int
i915_il_dm_map(devmap_cookie_t dhp, dev_t dev, uint_t flags, offset_t off,
    size_t len, void **pvtp)
{
	(void) dhp; (void) dev; (void) flags; (void) off; (void) len;
	(void) pvtp;		/* set by i915_il_devmap before this runs */
	return (0);
}

static int
i915_il_dm_dup(devmap_cookie_t dhp, void *pvtp, devmap_cookie_t ndhp,
    void **npvtp)
{
	struct i915_il_map *mp = pvtp;

	(void) dhp; (void) ndhp;
	atomic_inc_32(&mp->m_refs);
	*npvtp = mp;
	return (0);
}

static void
i915_il_dm_unmap(devmap_cookie_t dhp, void *pvtp, offset_t off, size_t len,
    devmap_cookie_t ndhp1, void **npvtp1, devmap_cookie_t ndhp2,
    void **npvtp2)
{
	struct i915_il_map *mp = pvtp;

	(void) dhp; (void) off; (void) len;
	/* a partial unmap leaves one or two pieces that keep the mapping */
	if (ndhp1 != NULL) {
		atomic_inc_32(&mp->m_refs);
		*npvtp1 = mp;
	}
	if (ndhp2 != NULL) {
		atomic_inc_32(&mp->m_refs);
		*npvtp2 = mp;
	}
	if (atomic_dec_32_nv(&mp->m_refs) != 0)
		return;
	gfxp_umem_cookie_destroy(mp->m_cookie);
	i915_glue_dumb_unmap(mp->m_obj);
	kmem_free(mp, sizeof (*mp));
}

static struct devmap_callback_ctl i915_il_dm_ops = {
	.devmap_rev = DEVMAP_OPS_REV,
	.devmap_map = i915_il_dm_map,
	.devmap_access = NULL,
	.devmap_dup = i915_il_dm_dup,
	.devmap_unmap = i915_il_dm_unmap,
};

static ddi_device_acc_attr_t i915_il_wc_attr = {
	.devacc_attr_version = DDI_DEVICE_ATTR_V0,
	.devacc_attr_endian_flags = DDI_NEVERSWAP_ACC,
	.devacc_attr_dataorder = DDI_MERGING_OK_ACC,	/* write-combining */
};

static int
i915_il_devmap(dev_t dev, devmap_cookie_t dhp, offset_t off, size_t len,
    size_t *maplen, uint_t model)
{
	struct i915_il *il = i915_il_get(dev);
	struct i915_il_map *mp;
	devmap_handle_t *h = (devmap_handle_t *)dhp;
	void *kva, *obj;
	size_t size;
	int ro, err;

	if (il == NULL)
		return (ENXIO);
	if (I915_IL_KIND(getminor(dev)) == I915_IL_TEXT)
		return (gfxp_fb_devmap(dev, dhp, off, len, maplen, model,
		    il->il_gfxp));
	if (i915_il_drmfile(dev) == NULL)
		return (ENXIO);
	err = i915_glue_dumb_map(i915_il_odev(il, dev), (uint64_t)off, len,
	    &kva, &size, &ro, &obj);
	if (err != 0)
		return (err);
	if (len > size) {
		i915_glue_dumb_unmap(obj);
		return (EINVAL);
	}
	mp = kmem_zalloc(sizeof (*mp), KM_SLEEP);
	mp->m_obj = obj;
	mp->m_size = size;
	mp->m_refs = 1;
	mp->m_cookie = gfxp_umem_cookie_init(kva, size);
	/* the umem offset is from the start of the object, not the fake
	 * drm offset the mmap used */
	err = gfxp_devmap_umem_setup(dhp, il->il_dip, &i915_il_dm_ops,
	    mp->m_cookie, 0, len, ro ? PROT_READ | PROT_USER : PROT_ALL,
	    0, &i915_il_wc_attr);
	if (err != 0) {
		gfxp_umem_cookie_destroy(mp->m_cookie);
		i915_glue_dumb_unmap(obj);
		kmem_free(mp, sizeof (*mp));
		return (err);
	}
	/*
	 * devmap_umem_setup leaves dh_pvtp to the devmap_map callback; set it
	 * here so the callbacks own mp from now on (devmap_setup frees the
	 * handle without calling devmap_unmap if devmap_device fails; that
	 * path leaks mp and the pin, NOTE: bounded by failed mmap calls).
	 */
	h->dh_pvtp = mp;
	*maplen = len;
	return (0);
}

static struct cb_ops i915_il_cb_ops = {
	.cb_open = i915_il_open,
	.cb_close = i915_il_close,
	.cb_strategy = nodev,
	.cb_print = nodev,
	.cb_dump = nodev,
	.cb_read = i915_il_read,
	.cb_write = nodev,
	.cb_ioctl = i915_il_ioctl,
	.cb_devmap = i915_il_devmap,
	.cb_mmap = nodev,
	.cb_segmap = ddi_devmap_segmap,
	.cb_chpoll = i915_il_chpoll,
	.cb_prop_op = ddi_prop_op,
	.cb_str = NULL,
	.cb_flag = D_NEW | D_MP | D_64BIT | D_DEVMAP,
	.cb_rev = CB_REV,
	.cb_aread = nodev,
	.cb_awrite = nodev,
};

static struct dev_ops i915_il_dev_ops = {
	.devo_rev = DEVO_REV,
	.devo_refcnt = 0,
	.devo_getinfo = i915_il_getinfo,
	.devo_identify = nulldev,
	.devo_probe = nulldev,
	.devo_attach = i915_il_attach,
	.devo_detach = i915_il_detach,
	.devo_reset = nodev,
	.devo_cb_ops = &i915_il_cb_ops,
	.devo_bus_ops = NULL,
	.devo_power = NULL,
	.devo_quiesce = ddi_quiesce_not_supported,
};

/* gfxp_fb_* and gfxp_umem_* live in misc/gfx_private, as for vgatext. */
char _depends_on[] = "misc/gfx_private";

static struct modldrv i915_il_modldrv = {
	&mod_driverops,
	"i915 (OpenBSD inteldrm, Gen9)",
	&i915_il_dev_ops,
};

static struct modlinkage i915_il_modlinkage = {
	MODREV_1, { &i915_il_modldrv, NULL }
};

int
_init(void)
{
	int err;

	if ((err = ddi_soft_state_init(&i915_il_state,
	    sizeof (struct i915_il), 1)) != 0)
		return (err);
	obsd_compat_init();
	i915_il_clones = id_space_create("i915_clone", 1,
	    I915_IL_CLONE_MAX + 1);
	if ((err = mod_install(&i915_il_modlinkage)) != 0) {
		id_space_destroy(i915_il_clones);
		obsd_compat_fini();
		ddi_soft_state_fini(&i915_il_state);
	}
	return (err);
}

int
_fini(void)
{
	int err;

	if ((err = mod_remove(&i915_il_modlinkage)) != 0)
		return (err);
	id_space_destroy(i915_il_clones);
	obsd_compat_fini();
	ddi_soft_state_fini(&i915_il_state);
	return (0);
}

int
_info(struct modinfo *mi)
{
	return (mod_info(&i915_il_modlinkage, mi));
}
