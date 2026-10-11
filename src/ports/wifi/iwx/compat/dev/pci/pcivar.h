/*
 * OpenBSD <dev/pci/pcivar.h> -> illumos DDI PCI access.
 *
 * OpenBSD hands a driver a pci_attach_args carrying an opaque chipset tag
 * (pa_pc) and a device tag (pa_tag); config space is read with
 * pci_conf_read(pc, tag, off). illumos uses a ddi_acc_handle_t obtained from
 * pci_config_setup(dip, &handle) and pci_config_get32(handle, off).
 *
 * So pa_pc carries the dev_info_t and pa_tag the config-space access handle,
 * and pci_conf_read/write become thin wrappers. The shapes line up cleanly;
 * this is the least risky of the four big families.
 *
 * STATUS: types/macros REAL. Functions declared here, implemented in
 * iwx_pci.c. Interrupt setup is the part that does NOT line up -- OpenBSD's
 * pci_intr_map_msix/msi/legacy trio becomes ddi_intr_get_supported_types +
 * ddi_intr_alloc, which is a different control flow, so those are implemented
 * rather than macro-mapped and are individually commented.
 */
#ifndef _IWX_COMPAT_DEV_PCI_PCIVAR_H
#define _IWX_COMPAT_DEV_PCI_PCIVAR_H

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <machine/bus.h>

typedef uint32_t	pcireg_t;
typedef uint16_t	pci_product_id_t;
typedef uint16_t	pci_vendor_id_t;

/* OpenBSD's opaque chipset tag -> the dev_info_t. */
typedef dev_info_t	*pci_chipset_tag_t;
/* OpenBSD's per-device tag -> illumos config-space access handle. */
typedef ddi_acc_handle_t pcitag_t;

struct pci_attach_args {
	dev_info_t		*pa_dip;
	pci_chipset_tag_t	pa_pc;
	pcitag_t		pa_tag;
	pcireg_t		pa_id;		/* (product << 16) | vendor */
	bus_dma_tag_t		pa_dmat;
	bus_space_tag_t		pa_memt;
};

struct pci_matchid {
	pci_vendor_id_t		pm_vid;
	pci_product_id_t	pm_pid;
};

#define PCI_VENDOR(id)		((id) & 0xffff)
#define PCI_PRODUCT(id)		(((id) >> 16) & 0xffff)

/* illumos interrupt handles; the count is fixed because iwx asks for one. */
typedef struct iwx_pci_intr {
	ddi_intr_handle_t	*ih_table;
	int			ih_count;
	int			ih_type;	/* DDI_INTR_TYPE_MSIX/MSI/FIXED */
	uint_t			ih_pri;
} *pci_intr_handle_t;

extern pcireg_t pci_conf_read(pci_chipset_tag_t, pcitag_t, int);
extern void pci_conf_write(pci_chipset_tag_t, pcitag_t, int, pcireg_t);
extern int pci_get_capability(pci_chipset_tag_t, pcitag_t, int, int *,
    pcireg_t *);
extern pcireg_t pci_mapreg_type(pci_chipset_tag_t, pcitag_t, int);
extern int pci_mapreg_map(struct pci_attach_args *, int, pcireg_t, int,
    bus_space_tag_t *, bus_space_handle_t *, bus_addr_t *, bus_size_t *,
    bus_size_t);
extern int pci_matchbyid(struct pci_attach_args *, const struct pci_matchid *,
    int);
extern int pci_intr_map_msix(struct pci_attach_args *, int,
    pci_intr_handle_t *);
extern int pci_intr_map_msi(struct pci_attach_args *, pci_intr_handle_t *);
extern int pci_intr_map(struct pci_attach_args *, pci_intr_handle_t *);
extern const char *pci_intr_string(pci_chipset_tag_t, pci_intr_handle_t);
extern void *pci_intr_establish(pci_chipset_tag_t, pci_intr_handle_t, int,
    int (*)(void *), void *, const char *);

#endif /* _IWX_COMPAT_DEV_PCI_PCIVAR_H */
