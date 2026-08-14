# solnix DRM/KMS port — STATUS

## Phase reached: C3-amdgpu-c (the Navi 12 IP-block / ring bring-up — navi12 register bases + reduced GMC/GART + GFX/SDMA command rings + the IH ring, COMPILING against illumos headers + the C1/amdgpu framework)

C3-amdgpu-c is the **last compile-phase piece before amdgpu drives a real GPU**.
With TTM (C3-amdgpu-b) providing `amdgpu_bo_create`, each IP block now allocates
its ring buffers + page tables. The chain the attach path runs after TTM:
`navi12_reg_base_init` (set the SOC15 register bases so RREG32/WREG32 can
address each IP block) -> `amdgpu_wb_init` (the ring-progress writeback buffer)
-> `amdgpu_gmc_init` (the GART page table) -> `amdgpu_ring_init` x2 (the GFX +
SDMA command rings) -> `amdgpu_ih_ring_init` (the interrupt ring). It allocates
the BOs + sets up the pointers/reg-bases; it does NOT power up the GPU or load
firmware (that is C3-amdgpu-d, needs real hardware).

### C3-amdgpu-c deliverables, per piece (all COMPILING, ET_REL AMD64)

- **navi12 register base: YES.** `amdgpu/amdgpu_ip.c` (build copy
  `src/amdgpu_ip.c`) + `amdgpu_ip.h`. `navi12_reg_base_init` fills
  `sc->ip->reg_offset[hwip][inst]` from the Navi 12 IP-base table (GC / HDP /
  MMHUB / ATHUB / NBIF0 / MP0 / OSSSYS / SDMA=GC / SMUIO / THM / CLK / DF), the
  base values cribbed **VERBATIM** from `../amdgpu-ref/src/navi12_ip_offset.h`
  (the real gfx1011 MMIO bases, NOT invented). `amdgpu_reg_offset(sc, hwip,
  inst, seg, reg)` = `reg_offset[..][seg] + reg` (the SOC15_REG_OFFSET model)
  is the absolute MMIO word index RREG32/WREG32 (C3-amdgpu-a) then addresses.
  Crib: `amdgpu_navi12_reg_init.c` + `soc15_common.h`.
- **GMC / GART: YES.** `amdgpu/gmc.c`. `amdgpu_gmc_init` picks a 512 MB GART,
  derives `num_gpu_pages = gart_size / GPU_PAGE_SIZE` and `table_size =
  num_gpu_pages * 8` (8 bytes/PTE), allocates + zeroes the page-table BO from
  `amdgpu_bo_create` (in GTT here so it has a CPU mapping; real GMC 10 puts it
  in VRAM + kmaps it — the VRAM CPU-mmap devmap path is deferred). No live
  aperture-register programming, no per-page PTE fill (deferred, needs live
  MMIO / SDMA). Crib: `amdgpu_gart.h`/`amdgpu_gart.c` `amdgpu_gart_init` +
  `gmc_v10_0` gart_size.
- **GFX + SDMA ring_init: YES.** `amdgpu/amdgpu_ring.c`. `amdgpu_ring_init`:
  `ring_size = pow2(max_dw * 4 * sched_hw_submission)`, `buf_mask =
  ring_size/4 - 1`, `ptr_mask`, the ring BO from `amdgpu_bo_create`(GTT) ->
  CPU ptr + GPU addr, the rptr/wptr/fence writeback slots (`amdgpu_wb_get`),
  and the doorbell index. `amdgpu_ring_write` appends a dword with the wptr
  wrap. This is the transport EXECBUFFER (the C1d 3D submit) ultimately feeds;
  the live IB-emit + drm_sched wiring is C3-amdgpu-d. Crib: `amdgpu_ring.h` /
  `amdgpu_ring.c` `amdgpu_ring_init` + `amdgpu_ring_write`; `gfx_v10_0` /
  `sdma_v5_0` ring setup.
- **IH ring: YES (skeleton).** `amdgpu/amdgpu_ring.c` `amdgpu_ih_ring_init`:
  the 256 KB interrupt-handler ring BO (GTT) + rptr + ptr_mask. The GPU writes
  interrupt-vector entries here; the ISR (amdgpu.c `amdgpu_intr_stub`, on the
  MSI-X vector C3-amdgpu-a reserved) drains it. The IV decode + the
  per-IP-block `.process` dispatch + the live WPTR/RPTR register wiring are
  C3-amdgpu-d. Crib: `amdgpu_ih.h` + `navi10_ih.c`.
- **writeback + aggregate: YES.** `amdgpu_wb_*` (a 128-slot GTT dword BO the
  GPU posts ring progress into, bitmap slot allocator) + `amdgpu_ip_blocks_init`
  / `_fini` (the reduced `amdgpu_device_ip_init`: common/GMC/GFX/SDMA/IH order,
  per `nv_set_ip_blocks` CHIP_NAVI12; PSP/SMU/DCE/VCN skipped). Wired into
  `amdgpu_transport_attach` after `amdgpu_ttm_init`.

### C3-amdgpu-c what compiles (verified)

    cd /root/drm-port && make
      -> src/amdgpu_ip.o    ELF 64-bit LSB relocatable AMD64  (ET_REL, EM_AMD64)
      -> src/gmc.o          ELF 64-bit LSB relocatable AMD64
      -> src/amdgpu_ring.o  ELF 64-bit LSB relocatable AMD64
      -> src/amdgpu.o       (now calls amdgpu_ip_blocks_init after TTM)
      -> drm                links the three new objects into the single module
    ./verify-syms.sh  # 124 undefs, zero phantom (C3-amdgpu-c adds only
                      #   snprintf as a new external; all other new undefs are
                      #   intra-amdgpu, resolved at link)
    gcc -o /tmp/tc test/test_c3_amdgpu_c.c && /tmp/tc  # "C3-amdgpu-c logic self-check: PASS"

### C3-amdgpu-c deferred (each mapped in docs/design-gpu-amdgpu.md)

- **power-up + firmware** (`request_firmware` of navi12_*.bin, PSP/SMU
  sequencing) — C3-amdgpu-d; needs the real V520.
- **live register programming** — `gmc_v10_0` gart_enable (VM page-table base +
  the PTE-fill loop over the GTT cookies), the GFX/SDMA `.hw_init` (ring-enable
  registers + the doorbell aperture), the IH WPTR/RPTR wiring + IV decode.
- **the live submit path** — the GFX/SDMA rings wired to the C1 scheduler
  (`drm_sched.c`): a `drm_sched_job` `run_job` emits the IB into the ring +
  rings the doorbell; completion signals the C1 dma-fence.

### R-next: C3-amdgpu-d (firmware load + power-up sequencing — needs real hw)

All remaining pieces are `RREG32/WREG32` against a real Navi 12: load the
microcode blobs, power up (PSP/SMU), program the GMC/GFX/SDMA/IH live
registers, wire the rings to the C1 scheduler, then KFD (A3-f, ROCm compute).
The compile-phase floor — device-init (a) + TTM (b) + IP blocks/rings (c) — is
now complete.

---

## Prior phase: C3-amdgpu-b (the smallest TTM — vmem VRAM manager over BAR0 + ddi_dma GTT manager + ttm_bo core + amdgpu_bo_create, COMPILING against illumos headers + the C1/amdgpu framework)

C3-amdgpu-b builds the **key new kernel subsystem C1 deferred**: TTM
(Translation Table Manager) — GPU memory management. C1's virtio-gpu had no
VRAM, so it had no TTM; amdgpu on the g4ad V520 (Navi 12) is the real VRAM GPU
that needs it. amdgpu's ring buffers, page tables, and buffer objects all
allocate through TTM, so this is the gate for the IP-block / ring bring-up.

The **illumos-TTM design** (the load-bearing insight): VRAM = the AMD GPU's
onboard memory reached through the BAR0 PCI aperture (mapped in C3-amdgpu-a),
range-allocated by **illumos `vmem`** — the kernel's general resource
allocator, a clean fit for carving VRAM offsets; GTT = system RAM the GPU
reaches via DMA, allocated with **`ddi_dma_alloc_handle` + `ddi_dma_mem_alloc`
+ `ddi_dma_addr_bind_handle`** whose cookies ARE the GPU-visible scatter-gather
addresses. No migration, no eviction, no swap (deferred per the design).

### C3-amdgpu-b deliverables, per piece (all COMPILING, ET_REL AMD64)

- **ttm_bo core: YES.** `amdgpu/ttm.c` (build copy `src/ttm.c`) +
  `ttm_priv.h`. Reduced `struct ttm_buffer_object` (a `kref`, a size, a
  `ttm_resource` placement, and a backing union: a VRAM `vmem` address OR a
  GTT `ddi_dma` state) + `struct ttm_resource` (mem_type/size/num_pages/start)
  + `ttm_bo_init`/`_get`/`_put` + `ttm_device_init`/`_fini`. Placed ONCE at
  init; released on the last put. Dropped (deferred): the drm_gem base, LRU/
  ddestroy/swap lists, `ttm_tt`, the moving fence, mmu notifiers. Crib:
  netbsd-ref `.../ttm/ttm_bo_api.h` + `ttm_placement.h`.
- **vmem VRAM manager: YES.** `ttm_range_man_*` in `ttm.c`. `vmem_create`
  (`VMC_IDENTIFIER` — abstract device offsets, not real pages) over the BAR0
  aperture `[TTM_VRAM_VMEM_BASE, +sc->vram_size)`; `vmem_xalloc`/`vmem_xfree`
  carve GPU-page-aligned byte ranges (`VM_BESTFIT` — no eviction to reclaim
  fragmentation). The base offset makes offset 0 representable and a NULL
  return unambiguously OOM. Crib: Linux `drm/ttm/ttm_range_manager.c` +
  `amdgpu_vram_mgr`, re-expressed over `vmem`.
- **ddi_dma GTT manager: YES.** `ttm_gtt_man_*` in `ttm.c`.
  `ddi_dma_alloc_handle` (44/48-bit GART attr) -> `ddi_dma_mem_alloc`
  (DMA-able kernel pages) -> `ddi_dma_addr_bind_handle` -> the cookies are the
  GPU-visible s/g addresses (`cookie0.dmac_laddress` = the base a GART/IOMMU
  maps). A byte-budget manager (512 MB default; each alloc carries its own
  cookies). Crib: the illumos nvme/vioif ddi_dma idiom + C1b's virtio backing.
- **amdgpu_bo_create: YES.** `amdgpu/amdgpu_ttm.c` (build copy
  `src/amdgpu_ttm.c`). `struct amdgpu_bo` = `ttm_buffer_object` + the GEM
  domain + a C1 `drm_gem_object` wrapper; `amdgpu_bo_create(sc, size,
  AMDGPU_GEM_DOMAIN_{VRAM,GTT}, &bo)` maps the domain -> ttm mem_type ->
  `ttm_bo_init` -> a vmem VRAM range or a ddi_dma GTT alloc, then attaches a C1
  GEM object so a GEM_CREATE handle resolves to the BO. `amdgpu_bo_gpu_offset`
  returns the address an IP block programs. `amdgpu_ttm_init`/`_fini` stand up
  the TTM device from the softc; `amdgpu_transport_attach` calls it after the
  BAR map. Crib: `../amdgpu-ref/src/amdgpu_object.h` amdgpu_bo_create +
  `amdgpu_ttm.h` amdgpu_ttm_init, reduced HARD.

### C3-amdgpu-b what compiles (verified)

    cd /root/drm-port && make
      -> src/ttm.o          ELF 64-bit LSB relocatable AMD64  (ET_REL, EM_AMD64)
      -> src/amdgpu_ttm.o   ELF 64-bit LSB relocatable AMD64
      -> src/amdgpu.o       (now calls amdgpu_ttm_init)
      -> drm                links ttm.o + amdgpu_ttm.o into the single module
    ./verify-syms.sh  # 123 undefs, zero phantom (C3-amdgpu-b adds only
                      #   vmem_create/destroy/xalloc/xfree +
                      #   ddi_dma_{alloc_handle,mem_alloc,addr_bind_handle,
                      #   unbind_handle,mem_free,free_handle} — all real illumos KPI)
    gcc -o /tmp/tb test/test_c3_amdgpu_b.c && /tmp/tb  # "C3-amdgpu-b logic self-check: PASS"

### C3-amdgpu-b deferred (each mapped in docs/design-gpu-amdgpu.md)

- **migration / placement** (VRAM<->GTT<->system) — needs the SDMA copy ring
  or a CPU memcpy through the two mappings. A BO is placed once, at create.
- **eviction / LRU** — the one piece with no illumos primitive to lean on; a
  bespoke per-manager LRU + the C1c ww_mutex-locked dma_resv.
- **`ttm_tt`** — the swappable system-page backing; SYSTEM placement here is
  the C1 GEM ddi_umem path, not TTM.
- **mmap of a VRAM BO** — a `devmap` over the BAR0 aperture (the C1b cb_devmap
  path extended); the GEM handle exists, the CPU mapping is deferred with
  eviction.

### R-next: C3-amdgpu-c (IP blocks / ring bring-up) — NOW DONE (see the top section)

The TTM unblocks it: `amdgpu_device_ip_early_init` -> `nv_set_ip_blocks` ->
`navi12_reg_base_init`, then each IP block (GFX/SDMA/GMC/IH) allocates its ring
buffers + page tables from `amdgpu_bo_create`. Then the IH ring +
`request_firmware`, then the GFX/SDMA rings wired to the C1 scheduler, then KFD
(A3-f, the ROCm compute surface).

---

## Prior phase: C3-amdgpu-a (amdgpu real-hardware PCI-attach/device-init skeleton — COMPILING against illumos headers + the C1 framework)

C3-amdgpu-a begins porting the **amdgpu DRM driver** (real AMD GPU hardware,
the fully-open ROCm path) onto the C1 framework, targeting the **g4ad EC2 GPU:
AMD Radeon Pro V520 = Navi 12 = gfx1011, PCI 1002:7362** — the best GPU-parity
target since amdgpu + ROCm are fully open (no NVIDIA GSP-firmware wall). amdgpu
is the biggest new kernel surface in existence (Linux amdgpu is ~4M LOC); this
is bounded compile-phase scaffolding, NOT a working driver.

### C3-amdgpu-a deliverables

- **Crib pinned: YES.** `amdgpu-ref/` — the NetBSD-imported amdgpu at the SAME
  pin as `netbsd-ref/` (`5a776510...`), subtree
  `sys/external/bsd/drm2/dist/drm/amd/amdgpu`, the device-init crib subset
  fetched via the git-blobs API (amdgpu_device.c, amdgpu_drv.c, amdgpu_nv.c,
  amdgpu_discovery.c, amdgpu_kms.c, amdgpu.h + the ttm/gmc/gart/object headers —
  NOT the full 329-file dir). Provenance + reproduce in
  `amdgpu-ref/PROVENANCE.md`. Confirmed real: `amdgpu_device.c,v 1.21
  2024/07/01`, `CHIP_NAVI12` handled in `amdgpu_nv.c`, PCI `{0x1002,0x7362,...,
  CHIP_NAVI12}` in `amdgpu_drv.c`.

- **illumos-layering design: YES.** `docs/design-gpu-amdgpu.md` — the full
  subsystem map (PCI/TTM/GEM/KMS/rings/fences/KFD/firmware -> illumos + what C1
  provides + what's NEW), with **TTM as the key new subsystem** C1 deferred
  (virtio-gpu had no VRAM), the linux-compat gaps beyond C1's shims enumerated,
  and the R-next (C3-amdgpu-b = the smallest TTM).

- **Smallest amdgpu piece compiling: YES (ET_REL AMD64, zero phantom).**
  `src/amdgpu.c` + `src/amdgpu_priv.h`: the reduced `amdgpu_device_init` —
  `amdgpu_transport_attach(dip, drm)` called from the C1 `drm_attach` exactly
  like `virtio_gpu_transport_attach`, but for a **raw PCI device** (amdgpu is a
  bare PCI GPU, not a virtio child):
    1. `pci_config_setup` + read vendor/device/rev -> classify **CHIP_NAVI12**
       (1002:7362 = the V520);
    2. `ddi_regs_map_setup` maps **BAR5** (MMIO regs = `rmmio`) + **BAR0** (VRAM
       aperture), `ddi_dev_regsize` records sizes;
    3. `amdgpu_rreg32`/`amdgpu_wreg32` = RREG32/WREG32 via `ddi_get32`/
       `ddi_put32` at byte offset `4*reg` (the illumos analogue of NetBSD's
       `bus_space_read_4(rmmiot, rmmioh, 4*reg)`);
    4. `ddi_intr_get_supported_types` -> `ddi_intr_alloc` (MSI-X preferred) +
       `ddi_intr_add_handler` reserves the interrupt vector (the IH-ring drain
       is deferred).
  It links into the single `drm` ET_REL AMD64 module; `verify-syms.sh` reports
  **113 undefs, zero phantom** — every amdgpu.o undef is a real illumos DDI
  export (`ddi_regs_map_setup`, `pci_config_setup`, `ddi_intr_alloc`,
  `ddi_get32`, `ddi_dev_regsize`, ...). It does NOT run and brings up no IP
  block; it is the PCI-attach/asic-detect/BAR-map floor the rest of amdgpu
  builds on.

### C3-amdgpu-a what compiles (verified)

    cd /root/drm-port && make
      -> src/amdgpu.o   ELF 64-bit LSB relocatable AMD64  (ET_REL, EM_AMD64)
      -> drm            links amdgpu.o into the single module
    ./verify-syms.sh  # 113 undefs, zero phantom (amdgpu adds only real DDI KPI)
    gcc -o /tmp/t test/test_c3_amdgpu.c && /tmp/t  # "C3-amdgpu-a logic self-check: PASS"

### C3-amdgpu-a deferred (each mapped in docs/design-gpu-amdgpu.md, none a blocker)

- **TTM** (VRAM+GTT placement) — the biggest NEW piece vs C1; VRAM = the BAR0
  aperture (mapped here), GTT = `ddi_dma_*`, eviction bespoke. **C3-amdgpu-b.**
- **IP-block bring-up** — `amdgpu_device_ip_early_init` -> `nv_set_ip_blocks` ->
  `navi12_reg_base_init` + each IP block's `.early_init/.sw_init/.hw_init`.
- **firmware** — `request_firmware("amdgpu/navi12_*.bin")` -> illumos
  `firmware(9F)`; the blobs are redistributable (`LICENSE.amdgpu`).
- **rings / command submission** (amdgpu_cs) -> the C1 scheduler (C3-amdgpu-c).
- **KFD** (`/dev/kfd`, the ROCm compute ioctl surface) -> A3-f.
- **KMS/DC** (display) -> reuse C1 KMS shape; skip for headless-compute-first.

### R-next (from C3-amdgpu-a): C3-amdgpu-b — NOW DONE (see the top section)

The smallest TTM: a VRAM range allocator (`vmem` arena) over the BAR0 aperture +
GTT via `ddi_dma_*`, no migration/eviction — enough to allocate an `amdgpu_bo`
in VRAM and GTT, which the IP-block bring-up needs for its ring buffers + page
tables. **Delivered in C3-amdgpu-b (compiling)** — `amdgpu/ttm.c` +
`amdgpu_ttm.c` + `ttm_priv.h`. Next is C3-amdgpu-c (IP blocks / rings), then the
IH ring + `request_firmware`, then KFD (the ROCm compute surface).

---

## Prior phase: C1d (virtio-gpu 3D command path — EXECBUFFER + CTX + GET_CAPS + RESOURCE_CREATE_3D + TRANSFER_3D, all COMPILING against illumos headers)


C1d extends the C1b 2D virtio-gpu transport to the **3D command/ioctl surface**
that Mesa's virgl (GL) and venus (Vulkan) drivers drive — the one bounded kernel
gap between the compiling C1 framework + C3a's (built) virgl/venus userspace and
accelerated GPU on solnix. It adds no new transport, no VRAM, no TTM: 3D is more
command types on the *same* controlq + `virtio_gpu_exec` chain + GEM buffers,
signalling the *same* C1c dma-fence via the *same* C1c scheduler. The whole DRM
module — core + GEM + virtio-gpu 2D + 3D + dma-fence/scheduler + PRIME — compiles
as a single `ET_REL` AMD64 kernel object, with every undefined symbol resolving
to a real illumos KPI (genunix/specfs) or an export of the illumos `virtio`
module. Zero phantom symbols (checked by `verify-syms.sh`).

It is a COMPILE milestone: the 3D path is written to run (it drives the real
illumos virtio KPI + the C1c scheduler/dma-fence/sync_file), but is not verified
running under QEMU (needs a metal host with `-device virtio-gpu-gl` + KVM + a
host GPU). With C3a's virgl/venus Mesa, **the C1+C3a stack is now
compile-complete for accelerated virtio-gpu**, pending only the metal runtime
proof.

### C1d deliverables, per item (all compiling)

- **EXECBUFFER: YES.** `virtio_gpu_ioctl_execbuffer` in `src/virtio_gpu_3d.c`.
  The load-bearing path: copyin the virgl/venus command stream → a
  `drm_sched_job` whose `run_job` ships it via `SUBMIT_3D`
  (`virtio_gpu_exec_extra`) → `drm_sched_entity_push_job` → the job's finished
  C1c dma-fence is the out fence, wrapped in a C1c `sync_file` fd when
  `VIRTGPU_EXECBUF_FENCE_FD_OUT` is set; an in-fence fd is waited first. This
  **wires the C1c scheduler `run_job` → the virtio `SUBMIT_3D` submission**, the
  step the C1c "remaining runtime" list named.
- **CTX_CREATE / CTX_DESTROY: YES.** `virtio_gpu_ioctl_context_init` +
  `virtio_gpu_cmd_ctx_create`/`_destroy`/`_attach_resource`. A per-drm-device 3D
  context (CTX_CREATE with the capset id in `context_init` selecting virgl vs
  venus), created lazily, destroyed at detach.
- **RESOURCE_CREATE_3D: YES.** `virtio_gpu_ioctl_resource_create` +
  `virtio_gpu_cmd_resource_create_3d`: `ddi_umem_alloc` a GEM object →
  RESOURCE_CREATE_3D (target/format/bind/dims/array/mip) → ATTACH_BACKING →
  CTX_ATTACH_RESOURCE. Reuses the C1 GEM object.
- **GET_CAPS: YES.** `virtio_gpu_ioctl_get_caps` + `virtio_gpu_cmd_get_capset_info`/
  `_get_capset`: walk GET_CAPSET_INFO to match the requested capset id, then
  GET_CAPSET for the blob, copyout to Mesa. Plus GETPARAM (3D_FEATURES /
  CONTEXT_INIT) so Mesa probes before choosing virgl/venus.
- **TRANSFER_3D: YES.** `virtio_gpu_ioctl_transfer_to_host` / `_from_host` +
  `virtio_gpu_cmd_transfer_3d`: box-form TRANSFER_{TO,FROM}_HOST_3D
  (level/offset/stride/layer_stride). Plus MAP (`virtio_gpu_ioctl_map`, reuses
  the C1b `cb_devmap` mmap-offset path) and WAIT (synchronous no-op).
- **UAPI preserved: YES.** `src/uapi/drm/virtgpu_drm.h` is the Linux DRM
  `virtgpu_drm.h` verbatim (via the NetBSD import + current-Linux CONTEXT_INIT/
  ring_idx/blob params), so C3a's virgl/venus Mesa binds unchanged.

## Prior phase (C1c) summary

C1c builds on the C1a drm-core/GEM stub and the C1b real-GEM-backing + virtio-gpu
2D path. The whole DRM module — core + GEM + virtio-gpu transport + 2D modeset +
the C1c GPU-synchronization/buffer-sharing primitives — compiles as a single
`ET_REL` AMD64 kernel object against the installed illumos kernel headers, with
every undefined symbol resolving to a real illumos KPI (genunix/specfs) or an
export of the illumos `virtio` kernel module. No phantom Linux symbols, no
phantom `dma_buf_*`, no phantom virtio symbols.

Getting the C1c primitives to compile against illumos headers + a
worked-out dma-buf-fd mechanism is the C1c deliverable, and **it unblocks C2
(Mesa/GBM/Vulkan)** at the compile/ABI level.

## Prior phase (C1b) summary

C1b: real GEM backing (`ddi_umem_alloc`) + `cb_devmap`/`devmap_umem_setup` mmap;
the C1b shim primitives (workqueue→taskq, kthread, completion, rwsem); virtio-gpu
attach over the illumos `virtio` framework + `GET_DISPLAY_INFO`; the SET_SCANOUT
2D modeset chain. See DESIGN.md for the full C1a/C1b detail.

## What compiles (verified)

    cd /root/drm-port && make
      -> src/drm_core.o    ELF 64-bit LSB relocatable AMD64   (ET_REL, EM_AMD64)
      -> src/drm_gem.o     ELF 64-bit LSB relocatable AMD64
      -> src/virtio_gpu.o  ELF 64-bit LSB relocatable AMD64
      -> src/virtio_gpu_3d.o ELF 64-bit LSB relocatable AMD64  (C1d 3D path)
      -> src/drm_dma.o     ELF 64-bit LSB relocatable AMD64   (C1c fence/ww/resv)
      -> src/drm_sched.o   ELF 64-bit LSB relocatable AMD64   (C1c scheduler)
      -> src/drm_prime.o   ELF 64-bit LSB relocatable AMD64   (C1c PRIME/sync_file)
      -> drm               ELF 64-bit LSB relocatable AMD64    (ld -r linked module)

    make verify   # prints file types + elfdump e_type/e_machine (ET_REL/AMD64)
    ./verify-syms.sh  # zero-phantom: every UNDEF resolves to illumos KPI or
                      # a virtio module export (96 undefs, all real)

    cc -o test_c1b test/test_c1b.c && ./test_c1b   # -> "C1b logic self-check: PASS"
    cc -o test_c1c test/test_c1c.c && ./test_c1c   # -> "C1c logic self-check: PASS"
    cc -o test_c1d test/test_c1d.c && ./test_c1d   # -> "C1d logic self-check: PASS"

### C1c deliverables, per item

- **dma-fence: YES (compiling).** `src/drm_dma.c` + `linux-compat/linux_dma.h`.
  `dma_fence_init`/`_signal`/`_signal_locked`/`_wait`/`_wait_timeout`/
  `_add_callback`/`_remove_callback`/`_enable_sw_signaling`/`_is_signaled`/
  `_set_error`/`_get`/`_put`/`_context_alloc` over `kref` + `kmutex_t` +
  `kcondvar_t` + an atomic flags word (ENABLE_SIGNAL/SIGNALED bits) + a callback
  `list_t`. Signal is one-shot; signalling wakes all `cv` waiters and fires +
  removes every callback under the fence lock; wait uses `cv_timedwait[_sig]`.
  Cribbed from NetBSD `linux_dma_fence.c`.

- **dma-resv + ww_mutex: YES (compiling).** Same `src/drm_dma.c`. `ww_mutex` is
  the real wound/wait: each `ww_acquire_ctx` takes a global monotonic ticket;
  locking a mutex held by an older (lower-ticket) ctx waits, by a younger ctx
  returns `-EDEADLK` (caller backs off + retries via `ww_mutex_lock_slow`),
  by self returns `-EALREADY`. `dma_resv` = a `ww_mutex` + one exclusive fence +
  a growable shared-fence array, with add-excl/add-shared/reserve-shared/
  wait-timeout. Cribbed from NetBSD `linux_ww_mutex.c` + `linux_dma_resv.c`
  (minus RCU: illumos has none, so readers take the lock).

- **dma-buf fd-sharing (PRIME) + sync_file: YES (design + compiling).** The hard
  illumos gap, closed in `src/drm_prime.c`. A PRIME fd is an fd from `falloc(9F)`
  whose `file_t->f_vnode` is a spec-vnode (`makespecvp`) of THIS drm device at a
  private per-export minor encoding the exported GEM handle. It passes across
  processes by `SCM_RIGHTS` like any fd; `mmap(fd)` faults through this driver's
  `cb_devmap` (C1b) onto the exported object's `ddi_umem` pages; import
  (`getf(fd) -> f_vnode minor -> export -> object`) re-issues a handle.
  `DRM_IOCTL_PRIME_HANDLE_TO_FD` / `PRIME_FD_TO_HANDLE` are the Linux DRM UAPI
  (in `uapi/drm/drm.h`) so libdrm/GBM/Mesa are unchanged. `sync_file` reuses the
  identical fd mechanism to wrap a fence. See DESIGN.md D.1 for the full design.
  Runtime gaps (need metal): the second-minor-space + `cb_close` export teardown
  and the sync_file `poll(2)` (`cb_chpoll`+`pollwakeup`, still `nochpoll`).

- **drm scheduler + virtio submission ordering: YES (compiling).**
  `src/drm_sched.c` + `drm_sched.h`. A single FIFO run-queue drained by one
  worker kthread; each `drm_sched_job` carries a scheduler-owned "finished"
  dma_fence; `run_job()` does the transport submission (for virtio-gpu the
  `virtio_gpu_exec` chain) and returns a hardware fence; when that signals (or
  immediately, if NULL/synchronous) the worker signals the finished fence, which
  is what a Mesa/Vulkan submit waits on. Cut down from Linux drm/scheduler +
  NetBSD; wiring `run_job` to `virtio_gpu.c` is the remaining runtime step.

### QEMU stretch: NOT reached (unchanged from C1b)

A `qemu-system-x86_64 -device virtio-gpu` boot to observe GET_DISPLAY_INFO
returning was not run: `/usr/bin/qemu-system-x86_64` exists on the build host
but the host is a *non-metal* EC2 instance (no `/dev/kvm`; QEMU has TCG only),
so a full illumos guest boot would be prohibitively slow, and no bootable
illumos guest image with the module installed was prepared. The module was NOT
`modload`ed into the live kernel either (loading a driver with no matching
device risks a panic; HARD RULE keeps us off the live kernel). The symbol
boundary is instead verified statically: every `virtio_*` undef is confirmed
present in `/kernel/misc/amd64/virtio`'s `FUNC GLOB` exports.

## What cribbed from where

- `src/uapi/drm/virtgpu_drm.h` (C1d) — the virtio-gpu **guest-driver DRM UAPI**
  (MAP/EXECBUFFER/GETPARAM/RESOURCE_CREATE/RESOURCE_INFO/TRANSFER_*_HOST/WAIT/
  GET_CAPS/CONTEXT_INIT ioctl numbers + struct layouts) reproduced VERBATIM from
  the Linux DRM UAPI `include/uapi/drm/virtgpu_drm.h` (via the NetBSD-current
  import + the current-Linux CONTEXT_INIT/ring_idx/blob additions). MIT/X11; the
  stable kernel<->userland ABI Mesa's virgl/venus already target, so C3a binds
  unchanged.
- `src/virtio_gpu_hw.h` C1d additions — the 3D **wire structs**
  (ctx_create/ctx_destroy/ctx_resource, resource_create_3d, transfer_host_3d +
  box, cmd_submit, get_capset_info/get_capset + resp) + the 3D command enum
  values, reproduced VERBATIM from Linux/QEMU `include/uapi/linux/virtio_gpu.h`
  (BSD-licensed for non-Linux guests, same provenance as the 2D structs).
- `src/virtio_gpu_3d.c` (C1d) — the 3D command *flow* (ctx create, resource
  create 3d, attach backing, transfer box, submit command buffer, get capset)
  follows Linux `drivers/gpu/drm/virtio/virtgpu_vq.c`; the ioctl handlers
  (execbuffer, context_init, get_caps, getparam, resource_create/info,
  transfer_{to,from}_host, map, wait) follow `virtgpu_ioctl.c`. Re-expressed
  against the illumos virtio KPI + the C1c scheduler/dma-fence/sync_file; no
  Linux .c is lifted. `src/virtio_gpu_priv.h` shares the C1b softc +
  `virtio_gpu_exec` between `virtio_gpu.c` and `virtio_gpu_3d.c` (the split
  mirrors Linux's virtgpu_vq.c / virtgpu_ioctl.c over one virtio_gpu_device).

## What cribbed from where (C1a-c)

- `src/virtio_gpu_hw.h` — the virtio-gpu **wire protocol** (command enum,
  ctrl_hdr, rect, resource_create_2d, set_scanout, resource_flush,
  transfer_to_host_2d, resource_attach_backing + mem_entry, resp_display_info,
  config space, format enum) cribbed VERBATIM from Linux/QEMU
  `include/uapi/linux/virtio_gpu.h` (torvalds/linux master, fetched at build
  time). That header is BSD-licensed precisely for non-Linux guest drivers.
- `src/virtio_impl.h` — the illumos `virtio` framework KPI, re-declared from the
  `FUNC GLOB` exports of `/kernel/misc/amd64/virtio` (the framework header is
  not installed under /usr/include on this build). This is the same KPI illumos
  `vioif(4D)`/`vioblk(4D)` bind to.
- `src/virtio_gpu.c` — the command *flow* (create resource, attach guest pages
  as backing, scanout, flush) follows Linux `drivers/gpu/drm/virtio/virtgpu_vq.c`
  and NetBSD's equivalent, re-expressed against the illumos virtio KPI. The
  attach shape (virtio_init → queues → virtio_init_complete) follows illumos
  vioif/vioblk. No Linux/NetBSD .c is lifted.
- `src/linux-compat/linux_compat.h` C1b additions — the primitives NetBSD
  emulates in `common/linux/linux_work.c`, `drm2/linux/linux_kthread.c`,
  `include/linux/completion.h`, `drm2/linux/linux_rwsem.c`, re-mapped to illumos
  `ddi_taskq`/`thread_create`/`kcondvar_t`/`krwlock_t` (used as the *checklist*
  of which Linux APIs must exist, not lifted).
- `src/linux-compat/linux_dma.h` + `src/drm_dma.c` (C1c) — dma-fence, ww_mutex,
  dma-resv semantics cribbed from NetBSD `drm2/linux/linux_dma_fence.c`,
  `linux_ww_mutex.c`, `linux_dma_resv.c` (fence flag machine, wound/wait ticket
  ordering, excl+shared fence lists), re-expressed over illumos `kref`/
  `kmutex_t`/`kcondvar_t`. No NetBSD .c lifted; RCU dropped (illumos has none —
  readers take the lock).
- `src/drm_sched.c` + `drm_sched.h` (C1c) — single-FIFO-queue scheduler shape
  (run-queue + worker + per-job finished fence) from Linux `drm/scheduler` +
  NetBSD drm2 use, cut to the one hardware queue virtio-gpu needs.
- `src/drm_prime.c` (C1c) — PRIME handle↔fd + sync_file. The ioctl contract
  (`drm_prime_handle`, `PRIME_HANDLE_TO_FD`/`FD_TO_HANDLE`) is the Linux DRM
  UAPI; the export/import flow follows Linux `drm_prime.c` + NetBSD
  `linux_sync_file.c`, but the fd itself is minted the illumos way —
  `falloc` over a `makespecvp` spec-vnode of this device — the DESIGN.md D.1
  mechanism, not Linux anon_inode/dma_buf.

## Layout of /root/drm-port/

    netbsd-ref/          NetBSD-current DRM crib, pinned git 5a7765109d...
    DESIGN.md            layer -> illumos mapping, provenance per file, C1a/b/c split
    STATUS.md            this file
    Makefile             kernel-module build (builds + links the 6 objects)
    src/
      drm_core.c         dev_ops/cb_ops, attach (+ virtio bind + prime init),
                         ioctl dispatch (+ PRIME), VERSION, cb_devmap GEM +
                         PRIME-minor mmap, SET_SCANOUT dispatch
      drm_gem.c          GEM create/map/destroy/close (ddi_umem backed),
                         offset->object lookup, SET_SCANOUT ioctl bridge
      drm_dma.c          C1c: dma-fence, ww_mutex, dma-resv over ksynch
      drm_sched.c        C1c: single-FIFO-queue GPU scheduler
      drm_sched.h        C1c: scheduler structs
      drm_prime.c        C1c: PRIME (dma-buf) handle<->fd + sync_file over
                         falloc/makespecvp/getf
      drm_internal.h     drm_device / drm_gem_object / drm_driver (+ C1c prime
                         export + sync_file lists, prime major/minor)
      virtio_gpu.c       virtio-gpu transport attach + 2D modeset chain
      virtio_gpu_3d.c    C1d: 3D command path (EXECBUFFER/CTX/GET_CAPS/
                         RESOURCE_CREATE_3D/TRANSFER_3D) + the DRM_IOCTL_VIRTGPU_*
                         ioctl handlers, over the C1c scheduler+fence+sync_file
      virtio_gpu_priv.h  C1d: shared virtio-gpu softc + exec + ioctl decls
      virtio_gpu_hw.h    virtio-gpu wire protocol (cribbed; +C1d 3D structs)
      virtio_impl.h      illumos virtio framework KPI (declarations)
      amdgpu.c           C3-amdgpu-a: reduced amdgpu_device_init
                         (amdgpu_transport_attach) + C3-amdgpu-b: calls
                         amdgpu_ttm_init after the BAR map + C3-amdgpu-c: calls
                         amdgpu_ip_blocks_init after TTM
      amdgpu_ip.h        C3-amdgpu-c: SOC15 reg_offset table + struct
                         amdgpu_ring/amdgpu_ih/amdgpu_gmc/amdgpu_wb/amdgpu_ip
      amdgpu_ip.c        C3-amdgpu-c: navi12_reg_base_init (VERBATIM IP bases)
                         + amdgpu_reg_offset + amdgpu_wb_* + ip_blocks_init
      gmc.c              C3-amdgpu-c: reduced GMC/GART (gart_size + page-table
                         BO from amdgpu_bo_create, no live PTE programming)
      amdgpu_ring.c      C3-amdgpu-c: amdgpu_ring_init (GFX+SDMA ring BOs +
                         rptr/wptr/doorbell) + amdgpu_ring_write + IH ring
      amdgpu_priv.h      C3-amdgpu-a: the reduced adev softc (BAR/reg/asic) +
                         C3-amdgpu-b: struct ttm_device *ttm +
                         C3-amdgpu-c: struct amdgpu_ip *ip
      ttm_priv.h         C3-amdgpu-b: reduced ttm_resource/ttm_buffer_object/
                         ttm_range_mgr/ttm_gtt_alloc/ttm_device + amdgpu_bo;
                         the illumos-TTM design (vmem-VRAM, ddi_dma-GTT)
      ttm.c              C3-amdgpu-b: vmem VRAM manager over BAR0 + ddi_dma GTT
                         manager + the ttm_bo core (no migration/eviction/swap)
      amdgpu_ttm.c       C3-amdgpu-b: amdgpu_ttm_init + amdgpu_bo_create/free +
                         amdgpu_bo_gpu_offset (GEM-domain -> VRAM/GTT glue)
      linux-compat/
        linux_compat.h   C1a shim + C1b primitives (taskq/kthread/cv/rwlock)
        linux_dma.h      C1c dma-fence/ww_mutex/dma-resv declarations + inlines
      uapi/drm/drm.h     Linux DRM UAPI subset + PRIME ioctls + solnix SET_SCANOUT
      uapi/drm/virtgpu_drm.h  C1d: virtio-gpu guest DRM UAPI (Linux, verbatim)
    verify-syms.sh       zero-phantom check (UNDEF -> illumos KPI / virtio export)
    test/
      test_c1b.c         userland self-check (offset lookup + cmd-buffer math)
      test_c1c.c         userland self-check (fence signal-once, ww ticket
                         compare, resv array growth)
      test_c1d.c         C1d self-check (execbuf size guard, capset match +
                         clamp, exec_extra cmd/resp layout)
      test_c3_amdgpu.c   C3-amdgpu-a self-check (RREG32 offset, BAR->rnumber,
                         asic classify)
      test_c3_amdgpu_b.c C3-amdgpu-b self-check (vmem<->VRAM-offset round-trip,
                         page rounding, used-bytes accounting, domain->mem_type)
      test_c3_amdgpu_c.c C3-amdgpu-c self-check (SOC15 reg-offset on the real
                         GC/OSSSYS bases, ring_size pow2 + buf_mask + wptr
                         wrap, wb slot alloc/reuse, GART table-size math)
    amdgpu/              C3-amdgpu-a/b/c canonical phase artifacts (amdgpu.c,
                         amdgpu_priv.h, ttm.c, ttm_priv.h, amdgpu_ttm.c,
                         amdgpu_ip.h, amdgpu_ip.c, gmc.c, amdgpu_ring.c) +
                         README.md; build copies live in src/
    amdgpu-ref/          NetBSD amdgpu crib (pin 5a77651) + PROVENANCE.md
    docs/design-gpu-amdgpu.md  the amdgpu illumos-layering design (TTM/PCI/
                         GEM/rings/KFD/firmware)
    build/               scratch build dir (throwaway)

## How to resume

1. Rebuild: `cd /root/drm-port && make verify && ./verify-syms.sh`.
2. Read DESIGN.md sections A-F (+ D.1 for the PRIME dma-buf-fd mechanism, F.1 for
   the C1d 3D command path); each row marks C1a/C1b/C1c/C1d.
3. C1d is DONE (compiling) — the last **kernel** gap for accelerated virtio-gpu
   is closed. With C3a's (built) virgl/venus Mesa, the stack is compile-complete
   for accelerated virtio-gpu; the metal runtime proof is the next milestone.

### Next: metal runtime proof (needs a QEMU host with a GPU + KVM)
The C1d 3D command path wires the scheduler `run_job` → `SUBMIT_3D` and the
EXECBUFFER out-fence → sync_file, all compiling against the real illumos KPI with
the `virtgpu_drm.h` UAPI preserved so C3a's virgl/venus Mesa binds unchanged.
End-to-end "accelerated triangle / llama.cpp-Vulkan in the guest" needs a metal
instance running `qemu-system-x86_64 -device virtio-gpu-gl` (host GPU + KVM);
this build host is non-metal (TCG-only). Remaining runtime bring-up (NOT
compile-blocking):
- make `SUBMIT_3D` async: return a real hardware fence from `run_job` + use the
  completion interrupt instead of `virtio_queue_poll`, and wire per-BO
  `dma_resv` fencing on the EXECBUFFER `bo_handles` list;
- carve the PRIME/sync_file spec-vnode minors out of the drm node as a real
  second minor space + `cb_close` teardown, and the sync_file `poll(2)` path
  (drm `cb_chpoll` + `pollwakeup`, currently `nochpoll`);
- scope the 3D context per `drm_file` (when the GEM handle table becomes
  per-file); zero-copy 3D resource/transfer backing over the GEM umem cookie;
- the C1b polish still pending: bind as a real virtio PCI child in `_init`, a
  devfsadm `/dev/dri/` rule.

## Anti-scope reminder (from the task + design docs)
Do NOT chase a working driver here — that is C1b-stretch/C1c. The ~500k-LOC
Linux DRM drivers in `netbsd-ref/.../dist/` are reference only; solnix adapts
the ~18-20k-LOC shim+glue boundary + the virtio-gpu 2D path, it does not lift
Linux .c. virtio-gpu first (no VRAM => no TTM on the critical path);
i915/amdgpu/nouveau are far later (C3).
