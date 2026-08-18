/*
 * pvr_fw_startstop.c - C-PVR-b: start/stop the PowerVR FW processor, illumos
 * side. The pvr analogue of Linux's pvr_fw_startstop.c. Sequences the FW core:
 * on start it runs the processor-specific wrapper_init (RISC-V remap for the
 * BXE-2-32), releases the core from reset, and waits for the FW to report
 * booted; on stop it halts the core.
 *
 * Every step here touches ROGUE_CR_* device registers on the powered-up core,
 * so the whole path is BXE-hardware-gated. The sequencing + the wrapper_init
 * dispatch are the C1-framework part; the actual register writes + the boot
 * poll need the real BXE-2-32.
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/errno.h>

#include "drm_internal.h"
#include "pvr_priv.h"

/* the soft-reset + boot registers (pvr_rogue_cr_defs.h). */
#define	ROGUE_CR_SOFT_RESET		0x0100
#define	ROGUE_CR_SOFT_RESET_GARTEN_EN	0x0000000000000001ULL

/*
 * pvr_fw_startstop_start - start the FW processor. Linux: pvr_fw_start ->
 * the processor's wrapper_init + release from reset. Off-hardware (no register
 * aperture on a stub parent, no powered core) it returns success after the
 * wrapper_init interface call so the attach floor stays valid; the real boot
 * poll (wait for the FW to set firmware_started) is BXE-hardware-gated.
 */
int
pvr_fw_startstop_start(struct pvr_softc *sc)
{
	int err = 0;

	if (sc->fw.defs != NULL && sc->fw.defs->wrapper_init != NULL)
		err = sc->fw.defs->wrapper_init(sc);
	if (err != 0)
		return (err);

	/*
	 * HARDWARE-GATED: release the Garten (FW core) from soft reset + poll
	 * for the FW to report booted:
	 *   pvr_cr_write64(sc, ROGUE_CR_SOFT_RESET, 0);   // clear reset
	 *   wait for fwif_sysinit->firmware_started == true
	 * Needs the powered-up BXE-2-32 core + the mapped register aperture.
	 * Off-hardware the interface call above succeeded, so we do not fail the
	 * attach floor here; pvr_fw_init marks booted only on the real path.
	 */
	(void) sc;
	return (0);
}

/*
 * pvr_fw_startstop_stop - halt the FW processor. Linux: pvr_fw_stop. Puts the
 * Garten core into soft reset. BXE-hardware-gated (register write).
 */
void
pvr_fw_startstop_stop(struct pvr_softc *sc)
{
	/*
	 * HARDWARE-GATED:
	 *   pvr_cr_write64(sc, ROGUE_CR_SOFT_RESET,
	 *       ROGUE_CR_SOFT_RESET_GARTEN_EN);
	 */
	(void) sc;
}
