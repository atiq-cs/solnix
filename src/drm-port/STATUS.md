# solnix DRM/KMS port — STATUS

## Phase reached: C1c (dma-fence + ww_mutex/dma-resv + PRIME dma-buf-fd + scheduler, all COMPILING against illumos headers)

C1c builds on the C1a drm-core/GEM stub and the C1b real-GEM-backing + virtio-gpu
2D path. The whole DRM module — core + GEM + virtio-gpu transport + 2D modeset +
the C1c GPU-synchronization/buffer-sharing primitives — compiles as a single
`ET_REL` AMD64 kernel object against the installed illumos kernel headers, with
every undefined symbol resolving to a real illumos KPI (genunix/specfs) or an
export of the illumos `virtio` kernel module. No phantom Linux symbols, no
phantom `dma_buf_*`, no phantom virtio symbols.

It is still a COMPILE milestone: the code is written to run (it drives the real
illumos virtio KPI, the real devmap/umem KPI, and the real falloc/getf/
makespecvp file/vnode KPI), but it is not verified running under QEMU (needs a
metal host). Getting the C1c primitives to compile against illumos headers + a
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
      -> src/drm_dma.o     ELF 64-bit LSB relocatable AMD64   (C1c fence/ww/resv)
      -> src/drm_sched.o   ELF 64-bit LSB relocatable AMD64   (C1c scheduler)
      -> src/drm_prime.o   ELF 64-bit LSB relocatable AMD64   (C1c PRIME/sync_file)
      -> drm               ELF 64-bit LSB relocatable AMD64    (ld -r linked module)

    make verify   # prints file types + elfdump e_type/e_machine (ET_REL/AMD64)

    cc -o test_c1b test/test_c1b.c && ./test_c1b   # -> "C1b logic self-check: PASS"
    cc -o test_c1c test/test_c1c.c && ./test_c1c   # -> "C1c logic self-check: PASS"

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
      virtio_gpu_hw.h    virtio-gpu wire protocol (cribbed, Linux UAPI)
      virtio_impl.h      illumos virtio framework KPI (declarations)
      linux-compat/
        linux_compat.h   C1a shim + C1b primitives (taskq/kthread/cv/rwlock)
        linux_dma.h      C1c dma-fence/ww_mutex/dma-resv declarations + inlines
      uapi/drm/drm.h     Linux DRM UAPI subset + PRIME ioctls + solnix SET_SCANOUT
    test/
      test_c1b.c         userland self-check (offset lookup + cmd-buffer math)
      test_c1c.c         userland self-check (fence signal-once, ww ticket
                         compare, resv array growth)
    build/               scratch build dir (throwaway)

## How to resume

1. Rebuild: `cd /root/drm-port && make verify`.
2. Read DESIGN.md sections A-F (+ D.1 for the PRIME dma-buf-fd mechanism); each
   row marks C1a/C1b/C1c.
3. C1c is DONE (compiling) — C2 (Mesa/GBM/Vulkan) is now the next phase.

### Next: C2 (Mesa/GBM/Vulkan) — now unblockable
The C1c primitives (fence, resv/ww_mutex, PRIME dma-buf-fd, scheduler) are the
synchronization + buffer-sharing surface Mesa/GBM/Vulkan build on, and they
compile against the real illumos KPI with the DRM UAPI (incl. PRIME) preserved.
Remaining runtime bring-up (needs a metal QEMU host, NOT compile-blocking):
- carve the PRIME/sync_file spec-vnode minors out of the drm node as a real
  second minor space + `cb_close` teardown on export-minor close;
- wire the scheduler `run_job` to `virtio_gpu_exec`, and the sync_file `poll(2)`
  path (drm `cb_chpoll` + `pollwakeup` event queue, currently `nochpoll`);
- the C1b polish still pending: bind as a real virtio PCI child in `_init`, a
  devfsadm `/dev/dri/` rule, the completion-interrupt path replacing
  `virtio_queue_poll`, and zero-copy scanout backing.

## Anti-scope reminder (from the task + design docs)
Do NOT chase a working driver here — that is C1b-stretch/C1c. The ~500k-LOC
Linux DRM drivers in `netbsd-ref/.../dist/` are reference only; solnix adapts
the ~18-20k-LOC shim+glue boundary + the virtio-gpu 2D path, it does not lift
Linux .c. virtio-gpu first (no VRAM => no TTM on the critical path);
i915/amdgpu/nouveau are far later (C3).
