/*
 * bus_dmamap_load_mbuf: the one call that couples the DMA and mbuf layers.
 *
 * It is not in compat/machine/bus.h because it is the only bus_dma entry point
 * that has to know what an mblk_t is: it walks the b_cont chain and materialises
 * one ddi_dma cookie per segment into the OpenBSD-visible dm_segs[] view.
 *
 * DECLARED ONLY, deliberately. There is no definition anywhere in the tree yet,
 * so a link fails with this exact symbol name rather than succeeding against a
 * plausible stub. A DMA path that "works" but maps the wrong pages is the single
 * most expensive class of bug to debug on hardware, so it must not exist in a
 * form that can be mistaken for done.
 *
 * CONTRACT it must satisfy when written (three call sites: the RX refill at
 * if_iwx.c:4634 and the TX path at :6369 and :6382):
 *
 *   - Returns 0 on success, EFBIG if the chain needs more than the map's
 *     segment limit, another errno otherwise. EFBIG SPECIFICALLY: the TX caller
 *     treats it as "linearize and retry" and any other errno as fatal, so
 *     collapsing EFBIG into EINVAL turns a recoverable case into a dropped
 *     frame.
 *   - On success sets map->dm_nsegs and fills map->dm_segs[0..nsegs-1], because
 *     the driver reads dm_segs[0].ds_addr directly to build TX descriptors.
 *   - Maps only the READABLE window of each segment (b_rptr..b_wptr), not the
 *     whole cluster. iwx_m_alloc() opens the write window to the full cluster
 *     for the RX case, which is why that case works out to the same thing --
 *     but the TX case has already had its 802.11 header trimmed with m_adj()
 *     and mapping from b_datap->db_base would DMA the trimmed header.
 *
 * STATUS: ENOSYS -- not implemented, not stubbed, fails at link.
 */
#ifndef _IWX_DMA_H
#define _IWX_DMA_H

#include <machine/bus.h>
#include "iwx_mbuf.h"

extern int bus_dmamap_load_mbuf(bus_dma_tag_t, bus_dmamap_t, mblk_t *, int);

#endif /* _IWX_DMA_H */
