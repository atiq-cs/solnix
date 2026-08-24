/*
 * amdgpu_psp.h - C3-amdgpu-d: the reduced PSP (Platform Security Processor)
 * state + command constants for Navi 12 (psp_v11_0).
 *
 * See psp.c for the bring-up sequence + the HARDWARE-GATED marking. This header
 * holds the softc-hung PSP state + the PSP GFX command ids the .hw_init issues.
 *
 * Crib provenance:
 *   - struct psp_context (reduced): Linux amdgpu_psp.h struct psp_context
 *   - the PSP GFX command ids: Linux psp_gfx_if.h enum psp_gfx_cmd_id
 */

#ifndef _AMDGPU_PSP_H_
#define _AMDGPU_PSP_H_

#include <sys/types.h>
#include "ttm_priv.h"		/* struct amdgpu_bo */

struct amdgpu_softc;

/* PSP GFX command ring size (crib: psp_v11_0 PSP_RING_SIZE, one page-ish). */
#define	PSP_RING_SIZE		0x10000		/* 64 KB */

/*
 * PSP GFX command ids (crib: psp_gfx_if.h enum psp_gfx_cmd_id). Only the two
 * the reduced bring-up issues are materialized; the fw_type is packed into the
 * high byte of the mailbox command word (psp_v11 convention).
 */
#define	PSP_GFX_CMD_LOAD_IP_FW	0x00000006u	/* GFX_CMD_ID_LOAD_IP_FW */
#define	PSP_GFX_CMD_CREATE_RING	0x00000001u	/* create the GFX ring */

/* the PSP response error mask (crib: psp response status high bits). */
#define	PSP_RESP_ERR_MASK	0x0000ffffu	/* nonzero low word == error */

/*
 * struct amdgpu_psp - the reduced psp_context. Holds the PSP GFX command ring
 * BO + its GPU address + the ready flag. Dropped (deferred): the sos/asd/ta
 * firmware sub-buffers, the tmr (trusted-memory-region) BO, the xgmi/ras/hdcp
 * trusted-application state -- none needed for the reduced authenticate-and-
 * load bring-up.
 */
struct amdgpu_psp {
	struct amdgpu_bo	*km_ring_bo;	/* PSP GFX command ring BO */
	uint64_t		km_ring_gpu_addr;
	struct amdgpu_bo	*fw_pri_bo;	/* sOS/sysdrv staging BO (fw_pri) */
	uint64_t		fw_pri_gpu_addr;
	boolean_t		initialized;
};

/* --- PSP bring-up (psp.c), all HARDWARE-GATED at runtime --- */
int	amdgpu_psp_hw_init(struct amdgpu_softc *);
void	amdgpu_psp_hw_fini(struct amdgpu_softc *);
int	amdgpu_psp_bootloader_load_sos(struct amdgpu_softc *, struct amdgpu_psp *);
int	amdgpu_psp_wait_sos(struct amdgpu_softc *);
int	amdgpu_psp_ring_create(struct amdgpu_softc *, struct amdgpu_psp *);
int	amdgpu_psp_load_fw(struct amdgpu_softc *, struct amdgpu_psp *,
	    uint64_t fw_gpu_addr, uint32_t fw_size, uint32_t fw_type);

#endif	/* _AMDGPU_PSP_H_ */
