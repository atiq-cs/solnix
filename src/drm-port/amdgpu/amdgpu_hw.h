/*
 * amdgpu_hw.h - C3-amdgpu-d: the per-IP-block .hw_init prototypes + shared
 * timeout constants. Every entry here is HARDWARE-GATED at runtime (it programs
 * live MMIO); see the per-file headers + the design doc's runtime checklist.
 *
 * The .hw_init chain the reduced power-up runs, in order (crib: amdgpu_device.c
 * amdgpu_device_ip_init .hw_init loop for the Navi 12 IP-block set):
 *   amdgpu_ucode_init   (firmware(9F) fetch -- amdgpu_ucode.c, OFF-HARDWARE ok)
 *   amdgpu_psp_hw_init  (authenticate + load every blob -- psp.c, GATED)
 *   amdgpu_gmc_hw_init  (gart_enable -- gmc_hw.c, GATED)
 *   amdgpu_gfx_hw_init  (RLC/ME/PFP/MEC load + GFX ring enable -- gfx_hw.c)
 *   amdgpu_sdma_hw_init (SDMA ucode + ring enable -- sdma_hw.c, GATED)
 */

#ifndef _AMDGPU_HW_H_
#define _AMDGPU_HW_H_

#include <sys/types.h>

struct amdgpu_softc;

/* shared live-register poll timeouts (microsecond steps; live-hw only). */
#define	GMC_HW_FLUSH_TIMEOUT_US		1000000		/* 1 s */
#define	GFX_HW_RLC_TIMEOUT_US		1000000
#define	SDMA_HW_TIMEOUT_US		1000000

/* --- the per-IP-block .hw_init entries (all HARDWARE-GATED) --- */
int	amdgpu_gmc_hw_init(struct amdgpu_softc *);
int	amdgpu_gfx_hw_init(struct amdgpu_softc *);
int	amdgpu_sdma_hw_init(struct amdgpu_softc *);

/* the aggregate reduced power-up chain (amdgpu_hw.c), wiring the above in
 * order after the C3-c software floor + the C3-d firmware fetch. */
int	amdgpu_hw_init(struct amdgpu_softc *);
void	amdgpu_hw_fini(struct amdgpu_softc *);

#endif	/* _AMDGPU_HW_H_ */
