# C3-KFD — the amdkfd (/dev/kfd) compute surface on illumos (compile-phase)

The ROCm/HIP **compute** entry point on illumos: the AMD Kernel Fusion Driver
(amdkfd) char device `/dev/kfd` + the core AMDKFD_IOC_* compute ioctls +
user-mode compute queues (doorbell submission), ported onto the C3-amdgpu
device + the C1 DRM framework. This is the deepest AMD compute path — beyond
the graphics Vulkan (RADV) surface — because ROCm's runtime (ROCr/HSA via
libhsakmt) talks to `/dev/kfd`, not to the DRI render node, for compute.

Phase **A3-f** from `../docs/design-gpu-amdgpu.md` (there listed DEFERRED:
"a second char device + the KFD ioctls + compute queues / user-mode queues /
doorbells"). Now compile-complete for the core compute surface.

## What compiled (y/n) + result

- **KFD char device + core compute ioctls: YES.** `/dev/kfd` is a second minor
  node (`KFD_MINOR` = 64) on the SAME illumos char device the C1 DRM core
  registers (which the C3-amdgpu transport attaches to). `drm_core.c`'s
  `cb_ioctl` routes a call whose minor == `KFD_MINOR` to `kfd_ioctl`
  (amdkfd/kfd_chardev.c); the DRI minors (card0=0 / renderD128=128) stay on the
  DRM dispatch. This mirrors Linux, where `/dev/kfd` and `/dev/dri/renderD*` are
  distinct char devices sharing the one amdgpu device — same device, two ABIs
  (graphics DRM base `'d'` vs compute KFD base `'K'`).

- **Compute-queue / doorbell mechanism: YES (compile).** `kfd_queue_create`
  (amdkfd/kfd_device_queue_manager.c) registers the user-mode ring + read/write
  pointer VAs, allocates a doorbell dword within the process's doorbell page
  (carved from **BAR2**, now mapped by the C3-amdgpu attach), and returns the
  `queue_id` + `doorbell_offset` the ABI reply needs. The doorbell aperture
  manager (`kfd_doorbell_alloc_page`/`_offset`, amdkfd/kfd_device.c) is real.

- **Zero-phantom undef audit: YES — every undef real.** The full
  DRM + amdgpu + KFD module links `ld -r` to one **ET_REL AMD64** object
  `drm-full` with **131 undefined symbols, ZERO phantom** — every undef resolves
  to a real illumos KPI (unix/genunix/specfs) or the illumos `virtio` module
  export. `verify-syms.sh drm-full` prints
  `zero-phantom OK: all 131 undefined symbols resolve`.
  The KFD objects' external undefs are all real KPI (`ddi_copyin`/`ddi_copyout`/
  `ddi_get_pid`/`kmem_*`/`mutex_*`/`avl_*`/`list_*`/`bzero`/`cmn_err`/
  `gethrtime`) or intra-module symbols resolved at link (`amdgpu_bo_create`/
  `amdgpu_bo_free` from C3-amdgpu TTM, the `kfd_*` cross-file calls, and
  `kfd_ioctl` for the drm_core route) — verified as `.text` (defined), not
  UNDEF, in the linked module.

## LOC

    amdkfd/uapi/kfd_ioctl.h              ~470   the KFD UAPI (verbatim ABI)
    amdkfd/kfd_priv.h                    ~250   the illumos-side model
    amdkfd/kfd_device.c                  ~190   device init + gfx10 apertures + doorbell aperture
    amdkfd/kfd_process.c                 ~160   per-process compute context (keyed by pid)
    amdkfd/kfd_device_queue_manager.c    ~290   queue create/destroy + doorbell + memory alloc/map
    amdkfd/kfd_chardev.c                 ~420   the /dev/kfd ioctl dispatch + handlers
    ---------------------------------------------------------------------------
    KFD kernel source (excl test)       ~1771 LOC
    amdkfd/test_kfd.c                    ~121   userland self-check (ABI/doorbell/apertures)

Plus the small integration edits: BAR2 (doorbell) mapping + `kfd_chardev_bind`
in `amdgpu/amdgpu.c`; the KFD minor node + ioctl route in `src/drm_core.c`; the
`sched`/`sched_ready` members + `drm_sched.h` include in `amdgpu/amdgpu_ip.h`
(a pre-existing C3-amdgpu-d header gap that blocked the full-module link); and
`DRM_COMMAND_BASE` in `src/uapi/drm/drm.h` (a pre-existing UAPI gap the virtgpu
ioctls need).

## The ioctl surface (amdkfd/uapi/kfd_ioctl.h — the ABI preserved verbatim)

The struct layouts + ioctl command numbers ARE the Linux amdkfd UAPI (crib:
Linux `include/uapi/linux/kfd_ioctl.h` @ v1.14), so an unmodified libhsakmt
compiled against the real Linux header produces the same cmd numbers this
kernel switches on. Only the `_IOC` encoding is re-expressed over the illumos
DRM/KFD bit layout (base `'K'`), the same shim RADV/ANV/the C1 drm.h use. The
self-check asserts `AMDKFD_IOWR(0x02, 88)` (CREATE_QUEUE) is bit-for-bit equal
to the Linux `_IOWR('K', 0x02, ...)`.

**Wired (dispatched + handled):**

| ioctl | nr | handler | what it does |
|---|---|---|---|
| GET_VERSION | 0x01 | kfd_ioctl_get_version | report KFD ABI 1.14 (the thunk's version gate) |
| CREATE_QUEUE | 0x02 | kfd_ioctl_create_queue | the load-bearing compute-dispatch ioctl: register ring/ptr VAs, alloc a doorbell dword, return queue_id + doorbell_offset |
| DESTROY_QUEUE | 0x03 | kfd_ioctl_destroy_queue | tear down a queue + release its doorbell/HWS state |
| GET_CLOCK_COUNTERS | 0x05 | kfd_ioctl_get_clock_counters | CPU/system counter via gethrtime; GPU counter hw-gated |
| GET_PROCESS_APERTURES | 0x06 | kfd_ioctl_get_process_apertures | report the gfx10 GPUVM/LDS/scratch VA windows (the topology) |
| GET_PROCESS_APERTURES_NEW | 0x14 | kfd_ioctl_get_process_apertures_new | same, unbounded-GPU form (user array ptr) |
| ACQUIRE_VM | 0x15 | kfd_ioctl_acquire_vm | bind the KFD process to a DRM render-node fd (shared GPUVM) |
| ALLOC_MEMORY_OF_GPU | 0x16 | kfd_ioctl_alloc_memory_of_gpu | allocate a GPU BO (VRAM/GTT via C3-amdgpu TTM), return handle + mmap offset |
| FREE_MEMORY_OF_GPU | 0x17 | kfd_ioctl_free_memory_of_gpu | release the BO |
| MAP_MEMORY_TO_GPU | 0x18 | kfd_ioctl_map_memory_to_gpu | map a BO into the process GPUVM (n_success accounting) |
| UNMAP_MEMORY_FROM_GPU | 0x19 | kfd_ioctl_unmap_memory_from_gpu | unmap |
| SET_SCRATCH_BACKING_VA | 0x11 | kfd_ioctl_set_scratch_backing_va | record the per-process scratch backing VA |
| AVAILABLE_MEMORY | 0x23 | kfd_ioctl_available_memory | report VRAM size (from the C3-amdgpu attach) |

**Deferred (return ENOTTY; ABI numbers + struct shapes present in the header so
a handler slots in without touching the dispatch key):** SET_MEMORY_POLICY
(0x04), UPDATE_QUEUE (0x07), the event ioctls CREATE/DESTROY/SET/RESET/
WAIT_EVENTS (0x08–0x0C), GET_TILE_CONFIG (0x12), SET_TRAP_HANDLER (0x13),
SET_CU_MASK (0x1A), GET_QUEUE_WAVE_STATE (0x1B), the dmabuf ioctls (0x1C/0x1D/
0x24), ALLOC_QUEUE_GWS (0x1E), SMI_EVENTS (0x1F), SVM (0x20), SET_XNACK_MODE
(0x21), CRIU (0x22), DBG_TRAP (0x26). None is on the core compute path
libhsakmt requires to create queues + allocate/map memory + dispatch.

## The compute-queue / doorbell mechanism (the ROCm dispatch primitive)

A KFD **user-mode queue** is the low-latency compute-dispatch primitive: the
ROCm runtime allocates the ring + the read/write-pointer dwords in GPU-mapped
memory (ALLOC_MEMORY_OF_GPU), CREATE_QUEUE registers those addresses + assigns
a **doorbell** (a 32-bit MMIO slot in the BAR2 aperture), and thereafter
userland submits by writing its ring's new write pointer to the doorbell — **no
syscall per submit**. The GPU's hardware scheduler (HWS) / MES notices the
doorbell write and dispatches the queue.

What compiled here:
- the **doorbell aperture** over BAR2 (`kfd_doorbell_aperture`): a per-process
  page bitmap (`KFD_MAX_DOORBELL_PROCESSES` = 128 pages), `kfd_doorbell_offset`
  = `page*4096 + doorbell_id*4` (crib: kfd_doorbell.c
  `kfd_get_doorbell_dw_offset_in_bar`). BAR2 is now mapped by the C3-amdgpu
  attach (`amdgpu/amdgpu.c` `amdgpu_map_bars`, doorbell_base from PCI
  `PCI_CONF_BASE2`).
- the **queue bookkeeping**: `kfd_queue` (ring base/size, rptr/wptr VAs, eop +
  ctx-save-restore, doorbell id/offset), one per process page slot, on the
  process's queue list + idr.
- the **per-process context** `kfd_process` keyed by illumos `pid_t` (Linux
  keys off `mm_struct`; `ddi_get_pid` gives the calling pid in `cb_ioctl`),
  owning the queues + memory allocations + doorbell page, torn down on the last
  `/dev/kfd` close.

## What is compile-complete vs HARDWARE-GATED

**Compile-complete (runs + returns the correct ABI reply off-hardware):** the
char device + ioctl dispatch, version/topology/apertures negotiation, acquire_vm
+ scratch-backing bookkeeping, memory alloc (via the real C3-amdgpu
amdgpu_bo_create TTM path) + free + map/unmap accounting, queue create/destroy +
the doorbell slot assignment + the doorbell_offset math, and the per-process
lifecycle. The self-check (`test_kfd.c`) asserts the ABI encoding equivalence,
the doorbell offset math, the page-bitmap alloc/free reuse, and the gfx10
aperture ordering — PASS.

**HARDWARE-GATED (needs firmware + a powered V520 — the C3-amdgpu-d gate):**
- the **live MQD write + HWS/MES runlist map** for a created queue (write the
  memory queue descriptor into a GTT BO, then a PM4 MAP_QUEUES packet through
  the MES/HWS packet manager so the GPU scheduler dispatches it). The queue is
  "created" off-hardware (the ABI reply + the doorbell slot are real) but not
  GPU-mapped (`q->mapped = B_FALSE`).
- the **GPUVM PTE program** for a mapped allocation (walk the BO's DMA cookies,
  write the GART/page-table entries, flush the TLB) — the C3-amdgpu-d gart path.
- the **doorbell BAR2 mmap fault** (the aperture is empty without a device, so
  `kfd_doorbell_alloc_page` returns ENOSPC off-hardware, a clean non-fatal
  hardware-gated condition — the process context still exists).
- the **HWS/MES firmware** (the MEC/MES microcode) + the SDMA/compute engine
  power-up — all C3-amdgpu-d, hardware-gated already.
- the **events** (interrupt-driven signal events over the IH ring), the **SVM**
  memory manager (page-fault-driven migration), and the **debugger/CRIU** paths
  are the deferred non-core surface.

Don't rabbit-hole on the MES/HWS packet formats — they are hardware-gated and
need the live silicon + firmware to validate.

## The ROCm userspace next step (what libhsakmt / ROCr needs from the KFD)

With `/dev/kfd` + the core ioctls compiling, the ROCm runtime stack layers on
top:

    HIP / rocBLAS / the accelerated-ML runtime   (application compute)
    ------------------------------------------------------------------
    ROCr (the HSA runtime, libhsa-runtime64)     (queues, signals, memory)
    ------------------------------------------------------------------
    libhsakmt (the HSA kernel-mode thunk)         (the /dev/kfd ioctl client)
    ------------------------------------------------------------------
    /dev/kfd + AMDKFD_IOC_*  (THIS layer)         (the KFD compute surface)
    ------------------------------------------------------------------
    C3-amdgpu device (BARs / TTM / rings / BAR2 doorbell)  +  C1 DRM

**libhsakmt** (the next layer to port/build on illumos) is a thin userspace
library that:
1. **opens `/dev/kfd`** and calls **GET_VERSION** (the 1.14 ABI this port
   reports) — the compatibility gate. ✓ compiles here.
2. reads the topology from **sysfs** (`/sys/devices/virtual/kfd/kfd/topology/
   nodes/*` on Linux) AND from **GET_PROCESS_APERTURES** — the GPUVM/LDS/
   scratch windows this port reports for gfx10. ✓ the ioctl compiles; the
   sysfs topology is a **solnix gap** (illumos has no `/sys` — libhsakmt's
   topology reader needs an illumos shim: a small procfs/ioctl topology
   surface or a KFD GET_TOPOLOGY ioctl the thunk is patched to call).
3. opens the DRM render node + calls **ACQUIRE_VM** to share the GPUVM. ✓
   compiles.
4. **ALLOC_MEMORY_OF_GPU** + **MAP_MEMORY_TO_GPU** for the ring buffers,
   kernel argument buffers, and compute allocations (the ones HIP/rocBLAS
   allocate). ✓ compiles (backed by the C3-amdgpu TTM).
5. **CREATE_QUEUE** for each HSA queue, mmaps `/dev/kfd` at the returned
   `doorbell_offset` to get the doorbell MMIO slot, then dispatches by writing
   the AQL packet ring + ringing the doorbell. ✓ the ioctl + doorbell offset
   compile; the **doorbell mmap fault + the live HWS dispatch are
   hardware-gated**.

So the immediate userspace milestone after this kernel port: **build libhsakmt
on illumos** (it is a small C library — the main port work is the topology
reader, which assumes Linux `/sys`, plus the `hsaKmt*` ioctl wrappers that map
1:1 onto the AMDKFD_IOC_* this port dispatches). Then **ROCr** (the HSA
runtime) on top of libhsakmt, then **HIP** — the accelerated-ML runtime. The
compute path is now unblocked at the kernel/ABI level exactly as RADV unblocked
the graphics-Vulkan path.

## Build + verify (from ../, on the g4ad/DRM node)

    make kfd            # compiles C1 + amdgpu + KFD -> drm-full (ET_REL AMD64)
                        # + runs verify-syms.sh drm-full (zero-phantom)
    make test-kfd       # amdkfd/test_kfd.c -> "C3-KFD logic self-check: PASS"

Result: **25 objects compile, 131 undefs, ZERO phantom, self-check PASS.**

## Files

    amdkfd/uapi/kfd_ioctl.h              the KFD UAPI (ABI preserved verbatim, base 'K')
    amdkfd/kfd_priv.h                    kfd_dev / kfd_process / kfd_queue / kfd_mem / doorbell model
    amdkfd/kfd_device.c                  kfd_device_init + gfx10 apertures + doorbell aperture manager
    amdkfd/kfd_process.c                 per-process compute context (keyed by illumos pid)
    amdkfd/kfd_device_queue_manager.c    queue create/destroy + doorbell alloc + memory alloc/map
    amdkfd/kfd_chardev.c                 the /dev/kfd ioctl dispatch + per-command handlers
    amdkfd/test_kfd.c                    userland self-check
    (integration) amdgpu/amdgpu.c        + BAR2 doorbell map + kfd_chardev_bind/unbind
    (integration) amdgpu/amdgpu_priv.h   + doorbell_base/size softc fields
    (integration) amdgpu/amdgpu_ip.h     + sched/sched_ready + drm_sched.h (pre-existing gap)
    (integration) src/drm_core.c         + /dev/kfd minor node + minor-based ioctl route
    (integration) src/uapi/drm/drm.h     + DRM_COMMAND_BASE (pre-existing UAPI gap)

## Crib provenance

The KFD kernel logic is cribbed from the Linux amdkfd driver
(`drivers/gpu/drm/amd/amdkfd/`): kfd_chardev.c (the ioctl entry + handlers),
kfd_process.c (the per-process context), kfd_device_queue_manager.c +
kfd_queue.c (the queue create/destroy), kfd_doorbell.c (the doorbell aperture),
kfd_device.c (the device init), kfd_flat_memory.c (the gfx9/v10 apertures). The
UAPI is verbatim from `include/uapi/linux/kfd_ioctl.h` @ v1.14. No Linux `.c` is
lifted — each primitive is re-expressed against the illumos DDI/kmem/ksynch KPI
+ the C1 shim (idr/list) + the C3-amdgpu device (BARs/TTM/BAR2 doorbell), the
same crib-and-adapt doctrine as C3-amdgpu itself.
