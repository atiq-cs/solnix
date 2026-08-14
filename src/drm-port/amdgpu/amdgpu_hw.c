/*
 * amdgpu_hw.c - C3-amdgpu-d: the reduced amdgpu power-up chain (the .hw_init
 * loop), illumos side.
 *
 * ============ COMPILES; the power-up is HARDWARE-GATED end to end ===========
 *
 * Runs the reduced amdgpu_device_ip_init .hw_init sequence in the crib order
 * (crib: amdgpu_device.c amdgpu_device_ip_init + amdgpu_nv.c nv_set_ip_blocks
 * for the Navi 12 block set):
 *
 *   1. amdgpu_ucode_init   firmware(9F) fetch of navi12_*.bin  (OFF-HARDWARE
 *                          ok, needs the solnix firmware package installed)
 *   2. amdgpu_psp_hw_init  PSP authenticate + load every blob  (GATED)
 *   3. amdgpu_gmc_hw_init  gart_enable (VM page-table base)    (GATED)
 *   4. amdgpu_gfx_hw_init  RLC/CP load + GFX ring enable       (GATED)
 *   5. amdgpu_sdma_hw_init SDMA ucode + ring enable            (GATED)
 *
 * Every step past (1) programs live MMIO + polls a status the silicon writes,
 * so off-hardware the chain stops at the first live poll (PSP sOS never reports
 * running). That is the CORRECT compile-phase behaviour: it is wired + it
 * compiles, and it fails cleanly without a GPU (the caller treats a hw_init
 * failure as non-fatal -- the C3-c software floor stays valid). On a real V520
 * the same chain brings the GPU up; the runtime checklist in the design doc
 * lists each live gate in order.
 *
 * Crib provenance: the .hw_init order is amdgpu_device_ip_init; each step's
 * register work is cribbed in its own file (amdgpu_ucode.c / psp.c / gmc_hw.c /
 * gfx_hw.c / sdma_hw.c). NO Linux/NetBSD .c is lifted.
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/cmn_err.h>

#include "amdgpu_priv.h"
#include "ttm_priv.h"
#include "amdgpu_ip.h"
#include "amdgpu_ucode.h"
#include "amdgpu_psp.h"
#include "amdgpu_hw.h"

/*
 * amdgpu_hw_init - the reduced power-up. Fetch firmware, then run each IP
 * block's .hw_init. Returns DDI_SUCCESS only if the whole chain brought the
 * GPU up (never off-hardware). A failure at any live gate returns the failing
 * step's status; the attach path treats that as non-fatal.
 */
int
amdgpu_hw_init(struct amdgpu_softc *sc)
{
	int r;

	if (sc->ip == NULL || !sc->ip->initialized)
		return (DDI_FAILURE);		/* need the C3-c floor */

	/* 1. firmware fetch (OFF-HARDWARE; needs the firmware package). */
	r = amdgpu_ucode_init(sc);
	if (r != DDI_SUCCESS) {
		cmn_err(CE_CONT, "?amdgpu: hw_init: firmware not available; "
		    "power-up deferred to a firmware-equipped host\n");
		return (r);
	}

	/* 2. PSP: authenticate + load every blob. HARDWARE-GATED. */
	r = amdgpu_psp_hw_init(sc);
	if (r != DDI_SUCCESS)
		goto gated;

	/* 3. GMC gart_enable. HARDWARE-GATED. */
	r = amdgpu_gmc_hw_init(sc);
	if (r != DDI_SUCCESS)
		goto gated;

	/* 4. GFX RLC/CP + ring enable. HARDWARE-GATED. */
	r = amdgpu_gfx_hw_init(sc);
	if (r != DDI_SUCCESS)
		goto gated;

	/* 5. SDMA ucode + ring enable. HARDWARE-GATED. */
	r = amdgpu_sdma_hw_init(sc);
	if (r != DDI_SUCCESS)
		goto gated;

	cmn_err(CE_CONT, "?amdgpu: hw_init: GPU powered up (PSP+GMC+GFX+SDMA)\n");
	return (DDI_SUCCESS);

gated:
	cmn_err(CE_CONT, "?amdgpu: hw_init stopped at a hardware gate "
	    "(expected without a powered V520); software floor intact\n");
	return (r);
}

void
amdgpu_hw_fini(struct amdgpu_softc *sc)
{
	if (sc == NULL)
		return;
	amdgpu_psp_hw_fini(sc);
	amdgpu_ucode_fini(sc);
}
