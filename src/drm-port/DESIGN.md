# solnix DRM/KMS port — layer-by-layer illumos mapping (C1a design)

Phase **C1a** of the compute keystone in `docs/design-gpu-compute-parity.md`
(illumos DRM/KMS core, cribbed from NetBSD `sys/external/bsd/drm2`). This
document maps each NetBSD drm2 layer to its illumos DDI/VM/ksynch equivalent,
records provenance per file, and marks what is done in C1a versus deferred to
C1b (KMS) / C1c (dma-buf + scheduler).

Crib reference: `netbsd-ref/` — NetBSD-current git
`5a7765109d6feb3a897b349b8d58572a0b7812f2` (see `netbsd-ref/README.md`).

## The three-strata model (unchanged from the substrate analysis)

NetBSD's drm2 is three layers, bottom to top:

1. **Imported Linux DRM (`dist/`, ~500k LOC)** — the drm core, KMS helpers,
   GEM, TTM, scheduler, and per-GPU drivers, RCS-tagged Linux source. **solnix
   does NOT rewrite or lift this.** It is the reference for the ABI and the
   semantics the shim must satisfy.
2. **The linux-KPI shim (`drm2/linux` + `common/linux`, ~14k LOC + 178 headers)**
   — NetBSD's emulation of the Linux kernel API on BSD primitives. **This is the
   crib.** solnix re-implements this boundary against illumos DDI (it does not
   lift NetBSD's .c; it maps each primitive, using NetBSD's shim as the
   checklist of *which* Linux APIs must be emulated).
3. **NetBSD<->drm glue (`drm2/drm`, ~4.4k LOC)** — binds the Linux core to the
   NetBSD device model (cdevsw, module, `/dev/dri/*`). **solnix rewrites this
   against illumos `dev_ops`/`cb_ops`.** The C1a `src/drm_core.c` is the first
   piece of this stratum.

The illumos-relevant porting surface is stratum 2 + 3 (~18-20k LOC), not the
500k of Linux drivers.

## Layer -> illumos mapping

### A. drm core + char device  (`drm2/drm/drm_cdevsw.c`, `drm_module.c`, `drm_stub.c`, `dist/drm/drm_drv.c`, `drm_ioctl.c`, `drm_file.c`)

| NetBSD construct | illumos equivalent | C1a status |
|---|---|---|
| `struct cdevsw drm_cdevsw` (`.d_open`, `.d_mmap`) | `struct cb_ops` (`cb_open`, `cb_devmap`) | DONE (`src/drm_core.c`) |
| `struct fileops drm_fileops` (`.fo_ioctl`, `.fo_close`, `.fo_poll`, `.fo_mmap`) | `cb_ops` (`cb_ioctl`, `cb_close`, `cb_chpoll`, `cb_devmap`) | ioctl/close DONE; poll/mmap stubbed (C1b) |
| `drm_ioctl_shim()` -> `drm_ioctl()` dispatch table | `drm_ioctl()` switch on DRM cmd nr | DONE (VERSION + GEM subset) |
| `MODULE(MODULE_CLASS_DRIVER, drmkms, ...)` modcmd | `_init`/`_fini`/`_info` + `modlinkage`/`modldrv` | DONE |
| per-`device_t` `struct drm_device` | per-instance `ddi_soft_state` `struct drm_device` | DONE |
| static `/dev/dri/card*` + `render*` via cdevsw major | `ddi_create_minor_node("card0"/"renderD128", DDI_NT_DISPLAY)` + a devfsadm rule linking `/dev/dri/` | node creation DONE; devfsadm rule = C1b |
| `dev->driver->{name,date,desc,major}` | `struct drm_driver` (`src/drm_internal.h`) | DONE (virtio-gpu identity) |
| `drm_copy_field()` (VERSION string contract) | `drm_copy_field()` w/ `ddi_copyout` | DONE (`src/drm_core.c`) |
| `copy_from_user`/`copy_to_user` | `ddi_copyin`/`ddi_copyout` (mode-aware) | DONE |

The DRM **userland ABI is preserved verbatim** (`src/uapi/drm/drm.h`): the
ioctl numbers and struct layouts are the Linux DRM UAPI, so libdrm/Mesa talk to
the illumos node unchanged — the whole payoff of the NetBSD-shim approach.

### B. GEM (buffer objects)  (`dist/drm/drm_gem.c`, `drm2/drm/drm_gem_vm.c`, `drm_vma_manager.c`)

| Linux/NetBSD GEM | illumos equivalent | C1a status |
|---|---|---|
| `drm_gem_object_init()` (shmem/uvm-backed pages) | `kmem_zalloc` kernel buffer (stub); real: `ddi_umem_alloc` + cookie | stub DONE; real backing C1b |
| `drm_gem_handle_create()` (idr handle table) | `idr` on illumos `avl_tree_t` (`src/linux-compat/linux_compat.h`) | DONE |
| `struct kref` on GEM object | `uint_t` + `atomic_inc/dec_uint_nv` | DONE |
| `DRM_IOCTL_MODE_CREATE_DUMB` | `drm_gem_create_dumb()` (pitch/size/handle) | DONE |
| `DRM_IOCTL_MODE_MAP_DUMB` (fake mmap offset) | `drm_gem_map_dumb()` returns offset | offset DONE; page fault-in = C1b |
| `DRM_IOCTL_MODE_DESTROY_DUMB` / `GEM_CLOSE` | `drm_gem_destroy_dumb()` / `drm_gem_close_ioctl()` | DONE |
| `drm_gem_mmap()` -> uvm fault -> pages | illumos `cb_devmap` -> `devmap_umem_setup()`/`devmap_devmem_setup()` (`ddidevmap.h`) | C1b |
| `drm_vma_offset_manager` (mmap offset alloc) | monotonic offset (stub); real: `id_space`/`vmem` arena | stub DONE; real C1b |

GEM's job is: allocate a buffer, hand userland an opaque 32-bit handle, refcount
it, and let userland mmap it. C1a implements the handle/refcount/lifecycle
against illumos primitives; the page-backing + fault path is the C1b item (it
needs `cb_devmap` + `devmap_umem_setup`, which is where illumos VM enters).

### C. TTM (VRAM / GTT placement)  (`drm2/ttm/ttm_bo_vm.c`, `ttm_bus_dma.c`, `ttm_agp_backend.c`)

TTM manages *where* a buffer lives (system RAM vs VRAM vs GART/GTT aperture) and
migrates it. It is only needed for discrete-VRAM GPUs; **virtio-gpu (the C1a/C1b
target) has no VRAM** — its buffers are host-shared system pages — so TTM is
**not on the C1a/C1b critical path**. Mapping for when a real VRAM GPU is
targeted (C3):

| TTM concept | illumos equivalent |
|---|---|
| TTM system-memory pool | `kmem`/`ddi_umem` pages |
| TTM VRAM manager (BAR-mapped device memory) | `ddi_regs_map_setup` on the GPU BAR + `devmap_devmem_setup` for mmap |
| `ttm_bus_dma` (GART/scatter-gather DMA) | `ddi_dma_alloc_handle` / `ddi_dma_addr_bind_handle` / cookies |
| TTM eviction / LRU migration | illumos VM has no direct analogue — bespoke, driven by the ddi_dma + regs layers |

### D. dma-buf / dma-fence / reservation objects  (`linux_dma_buf.c`, `linux_dma_fence*.c`, `linux_dma_resv.c`, `linux_sync_file.c`, `linux_sgt.c`)

This is the **cross-driver buffer-sharing + GPU synchronization** layer compute
depends on (a Vulkan/compute queue signals a fence; another consumer waits;
buffers are shared by fd). Deferred to **C1c** (it is not needed to register a
node or create a GEM object). Mapping:

| Linux primitive | illumos equivalent | phase |
|---|---|---|
| `struct dma_fence` (signal/wait, callbacks) | `kcondvar_t` + `kmutex_t` + `kref`; callbacks via `taskq` | C1c |
| `dma_fence_chain` / `dma_fence_array` | compose over the above | C1c |
| `struct dma_resv` (reservation object, ww-locked) | `kmutex_t` set + `ww_mutex` shim (below) | C1c |
| `struct dma_buf` (fd-exported buffer) | illumos has no fd-sharing of kernel buffers; export via a per-buffer minor node or a `ksensor`-style handle table, fd passed through `/dev/dri` | C1c (design open) |
| `struct sg_table` (scatter-gather) | `ddi_dma_cookie_t` array from `ddi_dma_*_bind_handle` | C1c |
| `sync_file` (fd-wrapped fence) | fence handle table + a minor node | C1c |

`dma_buf` fd-passing is the one primitive with **no clean illumos analogue** and
is flagged as the hardest sub-item of C1c (illumos does not pass kernel buffer
objects across processes by fd the way Linux does; the port needs a handle
table + a mechanism to hand userland a reference).

### E. the linux_* compat shims (the bulk of the crib)

| Linux KPI | NetBSD shim file | illumos equivalent | C1a status |
|---|---|---|---|
| `struct kref` | `include/linux/kref.h` | `uint_t` + `atomic_inc/dec_uint_nv` (`sys/atomic.h`) | DONE |
| `struct idr` (id->ptr) | `linux_idr.c` | `avl_tree_t` (C1a) -> `id_space(9F)` (real) | DONE (avl) |
| `struct mutex` | `include/linux/mutex.h` | `kmutex_t` + `mutex_enter/exit` (`sys/ksynch.h`) | DONE |
| `spinlock_t` | `include/linux/spinlock.h` | `kmutex_t` (MUTEX_DRIVER) | DONE |
| `kmalloc`/`kfree`/`kzalloc` | `include/linux/slab.h` | `kmem_alloc`/`kmem_free`/`kmem_zalloc` (`sys/kmem.h`) | DONE |
| `struct workqueue`/`work_struct` | `common/linux/linux_work.c` | `ddi_taskq_create` + `ddi_taskq_dispatch` (`sys/sunddi.h`) | C1b |
| `struct task_struct`/`kthread_run` | `linux_kthread.c` | `thread_create` + `cv`/`mutex` | C1b |
| `struct completion` | `include/linux/completion.h` | `kcondvar_t` + `kmutex_t` (`cv_wait`/`cv_signal`) | C1b |
| `struct ww_mutex` (wound/wait) | `linux_ww_mutex.c` | bespoke over `kmutex_t` + `kcondvar_t` (GEM/dma-resv need it) | C1c |
| `struct rw_semaphore` | `linux_rwsem.c` | `krwlock_t` (`rw_enter`/`rw_exit`) | C1b |
| `rcu` / `srcu` | `common/linux/linux_rcu.c`, `linux_srcu.c` | no illumos RCU; emulate with a quiescent-state barrier or a global rwlock (`NOTE: global rwlock, per-domain if contended`) | C1c |
| `radixtree` / `xarray` | `linux_radixtree.c`, `linux_xa.c` | `avl_tree_t` or `mod_hash` | C1c |
| `hrtimer` / `irq_work` | `linux_hrtimer.c`, `linux_irq_work.c` | `ddi_periodic_add` / `timeout(9F)` / taskq | C1b |
| `struct pci_dev` + BAR/MSI | `linux_pci.c` | `pci_config_*` + `ddi_regs_map_setup` + `ddi_intr_*` | C1b (bus attach) |
| `ioremap` / write-combining | `linux_io_mapping.c`, `linux_writecomb.c` | `ddi_regs_map_setup` + PAT/MTRR via ddi | C1b |
| `copy_to/from_user` | `include/linux/uaccess.h` | `ddi_copyin`/`ddi_copyout` | DONE |

### F. virtio-gpu — the first target  (`dist/include/uapi/drm/virtgpu_drm.h`)

QEMU `-device virtio-gpu` (or `virtio-vga` / `virtio-gpu-gl`) presents a paravirt
GPU over virtio — **no real GPU, cheap CI**. It is the right first target because:

- virtio-gpu buffers are **host-shared system pages** — no VRAM, so **no TTM**
  needed on the critical path (see C above).
- illumos already has a **virtio framework** (`virtio(7D)`, `vioblk`/`vioif`
  bind to virtio PCI) — the bus-attach half of `linux_pci.c` is partly solved by
  binding the drm node as a virtio child (C1b).
- the C1a node reports the `virtio_gpu` driver identity via `DRM_IOCTL_VERSION`,
  so a libdrm probe would match a virtio-gpu node exactly as on Linux/NetBSD.

C1b wires the C1a node to the illumos virtio transport (virtqueues for the
virtio-gpu control/cursor queues, `VIRTIO_GPU_CMD_*`), does the modeset
(`VIRTIO_GPU_CMD_SET_SCANOUT`), and turns MAP_DUMB into a real `cb_devmap`
fault-in of the GEM pages.

## What compiles today (C1a) — the load-bearing piece

`src/` builds to a single `ET_REL` AMD64 kernel object `drm` against the
installed illumos kernel headers (`/usr/include`, `-D_KERNEL -ffreestanding
-nostdinc`). It contains:

- `drm_core.c` — `dev_ops`/`cb_ops`, `_init`/`_fini`/`_info`, `attach` creating
  `card0` + `renderD128` minor nodes, the DRM ioctl dispatch, and
  `DRM_IOCTL_VERSION` (ABI-faithful, virtio-gpu identity).
- `drm_gem.c` — GEM create/map/destroy/close dumb-buffer ioctls, kmem-backed,
  refcounted, handle table.
- `linux-compat/linux_compat.h` — the C1a shim subset (kref, idr, mutex, kmem).
- `uapi/drm/drm.h` — the preserved Linux DRM UAPI subset.

**Every undefined symbol in the linked object is a real illumos kernel KPI**
(`ddi_soft_state_*`, `ddi_create_minor_node`, `ddi_copyin/out`, `mod_install`,
`mutex_*`, `avl_*`, `kmem_*`, `atomic_dec_uint_nv`, `nochpoll`/`nodev`,
`mod_driverops`, `_pagesize`) — no unresolved Linux symbols. The shim fully
absorbed the Linux KPI surface the stub touches into illumos primitives, which
is the C1a proof: the impedance boundary is real and mappable.

## Next phases

- **C1b (KMS + real backing):** wire the node to illumos virtio; `cb_devmap` +
  `devmap_umem_setup` for GEM mmap; workqueue->taskq, kthread, completion,
  pci/BAR shims; the virtio-gpu control queue + `SET_SCANOUT` modeset;
  devfsadm rule for `/dev/dri/`. First visible milestone: a virtio-gpu modeset.
- **C1c (dma-buf + scheduler for compute):** dma-fence (cv-backed),
  dma-resv/ww_mutex, dma-buf fd-sharing (the hard illumos gap), sync_file, the
  drm scheduler. This is what Vulkan-compute / render-node consumers need.
