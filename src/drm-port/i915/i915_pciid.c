/*
 * i915_pciid.c -- the illumos i915 device match, built from the UNMODIFIED
 * upstream id lists in openbsd-orig/include/drm/intel/pciids.h (MIT, Intel;
 * the same lists Linux ships).
 *
 * First target is Gen9 big-core (SKL/KBL/CFL/WHL/AML/CML), which is what the
 * X1's UHD 630 (8086:3e9b, CFL-H GT2) is. Second is Alder Lake-P (Gen12,
 * display 13), the X1E's Iris Xe (8086:46a6). OpenBSD builds every platform's
 * display and GT code into the one inteldrm object set, so the ADL-P paths
 * link already; they have never run here, and no driver alias for them is
 * shipped (ATTACH-PLAN.md HOLD). Other ids stay unmatched.
 *
 * The table uses pciids.h's own X-macro lists, so a re-fetched pciids.h adds
 * new ids in these families with no edit here. i915_pciid_device() walks the
 * table for the driver_aliases (pciex8086,<id>) list.
 *
 * Builds as a kernel object (-D_KERNEL) and as a userland self-check
 * (test/test_pciid.c, Makefile "test" target).
 */
#include <sys/types.h>
#include <sys/null.h>

/*
 * The minimum pci_device_id + PCI_DEVICE that pciids.h's INTEL_VGA_DEVICE()
 * expands to. Field names follow Linux's struct pci_device_id so the same
 * table can feed the linux-KPI pci layer later.
 */
#define	PCI_ANY_ID		(~0u)
#define	PCI_VENDOR_ID_INTEL	0x8086
#define	PCI_BASE_CLASS_DISPLAY	0x03
typedef unsigned long kernel_ulong_t;

struct pci_device_id {
	uint32_t vendor, device, subvendor, subdevice, class, class_mask;
	kernel_ulong_t driver_data;
};
#define	PCI_DEVICE(v, d) \
	.vendor = (v), .device = (d), \
	.subvendor = PCI_ANY_ID, .subdevice = PCI_ANY_ID

/* pciids.h defines INTEL_VGA_DEVICE only under _KERNEL. */
#ifndef _KERNEL
#define	_KERNEL
#define	I915_PCIID_UNDEF_KERNEL
#endif
#include <drm/intel/pciids.h>
#ifdef I915_PCIID_UNDEF_KERNEL
#undef _KERNEL
#endif

#include "i915_pciid.h"

static const struct i915_pciid_info skl_gt1 = { "skylake", 9, 1 };
static const struct i915_pciid_info skl_gt2 = { "skylake", 9, 2 };
static const struct i915_pciid_info skl_gt3 = { "skylake", 9, 3 };
static const struct i915_pciid_info skl_gt4 = { "skylake", 9, 4 };
static const struct i915_pciid_info kbl_gt1 = { "kabylake", 9, 1 };
static const struct i915_pciid_info kbl_gt2 = { "kabylake", 9, 2 };
static const struct i915_pciid_info kbl_gt3 = { "kabylake", 9, 3 };
static const struct i915_pciid_info cfl_gt1 = { "coffeelake", 9, 1 };
static const struct i915_pciid_info cfl_gt2 = { "coffeelake", 9, 2 };
static const struct i915_pciid_info cfl_gt3 = { "coffeelake", 9, 3 };
static const struct i915_pciid_info cml_gt1 = { "cometlake", 9, 1 };
static const struct i915_pciid_info cml_gt2 = { "cometlake", 9, 2 };
/* pciids.h lists ADL-P GT1 and GT2 ids in one list, so no GT tier (0). */
static const struct i915_pciid_info adl_p = { "alderlake_p", 12, 0 };

/*
 * Same id-list -> info pairing as the upstream i915_pci.c pciidlist[] for
 * these families (KBL GT4 and the WHL/AML variants reuse the GT2/GT3 infos
 * exactly as upstream does).
 */
static const struct pci_device_id i915_pciid_table[] = {
#ifndef I915_PCIID_SABOTAGE	/* negative control: drop the X1's list */
	INTEL_CFL_H_GT2_IDS(INTEL_VGA_DEVICE, &cfl_gt2),
#endif
	INTEL_SKL_GT1_IDS(INTEL_VGA_DEVICE, &skl_gt1),
	INTEL_SKL_GT2_IDS(INTEL_VGA_DEVICE, &skl_gt2),
	INTEL_SKL_GT3_IDS(INTEL_VGA_DEVICE, &skl_gt3),
	INTEL_SKL_GT4_IDS(INTEL_VGA_DEVICE, &skl_gt4),
	INTEL_KBL_GT1_IDS(INTEL_VGA_DEVICE, &kbl_gt1),
	INTEL_KBL_GT2_IDS(INTEL_VGA_DEVICE, &kbl_gt2),
	INTEL_KBL_GT3_IDS(INTEL_VGA_DEVICE, &kbl_gt3),
	INTEL_KBL_GT4_IDS(INTEL_VGA_DEVICE, &kbl_gt3),
	INTEL_AML_KBL_GT2_IDS(INTEL_VGA_DEVICE, &kbl_gt2),
	INTEL_CFL_S_GT1_IDS(INTEL_VGA_DEVICE, &cfl_gt1),
	INTEL_CFL_S_GT2_IDS(INTEL_VGA_DEVICE, &cfl_gt2),
	INTEL_CFL_H_GT1_IDS(INTEL_VGA_DEVICE, &cfl_gt1),
	INTEL_CFL_U_GT2_IDS(INTEL_VGA_DEVICE, &cfl_gt2),
	INTEL_CFL_U_GT3_IDS(INTEL_VGA_DEVICE, &cfl_gt3),
	INTEL_WHL_U_GT1_IDS(INTEL_VGA_DEVICE, &cfl_gt1),
	INTEL_WHL_U_GT2_IDS(INTEL_VGA_DEVICE, &cfl_gt2),
	INTEL_AML_CFL_GT2_IDS(INTEL_VGA_DEVICE, &cfl_gt2),
	INTEL_WHL_U_GT3_IDS(INTEL_VGA_DEVICE, &cfl_gt3),
	INTEL_CML_GT1_IDS(INTEL_VGA_DEVICE, &cml_gt1),
	INTEL_CML_GT2_IDS(INTEL_VGA_DEVICE, &cml_gt2),
	INTEL_CML_U_GT1_IDS(INTEL_VGA_DEVICE, &cml_gt1),
	INTEL_CML_U_GT2_IDS(INTEL_VGA_DEVICE, &cml_gt2),
#ifndef I915_PCIID_SABOTAGE_ADLP	/* negative control: drop the X1E's list */
	INTEL_ADLP_IDS(INTEL_VGA_DEVICE, &adl_p),
#endif
	{ 0 }
};

/*
 * Match on vendor, device and display class (INTEL_VGA_DEVICE sets
 * class = 0x03 << 16, class_mask = 0xff << 16). class is the 24-bit PCI
 * class code. Returns NULL when the device is not a first-target GPU.
 */
const struct i915_pciid_info *
i915_pciid_match(uint16_t vendor, uint16_t device, uint32_t class)
{
	const struct pci_device_id *id;

	for (id = i915_pciid_table; id->vendor != 0; id++) {
		if (id->vendor == vendor && id->device == device &&
		    (class & id->class_mask) == id->class)
			return ((const struct i915_pciid_info *)id->driver_data);
	}
	return (NULL);
}

unsigned int
i915_pciid_count(void)
{
	return (sizeof (i915_pciid_table) / sizeof (i915_pciid_table[0]) - 1);
}

uint16_t
i915_pciid_device(unsigned int i)
{
	return (i < i915_pciid_count() ? i915_pciid_table[i].device : 0);
}
