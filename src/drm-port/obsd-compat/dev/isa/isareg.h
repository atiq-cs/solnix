/* OpenBSD <dev/isa/isareg.h>: legacy ISA hole access for the VGA option ROM
 * (intel_rom.c, intel_bios.c). PLANNED: map 0xc0000 with psm_map_phys. */
#ifndef _OBSD_COMPAT_DEV_ISA_ISAREG_H
#define _OBSD_COMPAT_DEV_ISA_ISAREG_H
#include <obsd_prelude.h>
#define VGA_BIOS_ADDR	0xc0000
#define VGA_BIOS_LEN	0x10000
extern void *obsd_isa_hole_vaddr(paddr_t);
#define ISA_HOLE_VADDR(p)	obsd_isa_hole_vaddr(p)
#endif
