# iwm/iwx RX (and TX) DMA buffers must be physically contiguous (measured on the X1, 2026-10-10)

## What happened

`update_drv -a -i '"pciex8086,a370"' iwm` on dixi (the first real attach of the
OpenBSD iwm port to the AC 9560) panicked the kernel and boot-looped the laptop.
Two bugs, in order:

1. **Primary (why attach fails):** `iwm0: could not allocate RX ring`, preceded by
   the rootnex warning *"the driver is using ddi_dma_attr(9S) incorrectly ...
   partial mapping"*.
2. **Secondary (why it panicked, now fixed):** the error path freed the RX ring
   twice -> `ddi_dma_free_handle` on an already-freed handle ->
   `mutex_destroy: bad mutex` panic. Fixed by NULLing `data->map` after
   `bus_dmamap_destroy` in `iwm_free_{rx,tx}_ring` (gen-illumos-src.py).

The alias was removed, so the X1 no longer loops; it runs generation 4. The driver
loads but does not attach.

## Root cause of the primary bug

- The RX buffer is `IWM_RBUF_SIZE` = 4096 bytes, allocated by `iwx_m_alloc` ->
  `allocb(4096)`. illumos `allocb` is backed by a kmem dblk cache; a 4096-byte
  buffer is **not guaranteed page-aligned**, so its physical memory can straddle a
  4 KiB page boundary and bind as **2 DMA cookies**.
- The RX buffer map is created with `nsegs = 1` (`bus_dmamap_create(sc->sc_dmat,
  IWM_RBUF_SIZE, 1, ...)`), so `iwm_dma_attr` sets `dma_attr_sgllen = 1`.
- A 2-cookie buffer against `sgllen = 1` makes rootnex want a partial mapping,
  which the driver did not request (`DDI_DMA_PARTIAL` not set) -> the warning, and
  `iwm_dma_bind` returns `EFBIG` (nck > maxsegs) -> `iwm_rx_addbuf` fails ->
  `iwm_alloc_rx_ring` fails -> `could not allocate RX ring`.
- Raising `sgllen` is **wrong**: the hardware RX descriptor stores a single address
  (`ring->desc[idx] = htole{32,64}(data->map->dm_segs[0].ds_addr)`), so each RX
  buffer must be ONE contiguous DMA segment. OpenBSD gets this for free because its
  MCLGETL clusters come from a pool whose 4 KiB (`MCLBYTES`/`IWM_RBUF_SIZE`) buffers
  are page-aligned by construction. illumos `allocb` makes no such promise.

The same applies to TX: linearised TX frames bind on a map with `nsegs = 1` (the
chain is linearised when it would need more).

## The fix to make (not a 2am patch)

The RX buffers (and the linearised TX buffer) must be physically contiguous and
bind as one cookie. Options, in order of preference:

1. **Allocate RX buffers as DDI-contiguous DMA memory**, the way the descriptor
   rings already are (`iwm_dma_contig_alloc` -> `ddi_dma_mem_alloc` with the right
   `dma_attr_align`), and wrap each in an esballoc()'d mblk so the net80211/GLDv3
   path still sees an mblk. This guarantees one cookie and matches OpenBSD's
   pool-cluster semantics. Most faithful; a bit more code (a free callback).
2. **Constrain `iwm_dma_attr` for buffer maps** so DDI will only accept a
   single-cookie bind: `dma_attr_seg = IWM_RBUF_SIZE - 1` with
   `dma_attr_align = IWM_RBUF_SIZE`. This only helps memory DDI itself places, so
   it must be combined with a contiguous allocator (option 1); on `allocb` memory
   it just turns the failure into a cleaner `EFBIG`.
3. **Detect a >1-cookie bind in `iwm_rx_addbuf` and bounce** through a contiguous
   staging buffer. Simplest to add but adds a copy on the RX hot path; avoid if 1
   is feasible.

Go with option 1. Verify: with the fix, `iwm_alloc_rx_ring` succeeds (no rootnex
warning, no `could not allocate RX ring`), and a repeated attach/detach does not
leak DMA handles (`::kmem_cache` for the rootnex dma handle cache steady).

## Also fix in iwx

`iwx` has the identical latent bug: same `iwx_m_alloc` -> `allocb`, same
`bus_dmamap_create(..., 1, ...)`, same single-address RX descriptor. Apply the
same contiguous-buffer fix there before iwx is ever attached.

## Do not attach until this is fixed

The double-free panic is fixed, so a future attach fails cleanly instead of
panicking -- but it still fails (`could not allocate RX ring`) until the buffers
are contiguous. Keep the `pciex8086,a370` alias OFF (and the iwx alias) until an
attach reaches at least firmware load without the RX-ring failure, on a machine
with the dump device armed.
