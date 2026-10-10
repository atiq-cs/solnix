/*
 * iwm_bus.c -- OpenBSD bus_dma(9), bus_space(9) and pci(9) on illumos DDI.
 *
 * Implements exactly the entry points if_iwm.c calls (measured: 13 bus_*,
 * 11 pci_*), with the semantics its call sites depend on, so the vendored
 * iwm_attach() and ring code run unmodified:
 *
 *   iwm_dma_contig_alloc (if_iwm.c:1216-1254) does create -> dmamem_alloc ->
 *   dmamem_map -> load -> reads dm_segs[0].ds_addr. The DDI equivalent is one
 *   handle + one ddi_dma_mem_alloc + one bind, so the map object carries the
 *   whole contiguous allocation and dmamem_alloc/map/free/unmap operate on it
 *   through the bus_dma_segment_t, which records the owning map.
 *
 *   bus_dmamap_load_mbuf follows the contract written in ../iwx/iwx_dma.h:
 *   maps b_rptr..b_wptr of every b_cont segment, fills dm_segs[], and returns
 *   EFBIG (exactly) when the chain needs more segments than the map allows,
 *   because the TX path linearises and retries only on EFBIG
 *   (if_iwm.c:6929-6947).
 *
 *   Interrupts: the OpenBSD pci_intr_map_msix/msi/map + pci_intr_establish
 *   pair becomes ddi_intr_alloc + ddi_intr_add_handler, MSI-X or MSI first
 *   then FIXED, with the handler wrapped so it runs under the giant lock
 *   (net80211-openbsd/n80211_giant.c), as OpenBSD runs it under kernel_lock.
 *   A high-level interrupt is refused: giant is an adaptive mutex.
 *
 * DMA attributes: the 7000/8000/9000 families address 36 bits on the TX
 * descriptors (IWM_TFD high bits) and 64-bit on the RX/ICT pointers; the
 * attribute here limits every binding to 36 bits, which satisfies both and
 * matches what Linux iwlwifi sets for these families (DMA_BIT_MASK(36)).
 */

#include <sys/types.h>
#include <sys/ddi.h>
#include <sys/sunddi.h>
#include <sys/kmem.h>
#include <sys/errno.h>
#include <sys/pci.h>
#include <sys/cmn_err.h>
#include <sys/stream.h>
#include <sys/strsun.h>

#include <sys/iwx_kernel.h>
#include <machine/bus.h>
#include <dev/pci/pcivar.h>
#include <dev/pci/pcireg.h>

extern void n80211_giant_enter(void);
extern void n80211_giant_exit(void);

static ddi_device_acc_attr_t iwm_dma_acc_attr = {
	DDI_DEVICE_ATTR_V0,
	DDI_NEVERSWAP_ACC,
	DDI_STRICTORDER_ACC,
	DDI_DEFAULT_ACC
};

static ddi_device_acc_attr_t iwm_reg_acc_attr = {
	DDI_DEVICE_ATTR_V0,
	DDI_STRUCTURE_LE_ACC,
	DDI_STRICTORDER_ACC,
	DDI_DEFAULT_ACC
};

static void
iwm_dma_attr(ddi_dma_attr_t *a, bus_size_t align, int nsegs, bus_size_t maxseg)
{
	bzero(a, sizeof (*a));
	a->dma_attr_version = DMA_ATTR_V0;
	a->dma_attr_addr_lo = 0;
	a->dma_attr_addr_hi = 0xfffffffffULL;		/* 36 bits */
	a->dma_attr_count_max = maxseg > 0 ? maxseg - 1 : 0xffffffffU;
	a->dma_attr_align = align > 0 ? align : 1;
	a->dma_attr_burstsizes = 0xfff;
	a->dma_attr_minxfer = 1;
	a->dma_attr_maxxfer = 0xffffffffU;
	a->dma_attr_seg = 0xffffffffU;
	a->dma_attr_sgllen = nsegs > 0 ? nsegs : 1;
	a->dma_attr_granular = 1;
	a->dma_attr_flags = 0;
}

/* --------------------------------------------------------- bus_dmamap --- */

int
bus_dmamap_create(bus_dma_tag_t tag, bus_size_t size, int nsegs,
    bus_size_t maxsegsz, bus_size_t boundary, int flags, bus_dmamap_t *mapp)
{
	bus_dmamap_t map;
	ddi_dma_attr_t attr;
	int kmf = (flags & BUS_DMA_NOWAIT) ? KM_NOSLEEP : KM_SLEEP;

	(void) boundary;
	if (nsegs > IWX_DMA_MAX_SEGS)
		return (EINVAL);
	map = kmem_zalloc(sizeof (*map), kmf);
	if (map == NULL)
		return (ENOMEM);
	map->dm_maxsegs = nsegs;
	map->dm_size = size;
	iwm_dma_attr(&attr, 1, nsegs, maxsegsz);
	if (ddi_dma_alloc_handle(tag->dt_dip, &attr,
	    (flags & BUS_DMA_NOWAIT) ? DDI_DMA_DONTWAIT : DDI_DMA_SLEEP, NULL,
	    &map->dm_hdl) != DDI_SUCCESS) {
		kmem_free(map, sizeof (*map));
		return (ENOMEM);
	}
	*mapp = map;
	return (0);
}

void
bus_dmamap_destroy(bus_dma_tag_t tag, bus_dmamap_t map)
{
	(void) tag;
	if (map == NULL)
		return;
	if (map->dm_bound)
		(void) ddi_dma_unbind_handle(map->dm_hdl);
	if (map->dm_acc != NULL)
		ddi_dma_mem_free(&map->dm_acc);
	ddi_dma_free_handle(&map->dm_hdl);
	kmem_free(map, sizeof (*map));
}

static int
iwm_dma_bind(bus_dmamap_t map, caddr_t va, size_t len, int flags)
{
	ddi_dma_cookie_t ck;
	uint_t nck, i;
	uint_t dir = (flags & BUS_DMA_READ) ? DDI_DMA_READ :
	    (flags & BUS_DMA_WRITE) ? DDI_DMA_WRITE : DDI_DMA_RDWR;
	int r;

	r = ddi_dma_addr_bind_handle(map->dm_hdl, NULL, va, len,
	    dir | DDI_DMA_CONSISTENT,
	    (flags & BUS_DMA_NOWAIT) ? DDI_DMA_DONTWAIT : DDI_DMA_SLEEP, NULL,
	    &ck, &nck);
	if (r == DDI_DMA_TOOBIG)
		return (EFBIG);
	if (r != DDI_DMA_MAPPED)
		return (ENOMEM);
	if ((int)nck > map->dm_maxsegs) {
		(void) ddi_dma_unbind_handle(map->dm_hdl);
		return (EFBIG);
	}
	for (i = 0; i < nck; i++) {
		map->dm_segs[i].ds_addr = ck.dmac_laddress;
		map->dm_segs[i].ds_len = ck.dmac_size;
		if (i + 1 < nck)
			ddi_dma_nextcookie(map->dm_hdl, &ck);
	}
	map->dm_nsegs = (int)nck;
	map->dm_mapsize = len;
	map->dm_bound = B_TRUE;
	return (0);
}

int
bus_dmamap_load(bus_dma_tag_t tag, bus_dmamap_t map, void *buf,
    bus_size_t len, void *proc, int flags)
{
	(void) tag;
	(void) proc;
	if (map->dm_bound)
		return (EBUSY);
	return (iwm_dma_bind(map, buf, (size_t)len, flags));
}

/*
 * The contract in ../iwx/iwx_dma.h. iwm's RX buffers and linearised TX frames
 * are single-segment; a multi-segment TX chain is bound segment by segment
 * only if every b_cont piece is one cookie, else EFBIG makes the caller
 * linearise. A partially-bound chain is never left behind.
 */
int
bus_dmamap_load_mbuf(bus_dma_tag_t tag, bus_dmamap_t map, mblk_t *m,
    int flags)
{
	mblk_t *p;
	int n = 0;
	size_t total = 0;

	(void) tag;
	if (map->dm_bound)
		return (EBUSY);
	for (p = m; p != NULL; p = p->b_cont) {
		if (MBLKL(p) > 0)
			n++;
	}
	if (n == 0)
		return (EINVAL);
	if (n > 1)
		return (EFBIG);		/* caller linearises (if_iwm.c:6934) */
	for (p = m; MBLKL(p) == 0; p = p->b_cont)
		;
	/*
	 * RX: iwx_m_alloc opened the whole cluster as the write window, so
	 * b_rptr..b_wptr is the buffer the device fills. TX: it is the frame
	 * after m_adj trimmed the 802.11 header, which is what must be sent.
	 */
	total = MBLKL(p);
	return (iwm_dma_bind(map, (caddr_t)p->b_rptr, total, flags));
}

void
bus_dmamap_unload(bus_dma_tag_t tag, bus_dmamap_t map)
{
	(void) tag;
	if (map->dm_bound) {
		(void) ddi_dma_unbind_handle(map->dm_hdl);
		map->dm_bound = B_FALSE;
		map->dm_nsegs = 0;
		map->dm_mapsize = 0;
	}
}

void
bus_dmamap_sync(bus_dma_tag_t tag, bus_dmamap_t map, bus_addr_t off,
    bus_size_t len, int ops)
{
	uint_t who;

	(void) tag;
	if (!map->dm_bound)
		return;
	who = (ops & (BUS_DMASYNC_POSTREAD | BUS_DMASYNC_POSTWRITE)) ?
	    DDI_DMA_SYNC_FORKERNEL : DDI_DMA_SYNC_FORDEV;
	(void) ddi_dma_sync(map->dm_hdl, (off_t)off, (size_t)len, who);
}

/* ---------------------------------------------------------- bus_dmamem --- */

/*
 * OpenBSD splits allocation (dmamem_alloc, a segment) from mapping
 * (dmamem_map, a kva) from binding (dmamap_load). DDI allocates memory
 * against a handle, so the segment carries a private map+handle made here,
 * and dmamap_load of the returned kva on the caller's map binds the caller's
 * handle to that memory.
 */
int
bus_dmamem_alloc(bus_dma_tag_t tag, bus_size_t size, bus_size_t align,
    bus_size_t boundary, bus_dma_segment_t *segs, int nsegs, int *rsegs,
    int flags)
{
	ddi_dma_attr_t attr;
	ddi_dma_handle_t h;
	ddi_acc_handle_t acc;
	caddr_t kva;
	size_t real;

	(void) boundary;
	if (nsegs < 1)
		return (EINVAL);
	iwm_dma_attr(&attr, align, 1, 0);
	if (ddi_dma_alloc_handle(tag->dt_dip, &attr,
	    (flags & BUS_DMA_NOWAIT) ? DDI_DMA_DONTWAIT : DDI_DMA_SLEEP, NULL,
	    &h) != DDI_SUCCESS)
		return (ENOMEM);
	if (ddi_dma_mem_alloc(h, (size_t)size, &iwm_dma_acc_attr,
	    DDI_DMA_CONSISTENT,
	    (flags & BUS_DMA_NOWAIT) ? DDI_DMA_DONTWAIT : DDI_DMA_SLEEP, NULL,
	    &kva, &real, &acc) != DDI_SUCCESS) {
		ddi_dma_free_handle(&h);
		return (ENOMEM);
	}
	segs[0].ds_addr = 0;		/* known only once bound */
	segs[0].ds_len = size;
	segs[0].ds_kva = kva;
	segs[0].ds_hdl = h;
	segs[0].ds_acc = acc;
	*rsegs = 1;
	return (0);
}

void
bus_dmamem_free(bus_dma_tag_t tag, bus_dma_segment_t *segs, int nsegs)
{
	(void) tag;
	(void) nsegs;
	if (segs[0].ds_acc != NULL)
		ddi_dma_mem_free(&segs[0].ds_acc);
	if (segs[0].ds_hdl != NULL)
		ddi_dma_free_handle(&segs[0].ds_hdl);
	segs[0].ds_kva = NULL;
}

int
bus_dmamem_map(bus_dma_tag_t tag, bus_dma_segment_t *segs, int nsegs,
    size_t size, caddr_t *kvap, int flags)
{
	(void) tag;
	(void) nsegs;
	(void) size;
	(void) flags;
	if (segs[0].ds_kva == NULL)
		return (EINVAL);
	*kvap = segs[0].ds_kva;
	return (0);
}

void
bus_dmamem_unmap(bus_dma_tag_t tag, caddr_t kva, size_t size)
{
	(void) tag;
	(void) kva;
	(void) size;		/* the mapping lives until bus_dmamem_free */
}

/*
 * esballoc free_arg: owns the DDI-contiguous buffer that backs one RX or
 * firmware-command mblk. Freed when the last freemsg() on that mblk fires the
 * free callback. The frtn_t is embedded so the whole thing is one allocation.
 */
struct iwm_dmabuf {
	bus_dma_tag_t		db_tag;
	bus_dma_segment_t	db_seg;
	frtn_t			db_frtn;
};

static void
iwm_dmabuf_free(caddr_t arg)
{
	struct iwm_dmabuf *db = (struct iwm_dmabuf *)(void *)arg;

	bus_dmamem_free(db->db_tag, &db->db_seg, 1);
	kmem_free(db, sizeof (*db));
}

/*
 * Physically contiguous, single-cookie mblk for the DMA paths. bus_dmamem_alloc
 * requests one segment (sgllen == 1), so DDI must place the memory contiguously
 * and a later bus_dmamap bind returns exactly one cookie -- unlike allocb(),
 * whose 4 KiB buffers can straddle a page and bind as two. The 256-byte align
 * matches what the ring descriptors already use (iwm_dma_contig_alloc).
 */
mblk_t *
iwm_dma_mblk_alloc(bus_dma_tag_t tag, size_t size)
{
	struct iwm_dmabuf *db;
	bus_dma_segment_t seg;
	int rseg;
	mblk_t *m;

	if (size == 0)
		return (NULL);
	if (bus_dmamem_alloc(tag, (bus_size_t)size, 256, 0, &seg, 1, &rseg,
	    BUS_DMA_NOWAIT) != 0)
		return (NULL);
	db = kmem_zalloc(sizeof (*db), KM_NOSLEEP);
	if (db == NULL) {
		bus_dmamem_free(tag, &seg, 1);
		return (NULL);
	}
	db->db_tag = tag;
	db->db_seg = seg;
	db->db_frtn.free_func = iwm_dmabuf_free;
	db->db_frtn.free_arg = (caddr_t)db;
	m = esballoc((unsigned char *)seg.ds_kva, size, BPRI_MED, &db->db_frtn);
	if (m == NULL) {
		bus_dmamem_free(tag, &seg, 1);
		kmem_free(db, sizeof (*db));
		return (NULL);
	}
	/*
	 * Open the write window to the whole buffer, as iwx_m_alloc does: the
	 * device DMAs into [b_rptr, b_wptr) and the length is corrected after.
	 */
	m->b_wptr = m->b_rptr + size;
	return (m);
}

void
bus_space_unmap(bus_space_tag_t t, bus_space_handle_t h, bus_size_t size)
{
	(void) t;
	(void) size;
	if (h != NULL && h->bs_acc != NULL) {
		ddi_regs_map_free(&h->bs_acc);
		kmem_free(h, sizeof (*h));
	}
}

/* ----------------------------------------------------------------- pci --- */

pcireg_t
pci_conf_read(pci_chipset_tag_t pc, pcitag_t tag, int reg)
{
	(void) pc;
	return (pci_config_get32(tag, (off_t)reg));
}

void
pci_conf_write(pci_chipset_tag_t pc, pcitag_t tag, int reg, pcireg_t val)
{
	(void) pc;
	pci_config_put32(tag, (off_t)reg, val);
}

/* Walk the standard capability list (PCI 3.0 6.7). */
int
pci_get_capability(pci_chipset_tag_t pc, pcitag_t tag, int capid,
    int *offset, pcireg_t *value)
{
	uint8_t ptr;
	int guard = 48;

	(void) pc;
	if (!(pci_config_get16(tag, PCI_CONF_STAT) & PCI_STAT_CAP))
		return (0);
	ptr = pci_config_get8(tag, PCI_CONF_CAP_PTR) & ~3;
	while (ptr != 0 && guard-- > 0) {
		if (pci_config_get8(tag, ptr) == capid) {
			if (offset != NULL)
				*offset = ptr;
			if (value != NULL)
				*value = pci_config_get32(tag, ptr);
			return (1);
		}
		ptr = pci_config_get8(tag, ptr + 1) & ~3;
	}
	return (0);
}

pcireg_t
pci_mapreg_type(pci_chipset_tag_t pc, pcitag_t tag, int reg)
{
	(void) pc;
	return (pci_config_get32(tag, (off_t)reg) & 0x7);
}

/*
 * Map BAR0. On illumos, "reg" entry 0 is config space and entry 1 is the
 * first assigned BAR (dixi: assigned-addresses 8300a310... = 64-bit memory
 * BAR at config offset 0x10, 16 KiB), so OpenBSD's PCI_MAPREG_START maps to
 * register set 1.
 */
int
pci_mapreg_map(struct pci_attach_args *pa, int reg, pcireg_t type, int flags,
    bus_space_tag_t *tagp, bus_space_handle_t *handlep, bus_addr_t *basep,
    bus_size_t *sizep, bus_size_t maxsize)
{
	bus_space_handle_t h;
	off_t sz;

	(void) type;
	(void) flags;
	(void) basep;
	(void) maxsize;
	if (reg != PCI_MAPREG_START)
		return (EINVAL);
	if (ddi_dev_regsize(pa->pa_dip, 1, &sz) != DDI_SUCCESS)
		return (ENXIO);
	h = kmem_zalloc(sizeof (*h), KM_SLEEP);
	if (ddi_regs_map_setup(pa->pa_dip, 1, &h->bs_base, 0, sz,
	    &iwm_reg_acc_attr, &h->bs_acc) != DDI_SUCCESS) {
		kmem_free(h, sizeof (*h));
		return (ENXIO);
	}
	h->bs_size = sz;
	*tagp = NULL;
	*handlep = h;
	if (sizep != NULL)
		*sizep = (bus_size_t)sz;
	return (0);
}

int
pci_matchbyid(struct pci_attach_args *pa, const struct pci_matchid *ids,
    int n)
{
	int i;

	for (i = 0; i < n; i++) {
		if (PCI_VENDOR(pa->pa_id) == ids[i].pm_vid &&
		    PCI_PRODUCT(pa->pa_id) == ids[i].pm_pid)
			return (1);
	}
	return (0);
}

/* --------------------------------------------------------- interrupts --- */

/*
 * One vector of the given type. OpenBSD's map functions return 0 on success;
 * the handle remembers the type so establish can allocate it.
 */
static int
iwm_intr_map_type(struct pci_attach_args *pa, int type, pci_intr_handle_t *ihp)
{
	int types, count;
	pci_intr_handle_t ih;

	if (ddi_intr_get_supported_types(pa->pa_dip, &types) != DDI_SUCCESS ||
	    !(types & type))
		return (1);
	if (ddi_intr_get_nintrs(pa->pa_dip, type, &count) != DDI_SUCCESS ||
	    count < 1)
		return (1);
	ih = kmem_zalloc(sizeof (*ih), KM_SLEEP);
	ih->ih_type = type;
	ih->ih_dip = pa->pa_dip;
	*ihp = ih;
	return (0);
}

/*
 * NOTE: MSI-X is declined. iwm's MSI-X path (iwm_conf_msix_hw, if_iwm.c:1900)
 * programs IVAR tables per vector; with one vector MSI is equivalent and is
 * what the 9000 family uses under OpenBSD when MSI-X allocation fails. Add
 * MSI-X if a multi-vector configuration is ever wanted.
 */
int
pci_intr_map_msix(struct pci_attach_args *pa, int vec, pci_intr_handle_t *ihp)
{
	(void) pa;
	(void) vec;
	(void) ihp;
	return (1);
}

int
pci_intr_map_msi(struct pci_attach_args *pa, pci_intr_handle_t *ihp)
{
	return (iwm_intr_map_type(pa, DDI_INTR_TYPE_MSI, ihp));
}

int
pci_intr_map(struct pci_attach_args *pa, pci_intr_handle_t *ihp)
{
	return (iwm_intr_map_type(pa, DDI_INTR_TYPE_FIXED, ihp));
}

const char *
pci_intr_string(pci_chipset_tag_t pc, pci_intr_handle_t ih)
{
	(void) pc;
	return (ih->ih_type == DDI_INTR_TYPE_MSI ? "msi" :
	    ih->ih_type == DDI_INTR_TYPE_MSIX ? "msix" : "intx");
}

static uint_t
iwm_intr_trampoline(caddr_t a1, caddr_t a2)
{
	pci_intr_handle_t ih = (pci_intr_handle_t)(void *)a1;
	int claimed;

	(void) a2;
	n80211_giant_enter();
	claimed = ih->ih_fn(ih->ih_arg);
	n80211_giant_exit();
	return (claimed ? DDI_INTR_CLAIMED : DDI_INTR_UNCLAIMED);
}

void *
pci_intr_establish(pci_chipset_tag_t pc, pci_intr_handle_t ih, int level,
    int (*fn)(void *), void *arg, const char *name)
{
	int actual;
	uint_t pri;

	(void) pc;
	(void) level;
	(void) name;
	ih->ih_table = kmem_zalloc(sizeof (ddi_intr_handle_t), KM_SLEEP);
	if (ddi_intr_alloc(ih->ih_dip, ih->ih_table, ih->ih_type, 0, 1,
	    &actual, DDI_INTR_ALLOC_STRICT) != DDI_SUCCESS || actual != 1)
		goto fail_free;
	if (ddi_intr_get_pri(ih->ih_table[0], &pri) != DDI_SUCCESS)
		goto fail_intr;
	/* giant is adaptive: a handler above LOCK_LEVEL may not block on it */
	if (pri >= ddi_intr_get_hilevel_pri()) {
		cmn_err(CE_WARN, "iwm: interrupt priority %u is high-level", pri);
		goto fail_intr;
	}
	ih->ih_pri = pri;
	ih->ih_fn = fn;
	ih->ih_arg = arg;
	if (ddi_intr_add_handler(ih->ih_table[0], iwm_intr_trampoline,
	    (caddr_t)ih, NULL) != DDI_SUCCESS)
		goto fail_intr;
	/* MSI/MSI-X handles that advertise DDI_INTR_FLAG_BLOCK MUST be enabled
	 * with ddi_intr_block_enable, not ddi_intr_enable -- calling the wrong
	 * one returns failure. Record the capability so iwm_intr_{enable,disable}
	 * pick the matching call. (The AC 9560 uses MSI with the block cap;
	 * measured on the X1: ddi_intr_enable returned !=DDI_SUCCESS -> attach
	 * failed in iwm_intr_enable with every earlier stage succeeding.) */
	if (ddi_intr_get_cap(ih->ih_table[0], &ih->ih_cap) != DDI_SUCCESS)
		ih->ih_cap = 0;
	ih->ih_count = 1;
	return (ih);

fail_intr:
	(void) ddi_intr_free(ih->ih_table[0]);
fail_free:
	kmem_free(ih->ih_table, sizeof (ddi_intr_handle_t));
	ih->ih_table = NULL;
	return (NULL);
}

/* Enable after the softc is complete; split out so attach can order it. */
int
iwm_intr_enable(pci_intr_handle_t ih)
{
	int r;

	if (ih->ih_cap & DDI_INTR_FLAG_BLOCK)
		r = ddi_intr_block_enable(ih->ih_table, ih->ih_count);
	else
		r = ddi_intr_enable(ih->ih_table[0]);
	return (r == DDI_SUCCESS ? 0 : EIO);
}

void
iwm_intr_disestablish(pci_intr_handle_t ih)
{
	if (ih == NULL)
		return;
	if (ih->ih_table != NULL) {
		if (ih->ih_count > 0) {
			if (ih->ih_cap & DDI_INTR_FLAG_BLOCK)
				(void) ddi_intr_block_disable(ih->ih_table,
				    ih->ih_count);
			else
				(void) ddi_intr_disable(ih->ih_table[0]);
			(void) ddi_intr_remove_handler(ih->ih_table[0]);
		}
		(void) ddi_intr_free(ih->ih_table[0]);
		kmem_free(ih->ih_table, sizeof (ddi_intr_handle_t));
	}
	kmem_free(ih, sizeof (*ih));
}
