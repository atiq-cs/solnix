/*
 * OpenBSD <dev/acpi/dsdt.h>: the AML interpreter entry points drm_linux.c
 * calls for acpi_evaluate_object/acpi_get_handle. DECL; PLANNED as a bridge
 * to illumos acpica (AcpiGetHandle/AcpiEvaluateObject). Never reached while
 * acpi_softc is NULL.
 */
#ifndef _OBSD_COMPAT_DEV_ACPI_DSDT_H
#define _OBSD_COMPAT_DEV_ACPI_DSDT_H
#include <obsd_prelude.h>
#include <dev/acpi/amltypes.h>
struct acpi_softc;
extern struct aml_node *aml_searchname(struct aml_node *, const void *);
extern const char *aml_nodename(struct aml_node *);
extern int aml_evalnode(struct acpi_softc *, struct aml_node *, int,
    struct aml_value *, struct aml_value *);
extern void aml_freevalue(struct aml_value *);
extern void aml_register_notify(struct aml_node *, const char *,
    int (*)(struct aml_node *, int, void *), void *, int);
#endif
