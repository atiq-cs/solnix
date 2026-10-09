/*
 * OpenBSD <dev/acpi/acpivar.h>, the subset drm_linux.c and inteldrm read:
 * the softc's table queue, FADT pointer and sleep state. illumos has its own
 * ACPI (acpica in the kernel); on solnix acpi_softc stays NULL until a
 * bridge to acpica's AcpiGetTable is written (PLANNED), and drm_linux.c's
 * acpi_get_table then returns AE_NOT_FOUND, which i915 handles (no VBT
 * from ACPI: it falls back to the OpRegion mailbox and the VBIOS copy).
 */
#ifndef _OBSD_COMPAT_DEV_ACPI_ACPIVAR_H
#define _OBSD_COMPAT_DEV_ACPI_ACPIVAR_H
#include <obsd_prelude.h>
#include <dev/acpi/acpireg.h>
struct acpi_q {
	SIMPLEQ_ENTRY(acpi_q)	q_next;
	int			q_id;
	void			*q_table;
	uint8_t			q_data[0];
};
typedef SIMPLEQ_HEAD(, acpi_q) acpi_qhead_t;
struct aml_node;
extern struct aml_node *acpi_find_pci(pci_chipset_tag_t, pcitag_t);
/* struct acpi_softc itself is in obsd_kern.h (inteldrm reads sc_state
 * without ACPI configured); these are the fields drm_linux.c adds. */
#endif
