/*
 * OpenBSD -> illumos compatibility shim for the iwx (Intel AX2xx) driver.
 *
 * The vendored driver in openbsd-orig/ is left untouched; this header supplies
 * the OpenBSD kernel interfaces it calls. Measured call-site counts, which is
 * what determines how much of this file has to exist:
 *
 *   ieee80211_*     273   OpenBSD net80211 -> illumos net80211 (DIVERGED API)
 *   m_* (mbuf)      309   -> mblk_t
 *   if_* (ifnet)     97   -> GLDv3 mac_*
 *   bus_dmamap_*     50   -> ddi_dma_*
 *   task_/timeout_   69   -> ddi_taskq_* / timeout(9F)
 *
 * CORRECTION, measured: the five counts above are `grep -c` LINE counts with
 * UNANCHORED patterns, not call sites. `grep -c 'm_' if_iwx.c` is 309 and it
 * also matches vm_size, rm_sta_cmd, um_tbs, EM_GROUP, im_interval. Real surface:
 *
 *   ieee80211_*    287 occurrences, 76 distinct symbols, 48 functions called
 *   m_* (mbuf)     31 calls / 48 tokens / 12 distinct APIs   (not 309)
 *   if_* (ifnet)   3 function calls + ~70 struct-member reads (not 97)
 *   bus_*          56 calls, 12 distinct
 *   task_/timeout_ 32 calls, 8 distinct
 *
 * The mbuf hazard described at the end of this file is unchanged and real; only
 * its SIZE was overstated. STATUS.md has the full measurement and the 802.11
 * route decision (route b, chosen on evidence).
 *
 * STATUS: skeleton. The DMA, delay, register-access and lock layers below are
 * real; the mbuf and 802.11 layers are the hard part and are deliberately NOT
 * faked -- see the barrier note at the end of this file. Anything unimplemented
 * must fail to COMPILE rather than silently misbehave at runtime, because a
 * plausible-looking stub in a DMA or firmware path is far more expensive to
 * debug on hardware than a missing symbol is here.
 */

#ifndef _IWX_ILLUMOS_H
#define _IWX_ILLUMOS_H

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/stream.h>
#include <sys/mac_provider.h>
#include <sys/note.h>

/* ------------------------------------------------------------------ *
 * Byte order and register access.
 *
 * OpenBSD's bus_space_* carries a handle + offset. illumos ddi_get/put take a
 * mapped address, so the handle is kept in the softc and the offset added here.
 * ------------------------------------------------------------------ */
#define htole16(x)	LE_16(x)
#define htole32(x)	LE_32(x)
#define htole64(x)	LE_64(x)
#define letoh16(x)	LE_16(x)
#define letoh32(x)	LE_32(x)
#define letoh64(x)	LE_64(x)

/* ------------------------------------------------------------------ *
 * Delays and time.
 * ------------------------------------------------------------------ */
#define DELAY(us)		drv_usecwait(us)
#define delay_ms(ms)		drv_usecwait((ms) * 1000)
#define hz			drv_usectohz(1000000)

/* ------------------------------------------------------------------ *
 * Locking. OpenBSD splnet()/rw_* -> illumos mutex/rwlock.
 *
 * NOTE: OpenBSD's spl* model is a priority level, not a lock. Mapping it to a
 * mutex is only correct if every splnet() region in the driver is also a
 * critical section over the same data -- that must be checked per site, not
 * assumed. Sites that do not fit get an explicit per-site comment.
 * ------------------------------------------------------------------ */
typedef kmutex_t iwx_lock_t;
#define IWX_LOCK_INIT(l)	mutex_init(&(l), NULL, MUTEX_DRIVER, NULL)
#define IWX_LOCK(l)		mutex_enter(&(l))
#define IWX_UNLOCK(l)		mutex_exit(&(l))
#define IWX_LOCK_DESTROY(l)	mutex_destroy(&(l))
#define IWX_ASSERT_LOCKED(l)	ASSERT(MUTEX_HELD(&(l)))

/* ------------------------------------------------------------------ *
 * Memory.
 * ------------------------------------------------------------------ */
#define malloc_wait(sz)		kmem_zalloc((sz), KM_SLEEP)
#define malloc_nowait(sz)	kmem_zalloc((sz), KM_NOSLEEP)
#define free_sz(p, sz)		kmem_free((p), (sz))

/* ------------------------------------------------------------------ *
 * DMA. OpenBSD bus_dmamap_* -> illumos ddi_dma_*.
 *
 * The shapes differ enough that the driver's DMA call sites need a struct to
 * carry both the handle and the acc handle illumos requires.
 * ------------------------------------------------------------------ */
struct iwx_dma_info {
	ddi_dma_handle_t	dma_hdl;
	ddi_acc_handle_t	acc_hdl;
	ddi_dma_cookie_t	cookie;
	uint_t			ncookies;
	caddr_t			vaddr;
	uint64_t		paddr;
	size_t			size;
};

int iwx_dma_alloc(dev_info_t *dip, struct iwx_dma_info *dma, size_t size,
    uint_t align, boolean_t consistent);
void iwx_dma_free(struct iwx_dma_info *dma);

#define IWX_DMA_SYNC_PREWRITE(d) \
	(void) ddi_dma_sync((d)->dma_hdl, 0, (d)->size, DDI_DMA_SYNC_FORDEV)
#define IWX_DMA_SYNC_POSTREAD(d) \
	(void) ddi_dma_sync((d)->dma_hdl, 0, (d)->size, DDI_DMA_SYNC_FORKERNEL)

/* ------------------------------------------------------------------ *
 * Firmware loading. OpenBSD loadfirmware() reads /etc/firmware/<name>.
 *
 * The blob names are the OpenBSD ones (iwx-cc-a0-77, not
 * iwlwifi-cc-a0-77.ucode) -- pkgs/illumos/iwx-firmware.nix installs them under
 * these names precisely so this path needs no translation.
 * ------------------------------------------------------------------ */
#define IWX_FIRMWARE_DIR	"/etc/firmware"
int iwx_loadfirmware(const char *name, uint8_t **bufp, size_t *sizep);
void iwx_freefirmware(uint8_t *buf, size_t size);

/* ------------------------------------------------------------------ *
 * Taskq / timeout.
 * ------------------------------------------------------------------ */
struct iwx_task {
	ddi_taskq_t	*tq;
	void		(*fn)(void *);
	void		*arg;
};
struct iwx_timeout {
	timeout_id_t	id;
	void		(*fn)(void *);
	void		*arg;
	clock_t		ticks;
};

/* ==================================================================== *
 * THE BARRIER -- read before adding to this file.
 *
 * Two layers are NOT shimmed here, on purpose:
 *
 * 1. mbuf -> mblk_t (309 sites). OpenBSD mbufs and illumos mblk_t differ in
 *    ownership, chaining and cluster semantics. A macro-level #define mapping
 *    compiles and then corrupts packets under load, which is the single most
 *    expensive class of bug to chase on hardware that has no serial console.
 *    This needs a real translation layer with its own tests.
 *
 * 2. ieee80211_* (273 sites). illumos HAS net80211, but it is FreeBSD-derived
 *    and OpenBSD's has diverged: different node refcounting, different crypto
 *    plumbing, different state machine entry points. Two viable routes, and the
 *    choice should be MEASURED rather than argued:
 *      (a) adapt iwx's calls to illumos net80211  -- less code, more semantic risk
 *      (b) vendor OpenBSD's net80211 alongside    -- more code, far less risk
 *
 *    MEASURED AND DECIDED: route (b). Route (a) is refuted -- 53 of 76 distinct
 *    ieee80211_* symbols (70%) do not exist in illumos net80211 by name, 34 of
 *    the 48 CALLED functions are absent, and struct ieee80211_node shares ZERO
 *    member names between the two stacks (109 members ni_* vs 55 members in_*),
 *    so all 182 ni_* accesses break and it is not a rename. Only 17 of 56 ic_*
 *    field names exist. Where names DO match the signatures differ. Details and
 *    the route-(b) cost (24,665 lines, ~3x this shim work, weeks) in STATUS.md.
 *
 * Until both exist, this driver does not link, and that is the correct state:
 * a driver that half-works on a wifi-only laptop is worse than one that
 * visibly is not finished.
 *
 * PROGRESS: the mbuf layer of item 1 now EXISTS as iwx_mbuf.{h,c} + iwx_mlist.h
 * (73 unit checks, 11 negative controls, compiles as a kernel object), and the
 * compat layer took if_iwx.c from 364 errors to 30. It still does NOT link and
 * does NOT load. See STATUS.md for the exact claim ladder.
 * ==================================================================== */

#endif /* _IWX_ILLUMOS_H */
