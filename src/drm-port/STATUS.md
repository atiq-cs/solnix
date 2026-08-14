# solnix DRM/KMS port — STATUS

## Phase reached: C1d (virtio-gpu 3D command path — EXECBUFFER + CTX + GET_CAPS + RESOURCE_CREATE_3D + TRANSFER_3D, all COMPILING against illumos headers)

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
