# amdgpu on illumos — the C3-amdgpu layering design

Phase **C3-amdgpu-a** (compile-phase scaffolding). This maps the amdgpu DRM
driver (real AMD GPU, the fully-open ROCm path) onto the C1 DRM framework that
already compiles on illumos, targeting the **g4ad EC2 GPU: AMD Radeon Pro V520
= Navi 12 = gfx1011, PCI 1002:7362**. amdgpu is the biggest new kernel surface
(Linux amdgpu is ~4M LOC); this is a bounded scaffolding step + design, NOT a
working driver.

## Crib

Pinned in `../amdgpu-ref/` (see its `PROVENANCE.md`): the NetBSD-imported
amdgpu at the SAME pin as `../netbsd-ref` (`5a776510...`), subtree
`sys/external/bsd/drm2/dist/drm/amd/amdgpu`. The device-init crib subset
(amdgpu.h, amdgpu_device.c, amdgpu_drv.c, amdgpu_nv.c, amdgpu_discovery.c,
amdgpu_kms.c, the ttm/gmc/gart/object headers) is fetched via the git-blobs
API — NOT the full 329-file dir. Same pin so amdgpu sees the same linux-compat
KPI boundary the C1 shim was written against. The alternate reference is Linux
upstream `drivers/gpu/drm/amd/amdgpu` at any LTS tag (identical logic, minus
NetBSD's `amdgpu_` filename prefix and `__KERNEL_RCSID`).

## The three strata (same model as the C1 DESIGN.md)

    Linux/NetBSD amdgpu logic   (the crib — reference, not lifted verbatim)
    ------------------------------------------------------------
    linux-compat shim boundary  (C1's linux_compat.h/linux_dma.h + amdgpu gaps)
    ------------------------------------------------------------
    illumos DDI / VM / C1 DRM   (the substrate: ddi_*, C1 GEM/fence/sched)

## Subsystem map: amdgpu -> what C1 provides + what's NEW

| amdgpu subsystem | crib file | illumos / C1 mapping | status |
|---|---|---|---|
| **PCI attach** (BAR map, config space, MSI-X) | amdgpu_device.c device-init prologue; amdgpu_drv.c id table | `pci_config_setup` + `ddi_regs_map_setup` (per BAR) + `ddi_intr_alloc`/`_add_handler`. The raw-PCI analogue of C1b's virtio attach (which used the virtio bus). | **C3-amdgpu-a DONE (compiling)** — `src/amdgpu.c` |
| **register access** RREG32/WREG32 | amdgpu_device.c `amdgpu_mm_rreg` (`bus_space_read_4`) | `ddi_get32`/`ddi_put32` on the BAR5 access handle at byte offset `4*reg`. | **C3-amdgpu-a DONE** — `amdgpu_rreg32`/`_wreg32` |
| **asic detect** (Navi 12 / gfx1011) | amdgpu_drv.c `{0x1002,0x7362,...,CHIP_NAVI12}`; amdgpu_nv.c `nv_common_early_init` CHIP_NAVI12 case | read vendor/device/rev from config space -> classify CHIP_NAVI12. | **C3-amdgpu-a DONE** — `amdgpu_read_asic_id` |
| **IP-block bring-up** | amdgpu_device.c `amdgpu_device_ip_early_init` -> amdgpu_nv.c `nv_set_ip_blocks` -> `navi12_reg_base_init` | the per-IP-block `.early_init/.sw_init/.hw_init` table; each IP block (GFX/SDMA/GMC/IH/PSP/DC) is a large port of its own. | **DEFERRED (C3-amdgpu-b..)** |
| **TTM** (VRAM + GTT placement) | amdgpu_ttm.c, amdgpu_object.c, ttm/* | **the biggest NEW piece — C1 has no TTM** (virtio-gpu had no VRAM). See "TTM" below. VRAM = the BAR0 aperture (already mapped here); GTT = `ddi_dma_*` scatter-gather over system RAM; the LRU eviction is bespoke (illumos VM has no analogue). | **DEFERRED (C3-amdgpu-b, the key subsystem)** |
| **GEM** (amdgpu_gem / amdgpu_bo) | amdgpu_object.c, amdgpu_gem.c | reuse **C1 GEM** (`drm_gem.c`, `ddi_umem_alloc`); amdgpu's BO is a GEM object + a TTM placement, so amdgpu_bo = C1 GEM object + the (deferred) TTM placement. | C1 GEM reused; BO/TTM glue deferred |
| **KMS** (display / DC) | amdgpu_display.c, the DC (display core) subtree | reuse the **C1 KMS shape** (C1b SET_SCANOUT modeset). **Skip for headless-compute-first bring-up** — ROCm needs no display. | DEFERRED / skip for compute |
| **command submission** (rings / IB / amdgpu_cs) | amdgpu_cs.c, amdgpu_ring.c, amdgpu_ib.c | wire the GPU rings to the **C1 scheduler** (`drm_sched.c`): a `drm_sched_job` `run_job` writes the IB into the ring buffer + rings the doorbell; completion signals the C1 dma-fence — the same shape C1d used for the virtio SUBMIT_3D path. | DEFERRED (C3-amdgpu-c) |
| **fences / sync** | amdgpu_fence.c, amdgpu_sync.c | reuse **C1c dma-fence + dma-resv + sync_file** (`drm_dma.c`, `drm_prime.c`) directly; amdgpu_fence is a dma-fence subclass. | C1c reused |
| **KFD** (`/dev/kfd`, the ROCm compute ioctl surface) | amdkfd/* (a separate dir at the crib pin) | the compute path — a second char device + the KFD ioctls + the compute queues (user-mode queues / doorbells). | DEFERRED — **A3-f** (after GL/Vulkan) |
| **firmware** (signed GPU microcode blobs) | amdgpu_ucode.c `request_firmware` | see "firmware" below. amdgpu firmware is redistributable (`linux-firmware` `amdgpu/` LICENSE.amdgpu). | DEFERRED |

## TTM — the key new subsystem (C3-amdgpu-b)

C1 deferred TTM deliberately: virtio-gpu buffers are host-shared system pages,
no VRAM, so C1's DESIGN.md section C left TTM as "for when a real VRAM GPU is
targeted (C3)". amdgpu on the V520 is that GPU. TTM manages *where* a buffer
object lives and migrates it:

| TTM concept | illumos mapping | note |
|---|---|---|
| system-memory pool | `ddi_umem_alloc` pages (the C1 GEM backing) | reuse C1 |
| **VRAM manager** (device memory) | the **BAR0 aperture** — mapped in C3-amdgpu-a as `vram_hdl`/`vram_base`/`vram_size` — carved by a range allocator (a `gfxp`/`vmem` arena over the aperture offset). | the visible-VRAM window; a real Navi 12 has ~8-16GB VRAM but only a BAR-sized window is CPU-visible (resizable-BAR aside) |
| **GTT / GART** (GPU page table over system RAM) | `ddi_dma_alloc_handle` + `ddi_dma_addr_bind_handle` -> cookies; the GART table itself is device pages the GMC IP block programs | this is the scatter-gather path C1b's virtio backing already uses (`virtio_dma_cookie_pa`) — reuse the pattern |
| **placement / migration** (VRAM<->GTT<->system) | the DMA copy engine (SDMA ring) or a CPU memcpy through the two mappings | needs the SDMA ring (deferred) for async; a sync CPU copy works for bring-up |
| **eviction / LRU** | **bespoke** — illumos VM has no TTM-LRU analogue; a simple per-manager LRU list + the ww_mutex-locked dma_resv (C1c) for the reservation. | the one piece with no illumos primitive to lean on |

TTM is the load-bearing next step: GEM-on-TTM (amdgpu_bo) is how every amdgpu
buffer — command buffers, page tables, the framebuffer, compute allocations —
is allocated. C3-amdgpu-b is "the smallest TTM: a VRAM range allocator over the
BAR0 aperture + GTT via ddi_dma, no migration, no eviction".

## firmware — the loading approach

amdgpu needs signed microcode blobs per IP block (GFX/SDMA/PSP/SMC/VCN…);
Navi 12 loads e.g. `amdgpu/navi12_*.bin`. The blobs are **redistributable**
(the `linux-firmware` `amdgpu/` dir ships `LICENSE.amdgpu`, a redistribution-
permitted license) so solnix can package them like it packages other firmware.
The loading path: Linux `request_firmware(&fw, "amdgpu/navi12_gfx.bin", dev)`
-> on illumos, `firmware_open`/`firmware_read`/`firmware_close` (the illumos
`ddi` firmware(9F) loader that reads from `/boot/firmware` / a driver firmware
dir) OR a plain `vn_open`/`vn_rdwr` of a packaged path. This is a **linux-compat
gap beyond C1** — C1 never loaded firmware. It maps cleanly (illumos has a
firmware loader), just not yet written.

## linux-compat gaps beyond C1's shims (what amdgpu needs that C1 lacks)

C1's `linux_compat.h` + `linux_dma.h` cover kref/idr/mutex/spinlock/kmalloc/
copy_user + dma-fence/dma-resv/ww_mutex/scheduler/sync_file. amdgpu needs, in
addition (each maps to an illumos primitive — none is a blocker, all are work):

1. **TTM** — the whole `ttm_bo_*`/`ttm_resource_*`/`ttm_tt` API. No C1 analogue;
   the biggest gap. Map per the TTM table above. (C3-amdgpu-b.)
2. **`request_firmware` / `release_firmware`** — illumos `firmware(9F)`
   (`firmware_open`/`_read`/`_close`) or a packaged-path `vn_rdwr`. (above.)
3. **`readl`/`writel`/`ioread32`/`iowrite32`** — `ddi_get32`/`ddi_put32` on the
   BAR access handle. **Done** for RREG32/WREG32; a general `linux_io.h` shim
   would fold the rest.
4. **the IH (interrupt handler) ring** — amdgpu's interrupt model is a
   hardware ring the GPU writes IV (interrupt vector) entries into, drained by
   the ISR. C1's scheduler has no IH. The vector is reserved here
   (`ddi_intr_add_handler`); the ring drain + the per-IP-block `.process`
   dispatch is the deferred IH IP block.
5. **`pci_enable_atomic_ops_to_root` / PCIe capability walking** — illumos
   `pci_config_get*` over the PCIe extended-capability list (bespoke walk; the
   illumos `pcie` module has helpers).
6. **`hash_init`/`INIT_DELAYED_WORK`/`INIT_WORK`/`bitmap_*`/`atomic_set`** — the
   `adev` init in `amdgpu_device_init` uses more Linux primitives than C1's
   stub covers (delayed work -> `timeout(9F)`+taskq; bitmap -> a `ulong` array;
   the mutex_init storm -> `mutex_init`). These are the reason C3-amdgpu-a
   compiles a **reduced** device-init, not the literal `amdgpu_device_init`.
7. **DMA-BUF import of a VRAM BO** — C1c PRIME exports a GEM (system pages) fd;
   exporting a VRAM-resident BO needs the p2p / peer-DMA path (deferred).
8. **`enum amd_asic_type` + the `amd_shared.h` IP-block enums** — pure headers;
   copy from the crib as the IP blocks land.

## The C3-amdgpu-a deliverable (this phase)

`src/amdgpu.c` + `src/amdgpu_priv.h`: the reduced device-init —
`amdgpu_transport_attach(dip, drm)` (called from the C1 `drm_attach` exactly
like the virtio transport) that:

  - `pci_config_setup` + reads vendor/device/rev, classifies CHIP_NAVI12
    (1002:7362 = the V520);
  - `ddi_regs_map_setup` maps BAR5 (MMIO regs) + BAR0 (VRAM aperture),
    `ddi_dev_regsize` records their sizes;
  - `amdgpu_rreg32`/`amdgpu_wreg32` = RREG32/WREG32 via `ddi_get32`/`ddi_put32`;
  - `ddi_intr_get_supported_types` -> `ddi_intr_alloc` (MSI-X preferred) +
    `ddi_intr_add_handler` reserves the interrupt vector.

It compiles to **ET_REL AMD64**, links into the single `drm` module, and every
undefined symbol resolves to a real illumos DDI export (checked by
`verify-syms.sh` — 113 undefs, zero phantom). It does NOT run and does NOT bring
up any IP block; it is the PCI-attach/asic-detect/BAR-map floor the rest of
amdgpu builds on.

## R-next (C3-amdgpu-b)

**The smallest TTM**: a VRAM range allocator over the BAR0 aperture (`vmem`
arena on the aperture offset) + GTT via `ddi_dma_*`, no migration/eviction —
enough to allocate an amdgpu_bo in VRAM and in GTT. That unblocks the IP-block
bring-up (`nv_set_ip_blocks`/`navi12_reg_base_init`), which needs BOs for its
ring buffers + page tables. Then: the IH ring (item 4) + `request_firmware`
(item 2), then the GFX/SDMA rings wired to the C1 scheduler (C3-amdgpu-c),
then KFD (A3-f, the ROCm compute surface).
