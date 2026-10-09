/*
 * i915_illumos.c -- the illumos driver entry points for OpenBSD's inteldrm
 * (drm/i915), rung R1 of docs/x1-gpu-route.md.
 *
 * What it does:
 *   _init/_fini/_info: modlinkage for the "i915" driver; _init brings up
 *     the OpenBSD compat layer (obsd_compat_init).
 *   attach: pci_config_setup, match the device with i915_pciid.c (the Gen9
 *     table built from pciids.h), then build an illumos-backed
 *     struct pci_attach_args and run OpenBSD's own inteldrm attach
 *     (inteldrm_ca.ca_match / ca_attach, i915_driver.c). That attach maps
 *     BAR0 with pci_mapreg_map, sets up MSI with pci_intr_*, calls
 *     drm_attach_pci (config_found_sm -> drm_attach, obsd_glue.c), and runs
 *     the second stage (inteldrm_attachhook -> i915_driver_probe) through
 *     config_mountroot. Its last step, the wsdisplay console attach, fails
 *     cleanly by design (rasops_init STUB): the illumos console stays on
 *     gfxp_bitmap until the console handover in i915/ATTACH-PLAN.md.
 *   a /dev/dri/card0 minor node (DDI_NT_DISPLAY_DRM), for later; its
 *     open/ioctl are not wired to drmopen/drmioctl yet (ENXIO).
 *   detach: DDI_DETACH is refused while drm holds the device (inteldrm
 *     has no working detach on OpenBSD either: inteldrm_detach returns 0
 *     without undoing anything); DDI_SUSPEND/RESUME: refused (PLANNED).
 *
 * NOT LOADED. This file builds into the i915 module; loading it needs the
 * crash dump device the maintainer has not approved, and binding it needs
 * an alias for pciex8086,3e9b that nothing installs. See ATTACH-PLAN.md.
 */
#include <sys/types.h>
#include <sys/modctl.h>
#include <sys/conf.h>
#include <sys/stat.h>
#include <obsd_prelude.h>
#include "i915_pciid.h"

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
	int			il_minor;
};

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
	struct pci_attach_args *pa;
	const struct i915_pciid_info *id;
	uint16_t ven, dev;
	uint32_t class;
	int inst = ddi_get_instance(dip), bus, d, fn;
	struct device *self;

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

	/* The illumos-backed OpenBSD attach arguments. */
	il->il_pc.pc_dip = dip;
	il->il_pc.pc_cfg = il->il_cfg;
	il->il_pc.pc_self = pci_make_tag(NULL, bus, d, fn);
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
	pa->pa_bus = bus;
	pa->pa_device = d;
	pa->pa_function = fn;
	pa->pa_id = pci_conf_read(pa->pa_pc, pa->pa_tag, PCI_ID_REG);
	pa->pa_class = pci_conf_read(pa->pa_pc, pa->pa_tag, PCI_CLASS_REG);
	pa->pa_flags = PCI_FLAGS_MEM_ENABLED | PCI_FLAGS_MSI_ENABLED;
	pa->pa_memex = NULL;		/* no MCHBAR allocation (obsd_glue.c) */
	(void) snprintf(il->il_parent.dv_xname, sizeof (il->il_parent.dv_xname),
	    "pci%d", bus);
	il->il_parent.dv_private = dip;

	if (inteldrm_ca.ca_match(&il->il_parent, NULL, pa) == 0) {
		cmn_err(CE_NOTE, "!i915%d: inteldrm_match refused %04x:%04x",
		    inst, ven, dev);
		goto fail;
	}
	cmn_err(CE_CONT, "?i915%d: %s gen%u gt%u, OpenBSD inteldrm attach\n",
	    inst, id->platform, id->gen, id->gt);

	/* autoconf: the softc is the OpenBSD struct drm_i915_private. */
	self = kmem_zalloc(inteldrm_ca.ca_devsize, KM_SLEEP);
	self->dv_unit = inst;
	self->dv_parent = &il->il_parent;
	self->dv_private = dip;
	(void) snprintf(self->dv_xname, sizeof (self->dv_xname), "inteldrm%d",
	    inst);
	il->il_self = self;
	inteldrm_ca.ca_attach(&il->il_parent, self, pa);
	if (inteldrm_fatal_error) {
		/* the OpenBSD attach printed why; it leaves the device to
		 * the firmware console, as OpenBSD falls back to efifb */
		cmn_err(CE_WARN, "i915%d: inteldrm attach failed", inst);
		goto fail_drm;
	}

	il->il_minor = inst;
	if (ddi_create_minor_node(dip, "card0", S_IFCHR, il->il_minor,
	    DDI_NT_DISPLAY_DRM, 0) != DDI_SUCCESS)
		goto fail_drm;
	ddi_report_dev(dip);
	return (DDI_SUCCESS);

fail_drm:
	/*
	 * NOTE: inteldrm has no teardown that undoes a partial attach
	 * (OpenBSD's inteldrm_detach is empty). What it allocated stays
	 * allocated, and the module is then held: refusing _fini keeps its
	 * text alive for interrupt handlers and taskq entries it registered.
	 */
	il->il_self = NULL;
	ddi_remove_minor_node(dip, NULL);
	return (DDI_FAILURE);
fail:
	if (il->il_cfg != NULL)
		pci_config_teardown(&il->il_cfg);
	ddi_soft_state_free(i915_il_state, inst);
	return (DDI_FAILURE);
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
	int inst = (int)getminor((dev_t)arg);

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

/* PLANNED: drmopen/drmioctl/drmread/drmpoll/devmap through the OpenBSD
 * drm_drv.c entry points, with a clone minor per open. */
static int
i915_il_open(dev_t *devp, int flag, int otyp, cred_t *cr)
{
	(void) devp; (void) flag; (void) otyp; (void) cr;
	return (ENXIO);
}

static int
i915_il_close(dev_t dev, int flag, int otyp, cred_t *cr)
{
	(void) dev; (void) flag; (void) otyp; (void) cr;
	return (0);
}

static struct cb_ops i915_il_cb_ops = {
	.cb_open = i915_il_open,
	.cb_close = i915_il_close,
	.cb_strategy = nodev,
	.cb_print = nodev,
	.cb_dump = nodev,
	.cb_read = nodev,
	.cb_write = nodev,
	.cb_ioctl = nodev,
	.cb_devmap = nodev,
	.cb_mmap = nodev,
	.cb_segmap = nodev,
	.cb_chpoll = nochpoll,
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
	if ((err = mod_install(&i915_il_modlinkage)) != 0) {
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
	obsd_compat_fini();
	ddi_soft_state_fini(&i915_il_state);
	return (0);
}

int
_info(struct modinfo *mi)
{
	return (mod_info(&i915_il_modlinkage, mi));
}
