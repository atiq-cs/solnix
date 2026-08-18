/*
 * pvr_ccb.c - C-PVR-b: PowerVR command control blocks (the FW command rings),
 * illumos side. The pvr analogue of Linux's pvr_ccb.c. PowerVR's FW does most
 * of the work; the kernel talks to it over these rings rather than register-
 * banging. This is what makes the pvr kernel driver more command-ring than
 * register-driver (vs C3-amdgpu's register-heavy IP bring-up).
 *
 * Two rings:
 *   - the kernel CCB (KCCB): the kernel enqueues commands FOR the FW (kick a
 *     render, flush the MMU, power transitions);
 *   - the firmware CCB (FWCCB): the FW enqueues commands FOR the kernel (job
 *     completion, free-list grow requests), drained by the FW IRQ handler.
 *
 * Each ring is a control struct (read/write offsets) + a command buffer, both
 * FW objects (GEM BOs mapped into the FW heap). The offsets + the doorbell kick
 * touch device registers; those are BXE-hardware-gated. The ring setup + the
 * enqueue bookkeeping are the C1-framework part.
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/errno.h>

#include "drm_internal.h"
#include "pvr_priv.h"

/* the KCCB control struct: producer/consumer offsets (pvr_rogue_fwif.h) */
struct pvr_ccb_ctl {
	uint32_t	write_offset;	/* kernel-owned producer */
	uint32_t	read_offset;	/* FW-owned consumer */
	uint32_t	wrap_mask;
	uint32_t	cmd_size;
};

/*
 * pvr_ccb_init - stand up a command ring. num_cmds_log2 sizes the ring;
 * cmd_size is the per-command byte size. Allocates the control + buffer FW
 * objects and initializes the offsets. Linux: pvr_ccb_init.
 */
int
pvr_ccb_init(struct pvr_softc *sc, struct pvr_ccb *ccb,
    uint32_t num_cmds_log2, uint32_t cmd_size)
{
	uint32_t num_cmds = 1u << num_cmds_log2;
	struct pvr_ccb_ctl *ctl;

	mutex_init(&ccb->lock, NULL, MUTEX_DRIVER, NULL);
	ccb->num_cmds = num_cmds;
	ccb->cmd_size = cmd_size;

	ccb->ctrl_obj = pvr_fw_object_create(sc, sizeof (struct pvr_ccb_ctl),
	    PVR_BO_FW_FLAGS_DEVICE_UNCACHED);
	ccb->ccb_obj = pvr_fw_object_create(sc, (size_t)num_cmds * cmd_size,
	    PVR_BO_FW_FLAGS_DEVICE_UNCACHED);
	if (ccb->ctrl_obj == NULL || ccb->ccb_obj == NULL) {
		pvr_ccb_fini(ccb);
		return (ENOMEM);
	}

	ccb->ctrl = pvr_gem_object_vmap(ccb->ctrl_obj->gem);
	ccb->ccb = pvr_gem_object_vmap(ccb->ccb_obj->gem);
	pvr_fw_object_get_fw_addr(ccb->ctrl_obj, &ccb->ctrl_fw_addr);
	pvr_fw_object_get_fw_addr(ccb->ccb_obj, &ccb->ccb_fw_addr);

	if (ccb->ctrl != NULL) {
		ctl = ccb->ctrl;
		ctl->write_offset = 0;
		ctl->read_offset = 0;
		ctl->wrap_mask = num_cmds - 1;
		ctl->cmd_size = cmd_size;
	}
	return (0);
}

void
pvr_ccb_fini(struct pvr_ccb *ccb)
{
	if (ccb->ccb_obj != NULL) {
		pvr_gem_object_vunmap(ccb->ccb_obj->gem);
		pvr_fw_object_destroy(NULL, ccb->ccb_obj);
		ccb->ccb_obj = NULL;
	}
	if (ccb->ctrl_obj != NULL) {
		pvr_gem_object_vunmap(ccb->ctrl_obj->gem);
		pvr_fw_object_destroy(NULL, ccb->ctrl_obj);
		ccb->ctrl_obj = NULL;
	}
	mutex_destroy(&ccb->lock);
}

/*
 * pvr_kccb_send_cmd - enqueue a command for the FW on the KCCB + kick the FW
 * doorbell. Writes the command at the producer offset, advances write_offset,
 * then kicks the FW via ROGUE_CR_MTS_SCHEDULE. The doorbell write is BXE-
 * hardware-gated; the ring bookkeeping is complete. Linux: pvr_kccb_send_cmd.
 */
int
pvr_kccb_send_cmd(struct pvr_softc *sc, const void *cmd, size_t cmd_size)
{
	struct pvr_ccb *ccb = &sc->kccb;
	struct pvr_ccb_ctl *ctl = ccb->ctrl;
	uint32_t next;

	if (ctl == NULL || ccb->ccb == NULL)
		return (ENXIO);	/* ring not backed (FW-heap-gated) */
	if (cmd_size > ccb->cmd_size)
		return (EINVAL);

	mutex_enter(&ccb->lock);
	next = (ctl->write_offset + 1) & ctl->wrap_mask;
	if (next == ctl->read_offset) {	/* ring full */
		mutex_exit(&ccb->lock);
		return (EAGAIN);
	}
	bcopy(cmd, (uint8_t *)ccb->ccb + (size_t)ctl->write_offset *
	    ccb->cmd_size, cmd_size);
	ctl->write_offset = next;
	mutex_exit(&ccb->lock);

	/*
	 * HARDWARE-GATED: kick the FW to consume the ring:
	 *   pvr_cr_write32(sc, ROGUE_CR_MTS_SCHEDULE,
	 *       ROGUE_CR_MTS_SCHEDULE_TASK_COUNTED);
	 * Needs the booted FW + real device registers.
	 */
	(void) sc;
	return (0);
}
