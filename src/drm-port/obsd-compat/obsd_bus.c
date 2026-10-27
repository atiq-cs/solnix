/*
 * obsd_bus.c -- OpenBSD bus_space and PCI interrupt/BAR/enumeration entry
 * points on the illumos DDI, for the i915 port.
 *
 * bus_space (REAL): bus_space_map(tag, pa, size) finds the "reg" entry of
 * the attached device whose assigned BAR contains pa and maps [pa, pa+size)
 * of it with ddi_regs_map_setup(9F). The handle OpenBSD code gets is the
 * kernel VA, which is what OpenBSD amd64 hands out for memory space and what
 * the read/write macros in obsd_bus.h dereference. BUS_SPACE_MAP_PREFETCHABLE
 * becomes DDI_MERGING_OK_ACC (write-combining, as gfxp_bitmap maps the GOP
 * framebuffer); otherwise DDI_STRICTORDER_ACC (uncached, MMIO). A physical
 * range that is not inside one of the device's BARs is mapped with
 * psm_map_phys_new (ACPI OpRegion, stolen memory, legacy VGA ROM), uncached.
 *
 * PCI interrupts (REAL): pci_intr_map_msi / pci_intr_map pick one MSI or
 * FIXED vector with ddi_intr_alloc; pci_intr_establish adds the handler at
 * the vector's priority and enables it. OpenBSD's handler returns int (1 =
 * claimed), which is the DDI_INTR_CLAIMED/UNCLAIMED convention.
 *
 * pci_find_device / pci_enumerate_bus (REAL): a walk of the illumos device
 * tree that builds a pci_attach_args for every PCI function and calls
 * OpenBSD's match function; inteldrm uses it to find the PCH (ISA bridge).
 */
#ifdef OBSD_USERTEST
#include <stdint.h>
typedef unsigned int uint_t;
#else
#include <sys/types.h>
#include <obsd_prelude.h>
#endif

/*
 * IEEE 1275 PCI binding, phys.hi = npt000ss bbbbbbbb dddddfff rrrrrrrr.
 * Decoded here: illumos sys/pci.h redefines OpenBSD's PCI_CLASS_* and
 * PCI_PMCSR names (measured: -Werror redefinition), so it is not included.
 */
typedef struct {
	uint32_t	pci_phys_hi, pci_phys_mid, pci_phys_low;
	uint32_t	pci_size_hi, pci_size_low;
} pci_regspec_t;
#define PCI_REG_REG_G(hi)	((hi) & 0xff)
#define PCI_REG_FUNC_G(hi)	(((hi) >> 8) & 0x7)
#define PCI_REG_DEV_G(hi)	(((hi) >> 11) & 0x1f)
#define PCI_REG_BUS_G(hi)	(((hi) >> 16) & 0xff)
#define PCI_REG_ADDR_G(hi)	(((hi) >> 24) & 0x3)
#define PCI_PREFETCH_B		0x40000000
#define PCI_ADDR_IO		0x1
#define PCI_CONF_BASE0		0x10
#define PCI_CONF_BASE5		0x24

/* The physical address map of a device: one entry per "reg" BAR entry. */
#define OBSD_NBAR	8
struct obsd_bar {
	int		rnumber;	/* index in "reg" */
	int		cfgoff;		/* 0x10..0x24 */
	int		space;		/* PCI_ADDR_MEM32/MEM64/IO */
	int		prefetch;
	uint64_t	base, size;
};

/*
 * Match each "assigned-addresses" entry (IEEE 1275 PCI binding: phys.hi,
 * phys.mid, phys.lo, size.hi, size.lo) to its "reg" index by config offset
 * (phys.hi bits 7:0) and space. Pure function of the two property arrays,
 * so test/test_bars.c checks it on dixi's real iGPU values.
 */
int
obsd_bars_parse(const pci_regspec_t *reg, uint_t nreg,
    const pci_regspec_t *aa, uint_t naa, struct obsd_bar *bar, int max)
{
	uint_t i, j;
	int n = 0;

	for (i = 0; i < naa && n < max; i++) {
		uint_t off = PCI_REG_REG_G(aa[i].pci_phys_hi);

		if (off < PCI_CONF_BASE0 || off > PCI_CONF_BASE5)
			continue;
		for (j = 0; j < nreg; j++) {
			if (PCI_REG_REG_G(reg[j].pci_phys_hi) != off ||
			    PCI_REG_ADDR_G(reg[j].pci_phys_hi) !=
			    PCI_REG_ADDR_G(aa[i].pci_phys_hi))
				continue;
			bar[n].rnumber = j;
			bar[n].cfgoff = off;
			bar[n].space = PCI_REG_ADDR_G(aa[i].pci_phys_hi);
			bar[n].prefetch = (aa[i].pci_phys_hi & PCI_PREFETCH_B)
			    != 0;
			bar[n].base = ((uint64_t)aa[i].pci_phys_mid << 32) |
			    aa[i].pci_phys_low;
			bar[n].size = ((uint64_t)aa[i].pci_size_hi << 32) |
			    aa[i].pci_size_low;
			n++;
			break;
		}
	}
	return (n);
}

#ifndef OBSD_USERTEST
static int
obsd_bars(dev_info_t *dip, struct obsd_bar *bar)
{
	pci_regspec_t *reg, *aa;
	uint_t nreg, naa;
	int n;

	if (ddi_prop_lookup_int_array(DDI_DEV_T_ANY, dip, DDI_PROP_DONTPASS,
	    "reg", (int **)&reg, &nreg) != DDI_PROP_SUCCESS)
		return (0);
	if (ddi_prop_lookup_int_array(DDI_DEV_T_ANY, dip, DDI_PROP_DONTPASS,
	    "assigned-addresses", (int **)&aa, &naa) != DDI_PROP_SUCCESS) {
		ddi_prop_free(reg);
		return (0);
	}
	n = obsd_bars_parse(reg, nreg * sizeof (int) / sizeof (pci_regspec_t),
	    aa, naa * sizeof (int) / sizeof (pci_regspec_t), bar, OBSD_NBAR);
	ddi_prop_free(aa);
	ddi_prop_free(reg);
	return (n);
}

/* pci_mapreg_info for the attached device: base/size of the BAR at reg. */
int
obsd_pci_bar(dev_info_t *dip, int cfgoff, bus_addr_t *basep,
    bus_size_t *sizep, int *flagsp)
{
	struct obsd_bar bar[OBSD_NBAR];
	int i, n = obsd_bars(dip, bar);

	for (i = 0; i < n; i++) {
		if (bar[i].cfgoff != cfgoff)
			continue;
		if (basep != NULL)
			*basep = bar[i].base;
		if (sizep != NULL)
			*sizep = bar[i].size;
		if (flagsp != NULL)
			*flagsp = bar[i].prefetch ?
			    BUS_SPACE_MAP_PREFETCHABLE : 0;
		return (0);
	}
	return (EINVAL);
}

/*
 * Every live mapping, so bus_space_unmap can find the access handle (or
 * the psm mapping) from the VA OpenBSD code hands back.
 */
struct obsd_map {
	struct obsd_map		*m_next;
	uintptr_t		m_va;
	size_t			m_size;
	ddi_acc_handle_t	m_acc;	/* NULL: psm_map_phys_new mapping */
};
static struct obsd_map *obsd_maps;
static kmutex_t obsd_maps_lock;		/* zeroed = valid adaptive mutex */

extern caddr_t psm_map_phys_new(paddr_t, size_t, int);
extern void psm_unmap_phys(caddr_t, size_t);

int
bus_space_map(bus_space_tag_t t, bus_addr_t pa, bus_size_t size, int flags,
    bus_space_handle_t *bshp)
{
	struct obsd_bar bar[OBSD_NBAR];
	ddi_device_acc_attr_t attr;
	struct obsd_map *m;
	caddr_t va = NULL;
	int i, n;

	if (t == NULL || size == 0)
		return (EINVAL);
	m = kmem_zalloc(sizeof (*m), KM_SLEEP);
	n = t->bs_dip != NULL ? obsd_bars(t->bs_dip, bar) : 0;
	for (i = 0; i < n; i++) {
		if (bar[i].space == PCI_ADDR_IO || pa < bar[i].base ||
		    pa + size > bar[i].base + bar[i].size)
			continue;
		bzero(&attr, sizeof (attr));
		attr.devacc_attr_version = DDI_DEVICE_ATTR_V0;
		attr.devacc_attr_endian_flags = DDI_STRUCTURE_LE_ACC;
		attr.devacc_attr_dataorder =
		    (flags & BUS_SPACE_MAP_PREFETCHABLE) ?
		    DDI_MERGING_OK_ACC : DDI_STRICTORDER_ACC;
		if (ddi_regs_map_setup(t->bs_dip, bar[i].rnumber, &va,
		    (offset_t)(pa - bar[i].base), (offset_t)size, &attr,
		    &m->m_acc) != DDI_SUCCESS) {
			kmem_free(m, sizeof (*m));
			return (ENOMEM);
		}
		break;
	}
	if (va == NULL) {
		/* Not a BAR of ours: firmware tables, stolen RAM, VGA ROM. */
		va = psm_map_phys_new((paddr_t)pa, (size_t)size,
		    PROT_READ | PROT_WRITE);
		if (va == NULL) {
			kmem_free(m, sizeof (*m));
			return (ENOMEM);
		}
	}
	m->m_va = (uintptr_t)va;
	m->m_size = size;
	mutex_enter(&obsd_maps_lock);
	m->m_next = obsd_maps;
	obsd_maps = m;
	mutex_exit(&obsd_maps_lock);
	*bshp = (bus_space_handle_t)va;
	return (0);
}

void
bus_space_unmap(bus_space_tag_t t, bus_space_handle_t bsh, bus_size_t size)
{
	struct obsd_map **mp, *m = NULL;

	(void) t;
	mutex_enter(&obsd_maps_lock);
	for (mp = &obsd_maps; *mp != NULL; mp = &(*mp)->m_next) {
		if ((*mp)->m_va == bsh) {
			m = *mp;
			*mp = m->m_next;
			break;
		}
	}
	mutex_exit(&obsd_maps_lock);
	if (m == NULL) {
		cmn_err(CE_WARN, "bus_space_unmap: unknown handle %lx",
		    (ulong_t)bsh);
		return;
	}
	ASSERT(size == 0 || size == m->m_size);
	if (m->m_acc != NULL)
		ddi_regs_map_free(&m->m_acc);
	else
		psm_unmap_phys((caddr_t)m->m_va, m->m_size);
	kmem_free(m, sizeof (*m));
}

int
bus_space_subregion(bus_space_tag_t t, bus_space_handle_t bsh,
    bus_size_t off, bus_size_t size, bus_space_handle_t *nbshp)
{
	(void) t;
	(void) size;
	*nbshp = bsh + off;
	return (0);
}

/*
 * bus_space_mmap: the physical address of page off of a mapping, for a
 * user mmap fault (ttm). Memory space is identity-mapped by address, as on
 * OpenBSD amd64; the cache attribute is applied by the devmap that uses it.
 */
paddr_t
bus_space_mmap(bus_space_tag_t t, bus_addr_t addr, off_t off, int prot,
    int flags)
{
	(void) t; (void) prot; (void) flags;
	if (t != NULL && t->bs_io)
		return ((paddr_t)-1);
	return ((paddr_t)(addr + off));
}

/* pci_mapreg_map: the BAR at reg of pa's device, limited to maxsize. */
int
pci_mapreg_map(struct pci_attach_args *pa, int reg, pcireg_t type, int flags,
    bus_space_tag_t *tagp, bus_space_handle_t *handlep, bus_addr_t *basep,
    bus_size_t *sizep, bus_size_t maxsize)
{
	bus_space_tag_t tag;
	bus_space_handle_t h;
	bus_addr_t base;
	bus_size_t size;
	int bflags;

	if (PCI_MAPREG_TYPE(type) == PCI_MAPREG_TYPE_IO)
		return (EINVAL);	/* inteldrm maps only memory BARs */
	tag = pa->pa_memt;
	if (pci_mapreg_info(pa->pa_pc, pa->pa_tag, reg, type, &base, &size,
	    &bflags) != 0)
		return (EINVAL);
	if (maxsize != 0 && size > maxsize)
		size = maxsize;
	if (bus_space_map(tag, base, size, flags, &h) != 0)
		return (1);
	if (tagp != NULL)
		*tagp = tag;
	if (handlep != NULL)
		*handlep = h;
	if (basep != NULL)
		*basep = base;
	if (sizep != NULL)
		*sizep = size;
	return (0);
}

/* ------------------------------------------------------------ interrupts */
static int
obsd_intr_map(struct pci_attach_args *pa, pci_intr_handle_t *ihp, int type)
{
	dev_info_t *dip = pa->pa_pc->pc_dip;
	int types, actual;

	if (ddi_intr_get_supported_types(dip, &types) != DDI_SUCCESS ||
	    !(types & type))
		return (1);
	if (ddi_intr_alloc(dip, &ihp->ih, type, 0, 1, &actual,
	    DDI_INTR_ALLOC_STRICT) != DDI_SUCCESS || actual != 1)
		return (1);
	ihp->type = type;
	ihp->dip = dip;
	ihp->tag = pa->pa_tag;
	return (0);
}

int
pci_intr_map_msi(struct pci_attach_args *pa, pci_intr_handle_t *ihp)
{
	if (!(pa->pa_flags & PCI_FLAGS_MSI_ENABLED))
		return (1);
	return (obsd_intr_map(pa, ihp, DDI_INTR_TYPE_MSI));
}

int
pci_intr_map(struct pci_attach_args *pa, pci_intr_handle_t *ihp)
{
	return (obsd_intr_map(pa, ihp, DDI_INTR_TYPE_FIXED));
}

const char *
pci_intr_string(pci_chipset_tag_t pc, pci_intr_handle_t ih)
{
	(void) pc;
	return (ih.type == DDI_INTR_TYPE_MSI ? "msi" : "fixed");
}

/* One established handler: the OpenBSD function and its argument. */
struct obsd_intr {
	ddi_intr_handle_t	oi_ih;
	int			(*oi_func)(void *);
	void			*oi_arg;
};

static uint_t
obsd_intr_trampoline(caddr_t a1, caddr_t a2)
{
	struct obsd_intr *oi = (struct obsd_intr *)a1;

	(void) a2;
	return (oi->oi_func(oi->oi_arg) ? DDI_INTR_CLAIMED :
	    DDI_INTR_UNCLAIMED);
}

/*
 * The handler runs at the vector's DDI priority, a low-level interrupt
 * (pri < LOCK_LEVEL is refused below), so the adaptive MUTEX_DRIVER mutexes
 * mtx_init gives OpenBSD code are legal in it (obsd_kern.h, struct mutex).
 */
void *
pci_intr_establish(pci_chipset_tag_t pc, pci_intr_handle_t ih, int level,
    int (*func)(void *), void *arg, const char *what)
{
	struct obsd_intr *oi;
	uint_t pri;

	(void) pc; (void) level; (void) what;
	if (ddi_intr_get_pri(ih.ih, &pri) != DDI_SUCCESS ||
	    pri >= ddi_intr_get_hilevel_pri())
		return (NULL);
	oi = kmem_zalloc(sizeof (*oi), KM_SLEEP);
	oi->oi_ih = ih.ih;
	oi->oi_func = func;
	oi->oi_arg = arg;
	if (ddi_intr_add_handler(ih.ih, obsd_intr_trampoline, (caddr_t)oi,
	    NULL) != DDI_SUCCESS) {
		kmem_free(oi, sizeof (*oi));
		return (NULL);
	}
	if (ddi_intr_enable(ih.ih) != DDI_SUCCESS) {
		(void) ddi_intr_remove_handler(ih.ih);
		kmem_free(oi, sizeof (*oi));
		return (NULL);
	}
	return (oi);
}

void
pci_intr_disestablish(pci_chipset_tag_t pc, void *cookie)
{
	struct obsd_intr *oi = cookie;

	(void) pc;
	(void) ddi_intr_disable(oi->oi_ih);
	(void) ddi_intr_remove_handler(oi->oi_ih);
	(void) ddi_intr_free(oi->oi_ih);
	kmem_free(oi, sizeof (*oi));
}

/*
 * intr_barrier: wait until a running handler has returned. MAP: illumos
 * has no per-vector barrier; disabling and re-enabling the vector waits for
 * an in-progress handler (the DDI serialises them with the vector's lock).
 */
void
intr_barrier(void *cookie)
{
	struct obsd_intr *oi = cookie;

	if (oi == NULL)
		return;
	(void) ddi_intr_disable(oi->oi_ih);
	(void) ddi_intr_enable(oi->oi_ih);
}

/* ------------------------------------------------------- bus enumeration */
struct obsd_enum {
	int	(*match)(struct pci_attach_args *);
	struct pci_attach_args *out;
	struct pci_attach_args *tmpl;
	int	found;
};

static int
obsd_enum_walk(dev_info_t *dip, void *arg)
{
	struct obsd_enum *e = arg;
	struct pci_attach_args pa;
	pci_regspec_t *reg;
	uint_t nreg;
	int bus, dev, fn;

	if (ddi_prop_get_int(DDI_DEV_T_ANY, dip, DDI_PROP_DONTPASS,
	    "vendor-id", -1) == -1)
		return (DDI_WALK_CONTINUE);	/* not a PCI function */
	if (ddi_prop_lookup_int_array(DDI_DEV_T_ANY, dip, DDI_PROP_DONTPASS,
	    "reg", (int **)&reg, &nreg) != DDI_PROP_SUCCESS)
		return (DDI_WALK_CONTINUE);
	if (nreg * sizeof (int) < sizeof (pci_regspec_t)) {
		ddi_prop_free(reg);
		return (DDI_WALK_CONTINUE);
	}
	bus = PCI_REG_BUS_G(reg[0].pci_phys_hi);
	dev = PCI_REG_DEV_G(reg[0].pci_phys_hi);
	fn = PCI_REG_FUNC_G(reg[0].pci_phys_hi);
	ddi_prop_free(reg);
	if (e->tmpl != NULL)
		pa = *e->tmpl;
	else
		bzero(&pa, sizeof (pa));
	pa.pa_bus = bus;
	pa.pa_device = dev;
	pa.pa_function = fn;
	pa.pa_tag = pci_make_tag(pa.pa_pc, bus, dev, fn);
	pa.pa_id = pci_conf_read(pa.pa_pc, pa.pa_tag, PCI_ID_REG);
	pa.pa_class = pci_conf_read(pa.pa_pc, pa.pa_tag, PCI_CLASS_REG);
	if (e->match == NULL || e->match(&pa)) {
		if (e->out != NULL)
			*e->out = pa;
		e->found = 1;
		return (DDI_WALK_TERMINATE);
	}
	return (DDI_WALK_CONTINUE);
}

/* pci_find_device: the first PCI function anywhere that match() accepts;
 * the result is written over *pa (OpenBSD semantics). *pa is OUTPUT only:
 * OpenBSD's pci_find_device builds each candidate from the pci softc and
 * never reads *pa, and inteldrm's intel_pch_detect passes an uninitialised
 * stack struct. Copying it as a template carried a garbage pa_pc into
 * pci_conf_read, which panicked lixi (#gp in obsd_enum_walk, 2026-10-27,
 * the first card0 open). The candidates get a NULL chipset tag, so
 * pci_conf_read takes the mechanism-1 path every non-self read takes. */
int
pci_find_device(struct pci_attach_args *pa,
    int (*match)(struct pci_attach_args *))
{
	struct obsd_enum e = { match, pa, NULL, 0 };

	ddi_walk_devs(ddi_root_node(), obsd_enum_walk, &e);
	return (e.found);
}

/* pci_enumerate_bus: drm_linux.c's vga_get walks for VGA bridges to turn
 * off legacy VGA decode; MAP: every function in the tree, not one bus. */
int
pci_enumerate_bus(struct pci_softc *sc,
    int (*match)(struct pci_attach_args *), struct pci_attach_args *pap)
{
	struct obsd_enum e = { match, pap, NULL, 0 };

	(void) sc;
	ddi_walk_devs(ddi_root_node(), obsd_enum_walk, &e);
	return (e.found);
}
#endif /* !OBSD_USERTEST */
