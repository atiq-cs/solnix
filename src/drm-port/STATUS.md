# solnix DRM/KMS port — STATUS

## Phase reached: C1b (real GEM backing + mmap + virtio-gpu attach + SET_SCANOUT path, all COMPILING against illumos headers)

C1b builds on the C1a drm-core/GEM stub. The whole DRM module — core + GEM +
virtio-gpu transport + 2D modeset — compiles as a single `ET_REL` AMD64 kernel
object against the installed illumos kernel headers, with every undefined
symbol resolving to a real illumos KPI or an export of the illumos `virtio`
kernel module. No phantom Linux symbols, no phantom virtio symbols.

It is still a COMPILE milestone: the code is written to run (it drives the real
illumos virtio KPI and the real devmap/umem KPI), but it is not verified booting
under QEMU (see "QEMU stretch" below). Getting the C1b pieces to compile against
illumos headers is the C1b deliverable.

## What compiles (verified)

    cd /root/drm-port && make
      -> src/drm_core.o    ELF 64-bit LSB relocatable AMD64   (ET_REL, EM_AMD64)
      -> src/drm_gem.o     ELF 64-bit LSB relocatable AMD64
      -> src/virtio_gpu.o  ELF 64-bit LSB relocatable AMD64
      -> drm               ELF 64-bit LSB relocatable AMD64    (ld -r linked module)

    make verify   # prints file types + elfdump e_type/e_machine (ET_REL/AMD64)

    cc -o test_c1b test/test_c1b.c && ./test_c1b   # -> "C1b logic self-check: PASS"

### C1b deliverables, per item

- **GEM real page backing + mmap: YES.**
  `drm_gem.c` `drm_gem_create_dumb` now backs the object with
  `ddi_umem_alloc(9F)` (real pageable kernel memory + a `ddi_umem_cookie_t`)
  instead of the C1a `kmem_zalloc` stub. `drm_core.c` `drm_devmap` (the
  `cb_devmap` entry point) resolves an mmap offset back to its GEM object via
  `drm_gem_object_lookup_offset` and calls `devmap_umem_setup(9F)` on the
  object's umem cookie, so a userland mmap of the DRI node faults in exactly the
  object's pages. `DRM_IOCTL_MODE_MAP_DUMB` returns the devmap offset.

- **linux-compat shim primitives: YES.**
  `linux-compat/linux_compat.h` gains the C1b set on top of C1a's kref/idr/
  mutex/kmem: `workqueue_struct`/`work_struct` → `ddi_taskq_*`;
  `task_struct`/`kthread_run` → `thread_create` (+ `p0`, `minclsyspri`);
  `struct completion` → `kcondvar_t`+`kmutex_t` (`cv_wait`/`cv_timedwait`/
  `cv_broadcast`); `struct rw_semaphore` → `krwlock_t`. (ww_mutex, rcu,
  radixtree/xarray, hrtimer remain C1c.)

- **virtio-gpu attach + GET_DISPLAY_INFO probe: YES.**
  `virtio_gpu.c` `virtio_gpu_transport_attach` binds the illumos `virtio`
  framework (`virtio_init`), claims controlq(0) + cursorq(1) via
  `virtio_queue_alloc`, finishes with `virtio_init_complete`, reads
  `num_scanouts` from device config (`virtio_dev_get32`), and issues
  `VIRTIO_GPU_CMD_GET_DISPLAY_INFO` (via `virtio_gpu_exec`, a synchronous
  command/response over `virtio_chain_*` + `virtio_dma_*`). `drm_attach` calls
  it; on a non-virtio parent it no-ops cleanly (`dev->vgpu == NULL`).

- **SET_SCANOUT modeset (first-lit-framebuffer path): YES (compiling).**
  `virtio_gpu.c` implements the full 2D chain:
  `RESOURCE_CREATE_2D` → `RESOURCE_ATTACH_BACKING` (guest-physical cookies via
  `virtio_dma_cookie_pa`) → `SET_SCANOUT` → `TRANSFER_TO_HOST_2D` →
  `RESOURCE_FLUSH`, driven by `drm_gem_scanout()` from the solnix-private
  `DRM_IOCTL_MODE_SET_SCANOUT_SOLNIX` ioctl.

### QEMU stretch: NOT reached

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

## Layout of /root/drm-port/

    netbsd-ref/          NetBSD-current DRM crib, pinned git 5a7765109d...
    DESIGN.md            layer -> illumos mapping, provenance per file, C1a/b/c split
    STATUS.md            this file
    Makefile             kernel-module build (builds + links the 3 objects)
    src/
      drm_core.c         dev_ops/cb_ops, attach (+ virtio bind), ioctl dispatch,
                         VERSION, cb_devmap GEM mmap, SET_SCANOUT dispatch
      drm_gem.c          GEM create/map/destroy/close (ddi_umem backed),
                         offset->object lookup, SET_SCANOUT ioctl bridge
      drm_internal.h     drm_device / drm_gem_object / drm_driver (C1b fields)
      virtio_gpu.c       virtio-gpu transport attach + 2D modeset chain
      virtio_gpu_hw.h    virtio-gpu wire protocol (cribbed, Linux UAPI)
      virtio_impl.h      illumos virtio framework KPI (declarations)
      linux-compat/
        linux_compat.h   C1a shim + C1b primitives (taskq/kthread/cv/rwlock)
      uapi/drm/drm.h     Linux DRM UAPI subset + solnix SET_SCANOUT ioctl
    test/
      test_c1b.c         userland self-check (offset lookup + cmd-buffer math)
    build/               scratch build dir (throwaway)

## How to resume

1. Rebuild: `cd /root/drm-port && make verify`.
2. Read DESIGN.md sections A-F for the mapping; each row marks C1a/C1b/C1c.
3. C1b polish before C1c (optional, not blocking): (a) restructure the module to
   attach as a real virtio PCI child (bind under the virtio bus in `_init`
   rather than `mod_driverops` alone, so `virtio_init` gets a real virtio
   parent); (b) a devfsadm rule linking the minor nodes under `/dev/dri/`;
   (c) replace the `virtio_queue_poll` busy-wait in `virtio_gpu_exec` with the
   queue's completion interrupt + a `struct completion`; (d) zero-copy backing
   (export the GEM umem pages' own PAs instead of the bcopy in drm_gem_scanout).

### Next: C1c (dma-buf + fence + scheduler for compute)
- dma-fence (`kcondvar_t`-backed), dma-resv + ww_mutex shim, sync_file.
- dma-buf fd-sharing — the one primitive with no clean illumos analogue
  (design-open, flagged in DESIGN.md D); needed for cross-driver + Vulkan
  render-node buffer sharing.
- the drm GPU scheduler.
- Gates C2 (Mesa/GBM/Vulkan) and the whole compute stack above it.

## Anti-scope reminder (from the task + design docs)
Do NOT chase a working driver here — that is C1b-stretch/C1c. The ~500k-LOC
Linux DRM drivers in `netbsd-ref/.../dist/` are reference only; solnix adapts
the ~18-20k-LOC shim+glue boundary + the virtio-gpu 2D path, it does not lift
Linux .c. virtio-gpu first (no VRAM => no TTM on the critical path);
i915/amdgpu/nouveau are far later (C3).
