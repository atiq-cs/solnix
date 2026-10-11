/*
 * obsd_bus.h -- OpenBSD bus_space, bus_dma, PCI and i2c on illumos.
 *
 * bus_space: OpenBSD passes (tag, handle, offset). The handle here is the
 * mapped kernel VA of the BAR (as on OpenBSD amd64, where bus_space_handle_t
 * is the VA for memory space), and the tag carries the illumos
 * ddi_acc_handle_t that ddi_get32/ddi_put32 need. REAL for memory space.
 *
 * PCI: pci_chipset_tag_t carries the device's ddi_acc_handle_t from
 * pci_config_setup(9F); pcitag_t is OpenBSD's packed bus/dev/fn. Config
 * reads go through pci_config_get32 on that handle (DECL, obsd_kern.c); a
 * tag that is not the attached device (i915 reads the host bridge at
 * 0:0.0 for the MCHBAR and the ISA bridge for the PCH id) goes through
 * the illumos pci_getl_func/pci_putl_func hooks that the PCI nexus exports.
 *
 * bus_dma: PLANNED, the shape is src/ports/wifi/iwx/compat/machine/bus.h
 * (one map = ddi_dma_handle_t + ddi_acc_handle_t + the cookie list).
 */
#ifndef _OBSD_BUS_H
#define _OBSD_BUS_H

typedef uint64_t	bus_addr_t;
typedef uint64_t	bus_size_t;

struct obsd_bus_space {
	ddi_acc_handle_t	bs_acc;		/* NULL: direct volatile access */
	int			bs_io;		/* 1: x86 I/O port space */
	dev_info_t		*bs_dip;	/* device whose BARs it maps */
};
typedef struct obsd_bus_space	*bus_space_tag_t;
typedef uintptr_t		bus_space_handle_t;

#define BUS_SPACE_MAP_CACHEABLE		0x0001
#define BUS_SPACE_MAP_LINEAR		0x0002
#define BUS_SPACE_MAP_PREFETCHABLE	0x0008
#define BUS_SPACE_BARRIER_READ		0x01
#define BUS_SPACE_BARRIER_WRITE		0x02

/* Memory-space accessors (REAL: a volatile access to the mapped BAR, which
 * is what ddi_get32 does for a DDI_STRUCTURE_LE_ACC + DDI_STRICTORDER_ACC
 * mapping on x86, without the handle lookup). */
#define bus_space_read_1(t, h, o)	(*(volatile uint8_t *)((h) + (o)))
#define bus_space_read_2(t, h, o)	(*(volatile uint16_t *)((h) + (o)))
#define bus_space_read_4(t, h, o)	(*(volatile uint32_t *)((h) + (o)))
#define bus_space_read_8(t, h, o)	(*(volatile uint64_t *)((h) + (o)))
#define bus_space_write_1(t, h, o, v)	(*(volatile uint8_t *)((h) + (o)) = (v))
#define bus_space_write_2(t, h, o, v)	(*(volatile uint16_t *)((h) + (o)) = (v))
#define bus_space_write_4(t, h, o, v)	(*(volatile uint32_t *)((h) + (o)) = (v))
#define bus_space_write_8(t, h, o, v)	(*(volatile uint64_t *)((h) + (o)) = (v))
#define bus_space_barrier(t, h, o, l, f) __asm volatile("mfence" ::: "memory")
#define bus_space_vaddr(t, h)		((void *)(h))
/* DECL: ddi_regs_map_setup on the BAR whose physical base is addr. */
extern int bus_space_map(bus_space_tag_t, bus_addr_t, bus_size_t, int,
    bus_space_handle_t *);
extern void bus_space_unmap(bus_space_tag_t, bus_space_handle_t, bus_size_t);
extern paddr_t bus_space_mmap(bus_space_tag_t, bus_addr_t, off_t, int, int);
extern int bus_space_subregion(bus_space_tag_t, bus_space_handle_t,
    bus_size_t, bus_size_t, bus_space_handle_t *);

/* ---- bus_dma (types REAL; functions PLANNED) ---- */
typedef struct bus_dma_segment {
	bus_addr_t	ds_addr;
	bus_size_t	ds_len;
	vaddr_t		_ds_va;
} bus_dma_segment_t;
struct bus_dma_tag {
	dev_info_t	*dt_dip;
};
typedef struct bus_dma_tag	*bus_dma_tag_t;
struct bus_dmamap {
	ddi_dma_handle_t	_dm_hdl;
	ddi_acc_handle_t	_dm_acc;
	bus_size_t		dm_mapsize;
	int			dm_nsegs;
	bus_dma_segment_t	dm_segs[1];
};
typedef struct bus_dmamap	*bus_dmamap_t;
#define BUS_DMA_WAITOK		0x0000
#define BUS_DMA_NOWAIT		0x0001
#define BUS_DMA_ALLOCNOW	0x0002
#define BUS_DMA_COHERENT	0x0004
#define BUS_DMA_NOCACHE		0x0008
#define BUS_DMA_BUS1		0x0010
#define BUS_DMA_READ		0x0020
#define BUS_DMA_WRITE		0x0040
#define BUS_DMA_64BIT		0x0080
#define BUS_DMA_ZERO		0x0100
#define BUS_DMA_FIXED		0x0200
#define BUS_DMASYNC_PREREAD	0x01
#define BUS_DMASYNC_POSTREAD	0x02
#define BUS_DMASYNC_PREWRITE	0x04
#define BUS_DMASYNC_POSTWRITE	0x08
extern int bus_dmamap_create(bus_dma_tag_t, bus_size_t, int, bus_size_t,
    bus_size_t, int, bus_dmamap_t *);
extern void bus_dmamap_destroy(bus_dma_tag_t, bus_dmamap_t);
extern int bus_dmamap_load(bus_dma_tag_t, bus_dmamap_t, void *, bus_size_t,
    struct proc *, int);
extern int bus_dmamap_load_raw(bus_dma_tag_t, bus_dmamap_t,
    bus_dma_segment_t *, int, bus_size_t, int);
extern void bus_dmamap_unload(bus_dma_tag_t, bus_dmamap_t);
extern void bus_dmamap_sync(bus_dma_tag_t, bus_dmamap_t, bus_addr_t,
    bus_size_t, int);
extern int bus_dmamem_alloc(bus_dma_tag_t, bus_size_t, bus_size_t, bus_size_t,
    bus_dma_segment_t *, int, int *, int);
extern void bus_dmamem_free(bus_dma_tag_t, bus_dma_segment_t *, int);
extern int bus_dmamem_map(bus_dma_tag_t, bus_dma_segment_t *, int, size_t,
    caddr_t *, int);
extern void bus_dmamem_unmap(bus_dma_tag_t, caddr_t, size_t);
extern paddr_t bus_dmamem_mmap(bus_dma_tag_t, bus_dma_segment_t *, int, off_t,
    int, int);

/* ---- PCI ---- */
typedef uint32_t	pcireg_t;
typedef uint32_t	pcitag_t;	/* OpenBSD amd64: bus<<16|dev<<11|fn<<8 */
struct obsd_pci_chipset {
	dev_info_t		*pc_dip;
	ddi_acc_handle_t	pc_cfg;		/* pci_config_setup(9F) */
	pcitag_t		pc_self;	/* tag of pc_dip */
};
typedef struct obsd_pci_chipset	*pci_chipset_tag_t;
typedef struct {
	pcitag_t	tag;
	int		line, pin;
	ddi_intr_handle_t ih;
	int		type;		/* DDI_INTR_TYPE_MSI or _FIXED */
	dev_info_t	*dip;
} pci_intr_handle_t;
struct extent;
struct pci_attach_args {
	bus_space_tag_t	pa_iot;
	bus_space_tag_t	pa_memt;
	bus_dma_tag_t	pa_dmat;
	pci_chipset_tag_t pa_pc;
	int		pa_flags;
	struct extent	*pa_ioex;
	struct extent	*pa_memex;
	struct extent	*pa_pmemex;
	struct extent	*pa_busex;
	u_int		pa_domain;
	u_int		pa_bus;
	u_int		pa_device;
	u_int		pa_function;
	pcitag_t	pa_tag;
	pcireg_t	pa_id, pa_class;
	pcitag_t	*pa_bridgetag;
	pci_intr_handle_t *pa_bridgeih;
	int		pa_intrswiz;
	pcitag_t	pa_intrtag;
	int		pa_intrpin;
	int		pa_intrline;
};
#define PCI_FLAGS_IO_ENABLED	0x01
#define PCI_FLAGS_MEM_ENABLED	0x02
#define PCI_FLAGS_MSI_ENABLED	0x20
#define PCI_FLAGS_MSIVEC_ENABLED 0x40
struct pci_dev;
struct pci_softc {
	struct device		sc_dev;
	bus_space_tag_t		sc_iot, sc_memt;
	bus_dma_tag_t		sc_dmat;
	pci_chipset_tag_t	sc_pc;
	int			sc_flags;
	struct extent		*sc_ioex, *sc_memex, *sc_pmemex, *sc_busex;
	LIST_HEAD(, pci_dev)	sc_devs;
	int			sc_domain, sc_bus, sc_maxndevs;
	pcitag_t		*sc_bridgetag;
	pci_intr_handle_t	*sc_bridgeih;
	u_int			sc_intrswiz;
	pcitag_t		sc_intrtag;
};
extern int pci_enumerate_bus(struct pci_softc *,
    int (*)(struct pci_attach_args *), struct pci_attach_args *);
struct pci_matchid {
	uint16_t	pm_vid;
	uint16_t	pm_pid;
};
extern pcitag_t pci_make_tag(pci_chipset_tag_t, int, int, int);
extern void pci_decompose_tag(pci_chipset_tag_t, pcitag_t, int *, int *,
    int *);
extern pcireg_t pci_conf_read(pci_chipset_tag_t, pcitag_t, int);
extern void pci_conf_write(pci_chipset_tag_t, pcitag_t, int, pcireg_t);
extern int pci_get_capability(pci_chipset_tag_t, pcitag_t, int, int *,
    pcireg_t *);
extern int pci_get_ext_capability(pci_chipset_tag_t, pcitag_t, int, int *,
    pcireg_t *);
extern pcireg_t pci_mapreg_type(pci_chipset_tag_t, pcitag_t, int);
extern int pci_mapreg_info(pci_chipset_tag_t, pcitag_t, int, pcireg_t,
    bus_addr_t *, bus_size_t *, int *);
extern int pci_mapreg_map(struct pci_attach_args *, int, pcireg_t, int,
    bus_space_tag_t *, bus_space_handle_t *, bus_addr_t *, bus_size_t *,
    bus_size_t);
extern int pci_find_device(struct pci_attach_args *,
    int (*)(struct pci_attach_args *));
extern int pci_matchbyid(struct pci_attach_args *, const struct pci_matchid *,
    int);
extern int pci_intr_map(struct pci_attach_args *, pci_intr_handle_t *);
extern int pci_intr_map_msi(struct pci_attach_args *, pci_intr_handle_t *);
extern const char *pci_intr_string(pci_chipset_tag_t, pci_intr_handle_t);
extern void *pci_intr_establish(pci_chipset_tag_t, pci_intr_handle_t, int,
    int (*)(void *), void *, const char *);
extern void pci_intr_disestablish(pci_chipset_tag_t, void *);
extern int pci_set_powerstate(pci_chipset_tag_t, pcitag_t, int);
/* obsd_bus.c: a BAR of an attached illumos device, from its
 * "assigned-addresses" property (no config-space writes). */
extern int obsd_pci_bar(dev_info_t *, int, bus_addr_t *, bus_size_t *,
    int *);
extern int pci_get_powerstate(pci_chipset_tag_t, pcitag_t);

/* PCI config registers and decoders (REAL: the PCI spec values, with the
 * OpenBSD names used by drm's linux/pci.h). */
#define PCI_ID_REG			0x00
#define PCI_COMMAND_STATUS_REG		0x04
#define PCI_CLASS_REG			0x08
#define PCI_BHLC_REG			0x0c
#define PCI_MAPREG_START		0x10
#define PCI_MAPREG_END			0x28
#define PCI_SUBSYS_ID_REG		0x2c
#define PCI_ROM_REG			0x30
#define PCI_CAPLISTPTR_REG		0x34
#define PCI_INTERRUPT_REG		0x3c
#define PCI_VENDOR_SHIFT		0
#define PCI_VENDOR_MASK			0xffff
#define PCI_VENDOR(id)	(((id) >> PCI_VENDOR_SHIFT) & PCI_VENDOR_MASK)
#define PCI_PRODUCT_SHIFT		16
#define PCI_PRODUCT_MASK		0xffff
#define PCI_PRODUCT(id)	(((id) >> PCI_PRODUCT_SHIFT) & PCI_PRODUCT_MASK)
#define PCI_ID_CODE(vid, pid)	\
	((((vid) & PCI_VENDOR_MASK) << PCI_VENDOR_SHIFT) | \
	(((pid) & PCI_PRODUCT_MASK) << PCI_PRODUCT_SHIFT))
#define PCI_CLASS_SHIFT			24
#define PCI_CLASS_MASK			0xff
#define PCI_CLASS(cr)	(((cr) >> PCI_CLASS_SHIFT) & PCI_CLASS_MASK)
#define PCI_SUBCLASS_SHIFT		16
#define PCI_SUBCLASS_MASK		0xff
#define PCI_SUBCLASS(cr) (((cr) >> PCI_SUBCLASS_SHIFT) & PCI_SUBCLASS_MASK)
#define PCI_INTERFACE_SHIFT		8
#define PCI_INTERFACE_MASK		0xff
#define PCI_INTERFACE(cr) (((cr) >> PCI_INTERFACE_SHIFT) & PCI_INTERFACE_MASK)
#define PCI_REVISION_SHIFT		0
#define PCI_REVISION_MASK		0xff
#define PCI_REVISION(cr) (((cr) >> PCI_REVISION_SHIFT) & PCI_REVISION_MASK)
#define PCI_HDRTYPE_SHIFT		16
#define PCI_HDRTYPE_MASK		0xff
#define PCI_HDRTYPE(bhlcr) (((bhlcr) >> PCI_HDRTYPE_SHIFT) & PCI_HDRTYPE_MASK)
#define PCI_HDRTYPE_TYPE(bhlcr)		(PCI_HDRTYPE(bhlcr) & 0x7f)
#define PCI_COMMAND_IO_ENABLE		0x00000001
#define PCI_COMMAND_MEM_ENABLE		0x00000002
#define PCI_COMMAND_MASTER_ENABLE	0x00000004
#define PCI_CLASS_DISPLAY		0x03
#define PCI_CLASS_BRIDGE		0x06
#define PCI_SUBCLASS_DISPLAY_VGA	0x00
#define PCI_SUBCLASS_DISPLAY_MISC	0x80
#define PCI_SUBCLASS_BRIDGE_HOST	0x00
#define PCI_SUBCLASS_BRIDGE_ISA		0x01
#define PCI_MAPREG_TYPE_MEM		0x00000000
#define PCI_MAPREG_TYPE_IO		0x00000001
#define PCI_MAPREG_TYPE(mr)		((mr) & PCI_MAPREG_TYPE_IO)
#define PCI_MAPREG_MEM_TYPE_32BIT	0x00000000
#define PCI_MAPREG_MEM_TYPE_32BIT_1M	0x00000002
#define PCI_MAPREG_MEM_TYPE_64BIT	0x00000004
#define PCI_MAPREG_MEM_TYPE(mr)		((mr) & 0x00000006)
#define PCI_MAPREG_MEM_PREFETCHABLE(mr)	(((mr) & 0x00000008) != 0)
#define PCI_MAPREG_MEM_ADDR_MASK	0xfffffff0
#define PCI_MAPREG_ROM_ENABLE		0x00000001
#define PCI_CAP_PWRMGMT			0x01
#define PCI_CAP_AGP			0x02
#define PCI_CAP_VENDSPEC		0x09
#define PCI_CAP_PCIEXPRESS		0x10
#define PCI_CAP_MSI			0x05
#define PCI_PMCSR			0x04
#define PCI_PMCSR_STATE_MASK		0x0003
#define PCI_PMCSR_STATE_D0		0x0000
#define PCI_PMCSR_STATE_D3		0x0003
#define PCI_PCIE_XCAP			0x00
#define PCI_PCIE_XCAP_VER(x)		(((x) >> 16) & 0x0f)
#define PCI_PCIE_XCAP_TYPE(x)		(((x) >> 20) & 0x0f)
#define PCI_PCIE_XCAP_TYPE_PCIE_DEV	0x0
#define PCI_PCIE_XCAP_TYPE_UP		0x5
#define PCI_PCIE_XCAP_TYPE_DOWN		0x6
#define PCI_PCIE_DCAP			0x04
#define PCI_PCIE_DCSR			0x08
#define PCI_PCIE_DCSR_MPS		0x00007000
#define PCI_PCIE_DCSR_ENA_NO_SNOOP	0x00000800
#define PCI_PCIE_LCAP			0x0c
#define PCI_PCIE_LCSR			0x10
#define PCI_PCIE_LCSR_ASPM_L0S		0x00000001
#define PCI_PCIE_LCSR_ASPM_L1		0x00000002
#define PCI_PCIE_DCSR2			0x28
#define PCI_PCIE_LCAP2			0x2c
#define PCI_PCIE_LCSR2			0x30
#define PCI_PCIE_LCSR2_TLS		0x0000000f
#define PCI_PCIE_LCSR2_TLS_2_5		0x00000001
#define PCI_PCIE_LCSR2_TLS_5		0x00000002
#define PCI_PCIE_LCSR2_TLS_8		0x00000003
#define PCI_PCIE_ECAP			0x100
#define PCI_PCIE_ECAP_ID(x)		(((x) & 0x0000ffff))
#define PCI_PCIE_ECAP_VER(x)		(((x) >> 16) & 0x0f)
#define PCI_PCIE_ECAP_NEXT(x)		(((x) >> 20) & 0xffc)
#define PPB_REG_BRIDGECONTROL		0x3c
#define PPB_BC_VGA_ENABLE		0x00080000
#define PCI_VENDOR_ATI			0x1002
#define PCI_VENDOR_AMD			0x1022
#define PCI_VENDOR_INTEL		0x8086
#define PCI_VENDOR_VIATECH		0x1106
#define PCI_VENDOR_RCC			0x1166
#define PCI_VENDOR_APPLE		0x106b
#define PCI_VENDOR_SONY			0x104d
#define PCI_VENDOR_DELL			0x1028
#define PCI_VENDOR_HP			0x103c
#define PCI_VENDOR_IBM			0x1014
#define PCI_VENDOR_ASUSTEK		0x1043

/* ---- i2c (types REAL shape of OpenBSD dev/i2c; the GMBUS and DP-AUX
 * adapters fill the ops; the iic_* front end is DECL) ---- */
typedef uint16_t i2c_addr_t;
typedef enum {
	I2C_OP_READ = 0,
	I2C_OP_READ_WITH_STOP = 1,
	I2C_OP_WRITE = 2,
	I2C_OP_WRITE_WITH_STOP = 3,
} i2c_op_t;
#define I2C_OP_READ_P(x)	(((int)(x) & 2) == 0)
#define I2C_OP_WRITE_P(x)	(!I2C_OP_READ_P(x))
#define I2C_OP_STOP_P(x)	(((int)(x) & 1) != 0)
#define I2C_F_WRITE		0x00
#define I2C_F_READ		0x01
#define I2C_F_LAST		0x02
#define I2C_F_STOP		0x04
#define I2C_F_POLL		0x08
typedef struct i2c_controller {
	void	*ic_cookie;
	int	(*ic_acquire_bus)(void *, int);
	void	(*ic_release_bus)(void *, int);
	int	(*ic_exec)(void *, i2c_op_t, i2c_addr_t, const void *, size_t,
		    void *, size_t, int);
	int	(*ic_send_start)(void *, int);
	int	(*ic_send_stop)(void *, int);
	int	(*ic_initiate_xfer)(void *, i2c_addr_t, int);
	int	(*ic_read_byte)(void *, uint8_t *, int);
	int	(*ic_write_byte)(void *, uint8_t, int);
	void	*(*ic_intr_establish)(void *, void *, int, int (*)(void *),
		    void *, const char *);
	void	(*ic_intr_disestablish)(void *, void *);
	const char *(*ic_intr_string)(void *, void *);
} *i2c_tag_t;
#define iic_acquire_bus(ic, flags) \
	(*(ic)->ic_acquire_bus)((ic)->ic_cookie, (flags))
#define iic_release_bus(ic, flags) \
	(*(ic)->ic_release_bus)((ic)->ic_cookie, (flags))
extern int iic_exec(i2c_tag_t, i2c_op_t, i2c_addr_t, const void *, size_t,
    void *, size_t, int);
#define I2C_BIT_SDA		0
#define I2C_BIT_SCL		1
#define I2C_BIT_OUTPUT		2
#define I2C_BIT_INPUT		3
#define I2C_NBITS		4
struct i2c_bitbang_ops {
	void		(*ibo_set_bits)(void *, uint32_t);
	void		(*ibo_set_dir)(void *, uint32_t);
	uint32_t	(*ibo_read_bits)(void *);
	uint32_t	ibo_bits[I2C_NBITS];
};
typedef const struct i2c_bitbang_ops *i2c_bitbang_ops_t;
extern int i2c_bitbang_send_start(void *, int, i2c_bitbang_ops_t);
extern int i2c_bitbang_send_stop(void *, int, i2c_bitbang_ops_t);
extern int i2c_bitbang_initiate_xfer(void *, i2c_addr_t, int,
    i2c_bitbang_ops_t);
extern int i2c_bitbang_read_byte(void *, uint8_t *, int, i2c_bitbang_ops_t);
extern int i2c_bitbang_write_byte(void *, uint8_t, int, i2c_bitbang_ops_t);

/* ---- AGP (types only; i915 Gen9 has no AGP aperture; agp_intel_gtt.c is
 * the Gen2-5 GMCH path, compiled but never reached on CFL) ---- */
struct agp_methods {
	void	(*bind_page)(void *, bus_addr_t, paddr_t, int);
	void	(*unbind_page)(void *, bus_addr_t);
	void	(*flush_tlb)(void *);
	int	(*enable)(void *, u_int32_t mode);
};
struct agp_softc {
	struct device		sc_dev;
	const struct agp_methods *sc_methods;
	void			*sc_chipc;
	bus_dma_tag_t		sc_dmat;
	bus_space_tag_t		sc_memt;
	pci_chipset_tag_t	sc_pc;
	pcitag_t		sc_pcitag;
	bus_addr_t		sc_apaddr;
	bus_size_t		sc_apsize;
	pcireg_t		sc_id;
	int			sc_capoff;
};
struct agp_info {
	u_int32_t	ai_mode;
	bus_addr_t	ai_aperture_base;
	bus_size_t	ai_aperture_size;
	vsize_t		ai_memory_allowed;
	vsize_t		ai_memory_used;
	u_int32_t	ai_devid;
};

/* ---- VGA / wsdisplay console glue (types only; the illumos console is
 * vgatext/gfxp_bitmap, never wsdisplay -- i915_driver.c's wsdisplay attach
 * is replaced by the illumos attach, not compiled through this) ---- */
struct vga_pci_bar {
	int		addr;
	u_int		mapped;
	pcireg_t	maptype;
	bus_addr_t	base;
	bus_size_t	size;
	bus_size_t	maxsize;
	bus_space_tag_t	bst;
	bus_space_handle_t bsh;
	int		flags;
	void		*vaddr;
};

#endif /* _OBSD_BUS_H */
