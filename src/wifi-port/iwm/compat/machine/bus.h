/*
 * iwm copy of ../../../iwx/compat/machine/bus.h with the fields iwm_bus.c
 * needs (segment-owned DDI memory, map limits). Searched before iwx/compat/.
 */
/*
 * OpenBSD <machine/bus.h> -> illumos ddi_dma_* / ddi_acc_handle_t.
 *
 * bus_dma has a genuinely different shape on the two systems and the difference
 * is not cosmetic:
 *
 *   OpenBSD: a bus_dma_tag_t describes the parent bus, a bus_dmamap_t is created
 *   once and then loaded/unloaded repeatedly against different buffers, and the
 *   resulting segment list hangs off the map (map->dm_segs[]).
 *
 *   illumos: a ddi_dma_handle_t is allocated per buffer from an attributes
 *   struct, memory is allocated THROUGH it (ddi_dma_mem_alloc) which also
 *   returns a separate ddi_acc_handle_t for byte-swapped access, and cookies are
 *   fetched with ddi_dma_addr_bind_handle/ddi_dma_nextcookie.
 *
 * So bus_dmamap_t is modelled as a struct carrying BOTH illumos handles plus the
 * cookie list, and the OpenBSD dm_segs[] view is materialised into it on load so
 * the driver's segment reads keep working unchanged.
 *
 * STATUS: types and macros are REAL. The load/create/destroy functions are
 * declared here and implemented in iwx_dma.c; anything not yet implemented is
 * left as an undefined SYMBOL so it fails at LINK time with its own name rather
 * than silently returning success in a DMA path.
 */
#ifndef _IWM_COMPAT_MACHINE_BUS_H
#define _IWM_COMPAT_MACHINE_BUS_H

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/dditypes.h>
#include <sys/stream.h>

typedef uint64_t	bus_addr_t;
typedef uint64_t	bus_size_t;

/*
 * bus_space: OpenBSD carries (handle, offset); illumos ddi_get/put take a
 * mapped virtual address. The tag is unused on illumos and the handle becomes
 * the ddi_acc_handle_t plus the mapped base, so both must travel together.
 */
typedef struct iwx_bus_space_tag *bus_space_tag_t;
typedef struct iwx_bus_space {
	ddi_acc_handle_t	bs_acc;
	caddr_t			bs_base;
	off_t			bs_size;
} *bus_space_handle_t;

/* One DMA segment, matching the fields if_iwx.c reads out of dm_segs[]. */
typedef struct bus_dma_segment {
	bus_addr_t	ds_addr;
	bus_size_t	ds_len;
	/*
	 * iwm: bus_dmamem_alloc owns DDI memory through the segment, because
	 * DDI allocates memory against a DMA handle (see ../../iwm_bus.c).
	 */
	caddr_t			ds_kva;
	ddi_dma_handle_t	ds_hdl;
	ddi_acc_handle_t	ds_acc;
} bus_dma_segment_t;

#define IWX_DMA_MAX_SEGS	20	/* iwm: IWM_NUM_OF_TBS */

typedef struct iwx_bus_dma_tag {
	dev_info_t	*dt_dip;
} *bus_dma_tag_t;

typedef struct iwx_bus_dmamap {
	ddi_dma_handle_t	dm_hdl;
	ddi_acc_handle_t	dm_acc;
	boolean_t		dm_bound;
	/* OpenBSD-visible view. if_iwx.c reads dm_segs[0].ds_addr directly. */
	bus_size_t		dm_mapsize;
	int			dm_nsegs;
	int			dm_maxsegs;	/* iwm: create-time limit */
	bus_size_t		dm_size;	/* iwm: create-time size */
	bus_dma_segment_t	dm_segs[IWX_DMA_MAX_SEGS];
} *bus_dmamap_t;

/* Sync directions. illumos has two; OpenBSD's four collapse onto them. */
#define BUS_DMASYNC_PREREAD	0x01
#define BUS_DMASYNC_POSTREAD	0x02
#define BUS_DMASYNC_PREWRITE	0x04
#define BUS_DMASYNC_POSTWRITE	0x08

#define BUS_DMA_WAITOK		0x0000
#define BUS_DMA_NOWAIT		0x0001
#define BUS_DMA_ALLOCNOW	0x0002
#define BUS_DMA_COHERENT	0x0004
#define BUS_DMA_ZERO		0x0008
#define BUS_DMA_READ		0x0010
#define BUS_DMA_WRITE		0x0020
#define BUS_DMA_64BIT		0x0040

#define BUS_SPACE_MAP_LINEAR	0x0001

/* Register access. The offset is added to the mapped base. */
#define bus_space_read_1(t, h, o)	\
	ddi_get8((h)->bs_acc, (uint8_t *)((h)->bs_base + (o)))
#define bus_space_read_4(t, h, o)	\
	ddi_get32((h)->bs_acc, (uint32_t *)((h)->bs_base + (o)))
#define bus_space_write_1(t, h, o, v)	\
	ddi_put8((h)->bs_acc, (uint8_t *)((h)->bs_base + (o)), (v))
#define bus_space_write_4(t, h, o, v)	\
	ddi_put32((h)->bs_acc, (uint32_t *)((h)->bs_base + (o)), (v))
#define bus_space_barrier(t, h, o, l, f)	/* ddi_get/put are ordered */

extern int bus_dmamap_create(bus_dma_tag_t, bus_size_t, int, bus_size_t,
    bus_size_t, int, bus_dmamap_t *);
extern void bus_dmamap_destroy(bus_dma_tag_t, bus_dmamap_t);
extern int bus_dmamap_load(bus_dma_tag_t, bus_dmamap_t, void *, bus_size_t,
    void *, int);
extern void bus_dmamap_unload(bus_dma_tag_t, bus_dmamap_t);
extern void bus_dmamap_sync(bus_dma_tag_t, bus_dmamap_t, bus_addr_t,
    bus_size_t, int);
extern int bus_dmamem_alloc(bus_dma_tag_t, bus_size_t, bus_size_t, bus_size_t,
    bus_dma_segment_t *, int, int *, int);
extern void bus_dmamem_free(bus_dma_tag_t, bus_dma_segment_t *, int);
extern int bus_dmamem_map(bus_dma_tag_t, bus_dma_segment_t *, int, size_t,
    caddr_t *, int);
extern void bus_dmamem_unmap(bus_dma_tag_t, caddr_t, size_t);
extern void bus_space_unmap(bus_space_tag_t, bus_space_handle_t, bus_size_t);

/*
 * bus_dmamap_load_mbuf is the one call that COUPLES the DMA and mbuf layers, so
 * it takes an mblk_t and lives with the mbuf translation rather than here.
 * Declared in iwx_dma.h.
 */

/*
 * Allocate an mblk whose data buffer is physically contiguous DDI-DMA memory,
 * aligned so it binds as exactly ONE cookie through a bus_dmamap. The RX
 * refill buffers and the oversized firmware-command buffer are DMA'd and their
 * hardware descriptors store a single address (dm_segs[0].ds_addr), so the
 * backing memory must not straddle a page: allocb() does not promise that,
 * ddi_dma_mem_alloc with dma_attr_align == IWM_RBUF_SIZE does. The mblk is
 * esballoc()'d over the DDI memory with a free callback, so net80211/GLDv3
 * still see a plain mblk and the DMA memory is released when the last freemsg()
 * drops it. Returns NULL on failure. Lives in iwm_bus.c because it needs the
 * DDI DMA tag, which the mbuf translation layer deliberately does not carry.
 */
extern mblk_t *iwm_dma_mblk_alloc(bus_dma_tag_t, size_t);

#endif /* _IWM_COMPAT_MACHINE_BUS_H */
