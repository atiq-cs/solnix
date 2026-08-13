# solnix DRM/KMS port — layer-by-layer illumos mapping (C1a + C1b + C1c)

Phase **C1a/C1b/C1c** of the compute keystone in `docs/design-gpu-compute-parity.md`
(illumos DRM/KMS core, cribbed from NetBSD `sys/external/bsd/drm2`). This
document maps each NetBSD drm2 layer to its illumos DDI/VM/ksynch equivalent,
records provenance per file, and marks what is done in C1a, C1b (KMS + real GEM
backing + virtio-gpu), versus deferred to C1c (dma-buf + scheduler).

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
| `struct fileops drm_fileops` (`.fo_ioctl`, `.fo_close`, `.fo_poll`, `.fo_mmap`) | `cb_ops` (`cb_ioctl`, `cb_close`, `cb_chpoll`, `cb_devmap`) | ioctl/close/devmap DONE (C1b); poll stubbed (C1c) |
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
| `drm_gem_object_init()` (shmem/uvm-backed pages) | `ddi_umem_alloc` + cookie (`src/drm_gem.c`) | DONE (C1b) |
| `drm_gem_handle_create()` (idr handle table) | `idr` on illumos `avl_tree_t` (`src/linux-compat/linux_compat.h`) | DONE |
| `struct kref` on GEM object | `uint_t` + `atomic_inc/dec_uint_nv` | DONE |
| `DRM_IOCTL_MODE_CREATE_DUMB` | `drm_gem_create_dumb()` (pitch/size/handle) | DONE |
| `DRM_IOCTL_MODE_MAP_DUMB` (mmap offset) | `drm_gem_map_dumb()` returns devmap offset | DONE |
| `DRM_IOCTL_MODE_DESTROY_DUMB` / `GEM_CLOSE` | `drm_gem_destroy_dumb()` / `drm_gem_close_ioctl()` | DONE |
| `drm_gem_mmap()` -> uvm fault -> pages | `cb_devmap` -> `devmap_umem_setup()` on the GEM umem cookie (`src/drm_core.c` `drm_devmap`) | DONE (C1b) |
| `drm_vma_offset_manager` (mmap offset alloc) | monotonic per-device offset + O(n) range lookup (`drm_gem_object_lookup_offset`) | DONE (C1b; O(n), AVL upgrade noted) |

GEM's job is: allocate a buffer, hand userland an opaque 32-bit handle, refcount
it, and let userland mmap it. C1a implemented the handle/refcount/lifecycle;
**C1b makes the backing real** (`ddi_umem_alloc` gives kernel-VA pages + a
cookie) and turns MAP_DUMB into an actual fault-in: `cb_devmap` (`drm_devmap`)
resolves the offset back to the GEM object via `drm_gem_object_lookup_offset`
and calls `devmap_umem_setup(9F)` on the object's umem cookie, so a userland
mmap of the DRI node faults in exactly the object's pages. Those same pages are
what the virtio-gpu `RESOURCE_ATTACH_BACKING` hands the host.

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
| `struct dma_fence` (signal/wait, callbacks) | `kref` + `kmutex_t` + `kcondvar_t` + flags word + callback `list_t`; callbacks fire under the fence lock (`src/drm_dma.c`) | **C1c DONE** |
| `dma_fence_chain` / `dma_fence_array` | compose over the above | deferred (not needed for virtio-gpu single-queue) |
| `struct dma_resv` (reservation object, ww-locked) | `ww_mutex` + excl fence + shared-fence array (`src/drm_dma.c`) | **C1c DONE** |
| `struct dma_buf` (fd-exported buffer) | **PRIME fd over `falloc` + a spec-vnode of this drm device at a private minor** (`src/drm_prime.c`) — see "D.1 the dma-buf-fd mechanism" below | **C1c DONE (design + compile)** |
| `struct sg_table` (scatter-gather) | `ddi_dma_cookie_t` array (the virtio `virtio_dma_cookie_pa` list RESOURCE_ATTACH_BACKING already uses, C1b) | mapped (uses C1b path) |
| `sync_file` (fd-wrapped fence) | same `falloc`+spec-vnode fd mechanism as PRIME, minor -> `struct sync_file` holding a fence ref (`src/drm_prime.c`) | **C1c DONE (compile; poll wiring pending)** |
| `struct ww_mutex` (wound/wait) | `kmutex_t`+`kcondvar_t`, ticket-ordered wound/wait (`src/drm_dma.c`) | **C1c DONE** |
| drm GPU scheduler | single FIFO run-queue + one worker kthread; jobs carry a finished dma_fence (`src/drm_sched.c`) | **C1c DONE** |

### D.1 the dma-buf-fd mechanism (the load-bearing C1c design)

Linux exports a GEM buffer as a `dma_buf` fd: an *anonymous* `struct file` whose
`f_op` is `dma_buf_fops` and whose private data owns the pages; another
process/driver receives the fd (over `SCM_RIGHTS`) and re-derives the sg-table.
illumos has **no anonymous-file dma-buf type** — the gap this section flagged.
But illumos has the two ingredients Linux's dma-buf is built from:

1. `falloc(9F)` — the kernel side of `open(2)`: mint a `file_t` + an fd bound to
   a vnode. Any subsystem can create an fd.
2. `makespecvp()` — a *spec (device) vnode* over a `dev_t`; `mmap`/`close` of a
   spec vnode route to the owning driver's `cb_ops`.

So the **solnix PRIME fd** is: an fd from `falloc()` whose `file_t->f_vnode` is a
spec-vnode over *this drm device's own char node* (`ddi_driver_major(dip)`) at a
private per-export minor (`>= DRM_PRIME_MINOR_BASE`, allocated off
`drm_device->prime_next_minor`) encoding which GEM handle was exported. Because
it is a real fd over our own device:

- it is passed across processes by the illumos `SCM_RIGHTS` / `I_SENDFD`
  mechanism exactly like any other fd — the load-bearing requirement Mesa/GBM
  need for render-node + cross-process buffer sharing;
- `mmap(fd)` faults through *this driver's* `cb_devmap` (C1b) onto the GEM
  object's `ddi_umem` pages — the same pages `RESOURCE_ATTACH_BACKING` hands the
  host — so the importer sees the exact buffer. `cb_devmap` recognizes an export
  minor (`>= DRM_PRIME_MINOR_BASE`) and resolves it via
  `drm_prime_devmap_object` instead of the C1b mmap-offset lookup;
- the import side (`DRM_IOCTL_PRIME_FD_TO_HANDLE`) reverses it with `getf(fd) ->
  fp->f_vnode -> getminor -> the export -> the GEM object`, re-issues a handle in
  the importing client's table + takes a reference. No Linux `dma_buf_ops`
  needed.

This reuses the C1b devmap path rather than inventing a second mmap route, and
is pure real-KPI: `falloc`/`getf`/`releasef`/`setf`/`vn_rele`/`ddi_driver_major`
are `T` (defined) in genunix and `makespecvp` is `T` in the always-loaded
`specfs` module — verified. `sync_file` uses the identical fd mechanism (minor
-> `struct sync_file` -> a fence ref); its `poll(2)` POLLIN-on-signal wiring
lands when the drm node's `cb_chpoll` + a `pollwakeup(9F)` event queue are added
(currently `nochpoll`; the fence-callback half is already in place).

**C1c divergence from NetBSD: no RCU.** NetBSD's `linux_dma_fence.c` /
`linux_dma_resv.c` use RCU for lockless fence readers. illumos has no RCU, so
every reader in `drm_dma.c` takes the fence/resv lock. Correct, just not
lockless; the section-E `NOTE` (global-rwlock/quiescent RCU emulation) is the
upgrade path if lockless fence reads ever show up hot.

### E. the linux_* compat shims (the bulk of the crib)

| Linux KPI | NetBSD shim file | illumos equivalent | C1a status |
|---|---|---|---|
| `struct kref` | `include/linux/kref.h` | `uint_t` + `atomic_inc/dec_uint_nv` (`sys/atomic.h`) | DONE |
| `struct idr` (id->ptr) | `linux_idr.c` | `avl_tree_t` (C1a) -> `id_space(9F)` (real) | DONE (avl) |
| `struct mutex` | `include/linux/mutex.h` | `kmutex_t` + `mutex_enter/exit` (`sys/ksynch.h`) | DONE |
| `spinlock_t` | `include/linux/spinlock.h` | `kmutex_t` (MUTEX_DRIVER) | DONE |
| `kmalloc`/`kfree`/`kzalloc` | `include/linux/slab.h` | `kmem_alloc`/`kmem_free`/`kmem_zalloc` (`sys/kmem.h`) | DONE |
| `struct workqueue`/`work_struct` | `common/linux/linux_work.c` | `ddi_taskq_create` + `ddi_taskq_dispatch` (`sys/taskq.h`) | DONE (C1b) |
| `struct task_struct`/`kthread_run` | `linux_kthread.c` | `thread_create` + `p0`/`minclsyspri` (`sys/proc.h`,`sys/disp.h`) | DONE (C1b) |
| `struct completion` | `include/linux/completion.h` | `kcondvar_t` + `kmutex_t` (`cv_wait`/`cv_timedwait`/`cv_broadcast`) | DONE (C1b) |
| `struct ww_mutex` (wound/wait) | `linux_ww_mutex.c` | ticket-ordered wound/wait over `kmutex_t`+`kcondvar_t` (`src/drm_dma.c`) | DONE (C1c) |
| `struct rw_semaphore` | `linux_rwsem.c` | `krwlock_t` (`rw_enter`/`rw_exit`) | DONE (C1b) |
| `rcu` / `srcu` | `common/linux/linux_rcu.c`, `linux_srcu.c` | no illumos RCU; C1c dma-fence/dma-resv take the object lock on every read instead (correct, not lockless); global-rwlock/quiescent emulation is the upgrade path | C1c: lock-per-read |
| `radixtree` / `xarray` | `linux_radixtree.c`, `linux_xa.c` | `avl_tree_t` or `mod_hash` | C1c |
| `hrtimer` / `irq_work` | `linux_hrtimer.c`, `linux_irq_work.c` | `ddi_periodic_add` / `timeout(9F)` / taskq | C1b |
| `struct pci_dev` + BAR/MSI | `linux_pci.c` | illumos `virtio` framework (`virtio_init`) handles PCI/BAR/MSI for virtio children | DONE for virtio (C1b); raw `ddi_regs_map_setup`+`ddi_intr_*` for non-virtio GPUs = C3 |
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

C1b wires the C1a node to the illumos virtio transport and does the modeset.
Implemented in `src/virtio_gpu.c` against the illumos `virtio` framework KPI
(the module `/kernel/misc/amd64/virtio`, whose exports were used as the KPI
checklist — declared in `src/virtio_impl.h`), with the wire protocol cribbed
from Linux/QEMU (`src/virtio_gpu_hw.h`):

- `virtio_gpu_transport_attach()` — `virtio_init` → claim controlq(0)+cursorq(1)
  via `virtio_queue_alloc` → `virtio_init_complete` → read `num_scanouts` from
  device config (`virtio_dev_get32`) → `GET_DISPLAY_INFO` probe.
- `virtio_gpu_exec()` — synchronous command/response over a 2-descriptor
  `virtio_chain_*` on a `virtio_dma_alloc` buffer; submit + `virtio_queue_poll`.
- the `SET_SCANOUT` chain — `RESOURCE_CREATE_2D` → `RESOURCE_ATTACH_BACKING`
  (guest-physical cookies from `virtio_dma_cookie_pa`) → `SET_SCANOUT` →
  `TRANSFER_TO_HOST_2D` → `RESOURCE_FLUSH`, driven by `drm_gem_scanout()` from
  the `DRM_IOCTL_MODE_SET_SCANOUT_SOLNIX` ioctl.

## What compiles today (C1a + C1b + C1c) — the load-bearing piece

`src/` builds to a single `ET_REL` AMD64 kernel object `drm` against the
installed illumos kernel headers (`/usr/include`, `-D_KERNEL -ffreestanding
-nostdinc`). It contains:

- `drm_core.c` — `dev_ops`/`cb_ops`, `_init`/`_fini`/`_info`, `attach` creating
  `card0` + `renderD128` minor nodes, the DRM ioctl dispatch, `DRM_IOCTL_VERSION`
  (ABI-faithful, virtio-gpu identity), and the C1b `cb_devmap` (`drm_devmap`)
  GEM-mmap path via `devmap_umem_setup`.
- `drm_gem.c` — GEM create/map/destroy/close dumb-buffer ioctls, now backed by
  `ddi_umem_alloc` (real pageable memory + cookie), refcounted, handle table,
  the offset->object lookup for `cb_devmap`, and the SET_SCANOUT ioctl bridge.
- `virtio_gpu.c` — virtio-gpu transport attach + 2D modeset (above).
- `virtio_gpu_hw.h` — the virtio-gpu wire protocol (cribbed from Linux UAPI).
- `virtio_impl.h` — the illumos `virtio` framework KPI (declarations matching
  the module's exported symbols; no header shipped under /usr/include).
- `linux-compat/linux_compat.h` — C1a shim (kref, idr, mutex, kmem) + the C1b
  primitives (workqueue→taskq, kthread→thread_create, completion→cv,
  rwsem→krwlock_t).
- `linux-compat/linux_dma.h` + `drm_dma.c` — **C1c** dma-fence (kref + kmutex +
  kcondvar + flags + callback list), ww_mutex (ticket-ordered wound/wait), and
  dma-resv (excl + shared fence array). No RCU (lock-per-read).
- `drm_sched.h` + `drm_sched.c` — **C1c** minimal single-FIFO-queue GPU
  scheduler: one worker kthread drains jobs, each job's finished dma_fence is
  signalled on completion (a submitter waits on it).
- `drm_prime.c` — **C1c** PRIME (dma-buf) handle↔fd export/import + sync_file,
  over `falloc` + a spec-vnode of this device at a private minor (see D.1).
- `uapi/drm/drm.h` — the preserved Linux DRM UAPI subset + `PRIME_HANDLE_TO_FD`
  / `PRIME_FD_TO_HANDLE` + the solnix-private SET_SCANOUT demo ioctl.
- `test/test_c1b.c`, `test/test_c1c.c` — userland self-checks (offset-lookup +
  cmd-buffer math for C1b; fence signal-once, ww_mutex ticket compare, resv
  array growth for C1c) — `make`d + run separately; not part of the kernel
  object.

**Every undefined symbol in the linked object is a real illumos kernel KPI or
an export of the illumos `virtio` module** (`ddi_soft_state_*`,
`ddi_create_minor_node`, `ddi_copyin/out`, `ddi_umem_alloc`,
`devmap_umem_setup`, `mod_install`, `mutex_*`, `avl_*`, `kmem_*`,
`atomic_dec_uint_nv`, `virtio_init`, `virtio_queue_alloc`, `virtio_chain_*`,
`virtio_dma_*`, `virtio_dev_get32`, and the C1c `falloc`/`getf`/`releasef`/
`setf`/`makespecvp`/`vn_rele`/`ddi_driver_major`/`list_*`/`cv_*`/
`atomic_add_64_nv`) — no unresolved Linux symbols, no phantom `dma_buf_*`
virtio symbols (each `virtio_*` undef is verified against the module's
`FUNC GLOB` exports). The shim + KPI declarations fully absorb the Linux KPI
surface into illumos primitives: the impedance boundary is real and mappable.

## Next phases

- **C1c (dma-buf + fence + scheduler for compute) — DONE (compiling):**
  dma-fence (`src/drm_dma.c`, kref+kmutex+kcondvar+flags+callback list),
  ww_mutex (ticket-ordered wound/wait) + dma-resv (excl+shared fence array),
  the single-queue GPU scheduler (`src/drm_sched.c`), and the PRIME (dma-buf)
  handle↔fd + sync_file fd-sharing over `falloc`+spec-vnode (`src/drm_prime.c`,
  the load-bearing design in D.1). All link into the one `ET_REL` object; every
  new undef is real genunix/specfs KPI. This is what Mesa/GBM/Vulkan need for
  buffer synchronization + cross-process/cross-driver buffer sharing, so **C2
  (Mesa/GBM/Vulkan) is now unblockable** at the compile/ABI level.
  Remaining runtime gaps (need a metal QEMU host, not compile-blocking): the
  sync_file `poll(2)` path (drm `cb_chpoll` + `pollwakeup` event queue, still
  `nochpoll`); a second minor space carved out of the drm node for the PRIME/
  sync_file spec-vnodes + `cb_close` teardown on export-minor close; wiring the
  scheduler `run_job` to the virtio-gpu `virtio_gpu_exec` chain; and per-job
  timeout/GPU-reset (C3-era, a real multi-ring GPU).
- **C1b (KMS + real backing) — DONE (compiling):** real GEM backing
  (`ddi_umem_alloc`) + `cb_devmap`/`devmap_umem_setup` mmap; the C1b shim
  primitives (workqueue→taskq, kthread, completion, rwsem); virtio-gpu attach
  over the illumos `virtio` framework + `GET_DISPLAY_INFO` probe; the
  `SET_SCANOUT` 2D modeset chain. All compiles to one `ET_REL` object.
  Remaining C1b polish (not blocking): bind the drm node as an actual virtio
  PCI child in `attach` (currently `virtio_gpu_transport_attach` is written to
  be called from such an attach but the module's own `dev_ops.attach` still
  creates the minor nodes without a `virtio_init` — a real virtio child bind
  restructures `_init` to register under the virtio bus); a devfsadm rule for
  `/dev/dri/`; and the completion-interrupt path instead of `virtio_queue_poll`.
  A QEMU `-device virtio-gpu` boot (needs KVM; this build host is a non-metal
  EC2 instance with TCG-only QEMU) is the unreached run-time stretch.
