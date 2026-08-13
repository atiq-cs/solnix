# solnix DRM/KMS port — STATUS

## Phase reached: C1a (drm core + GEM stub COMPILING against illumos headers)

This is the R-P17-equivalent milestone for DRM in the C1..C4 compute-keystone
plan (`docs/design-gpu-compute-parity.md`): the smallest load-bearing DRM piece
— char-device/ioctl registration + GEM object create/map/close — compiles as an
illumos kernel module against the installed kernel headers, with the NetBSD
linux-KPI shim boundary mapped to illumos DDI/ksynch primitives.

It is NOT a working driver. It does not load, does not touch hardware, does not
modeset. Getting it to *compile* — proving the NetBSD-drm2-to-illumos impedance
boundary is real and mappable — is the C1a deliverable.

## What compiles (verified)

    cd /root/drm-port && make
      -> gcc -m64 -D_KERNEL -ffreestanding -nostdinc -I/usr/include -Isrc ...
      -> src/drm_core.o   ELF 64-bit LSB relocatable AMD64   (ET_REL, EM_AMD64)
      -> src/drm_gem.o    ELF 64-bit LSB relocatable AMD64
      -> drm              ELF 64-bit LSB relocatable AMD64    (ld -r linked module)

    make verify   # prints file types + elfdump e_type/e_machine

Verified: `elfdump -e drm` -> `e_type: ET_REL`, `e_machine: EM_AMD64`. Every
undefined symbol is a real illumos kernel KPI (`nm drm | grep UNDEF`): no
phantom Linux symbols — the shim absorbed the Linux KPI the stub touches.

Ioctls implemented as functional stubs (ABI-faithful, `ddi_copyin/out`):
  - `DRM_IOCTL_VERSION`         -> reports "virtio_gpu" 0.1.0 (libdrm-probe match)
  - `DRM_IOCTL_MODE_CREATE_DUMB` -> kmem-backed buffer, idr handle, pitch/size
  - `DRM_IOCTL_MODE_MAP_DUMB`    -> returns fake mmap offset
  - `DRM_IOCTL_MODE_DESTROY_DUMB` / `DRM_IOCTL_GEM_CLOSE` -> drop handle + ref
  - all other DRM ioctls -> ENOTTY

`attach` creates `card0` + `renderD128` minor nodes (DDI_NT_DISPLAY).

## Layout of /root/drm-port/

    netbsd-ref/          NetBSD-current DRM crib, pinned git 5a7765109d...
      README.md          provenance, pin, sparse paths, license posture, RCS ids
      src/sys/external/bsd/drm2/   the crib tree (shim + glue + dist core + ttm)
    DESIGN.md            layer -> illumos mapping, provenance per file, C1a/b/c split
    STATUS.md            this file
    Makefile             kernel-module build (illumos -D_KERNEL flags)
    src/
      drm_core.c         dev_ops/cb_ops, _init/_fini, attach+minor nodes, ioctl dispatch, VERSION
      drm_gem.c          GEM create/map/destroy/close dumb-buffer stubs
      drm_internal.h     illumos-side drm_device / drm_gem_object / drm_driver
      linux-compat/
        linux_compat.h   C1a shim subset: kref, idr(avl), mutex, kmem, copy*
      uapi/drm/drm.h     preserved Linux DRM UAPI subset (ioctl nrs + structs)
    build/               scratch build dir (same source, throwaway)

## How to resume

1. Restore git metadata if needed: re-fetch the pin (see netbsd-ref/README.md);
   the working source is retained, only the 638M packfile was moved out.
2. Rebuild the C1a object: `cd /root/drm-port && make verify`.
3. Read DESIGN.md sections A-F for the mapping; each row marks C1a/C1b/C1c.

### Next: C1b (KMS + real GEM backing + virtio wiring)
- Replace kmem GEM backing with `ddi_umem_alloc`; implement `cb_devmap` +
  `devmap_umem_setup` so MAP_DUMB + userland mmap fault in real pages.
- Port the shim primitives C1b needs: workqueue->`ddi_taskq_*`,
  kthread->`thread_create`, completion->`cv`, rwsem->`krwlock_t`,
  pci/BAR->`ddi_regs_map_setup`+`ddi_intr_*`.
- Bind the drm node to the illumos virtio transport (virtio-gpu control/cursor
  virtqueues, `VIRTIO_GPU_CMD_*`); implement `SET_SCANOUT` modeset.
- Ship a devfsadm rule to link the minor nodes under `/dev/dri/`.
- Milestone: a virtio-gpu modeset (first lit framebuffer) under QEMU
  `-device virtio-gpu`.

### Then: C1c (dma-buf + fence + scheduler for compute)
- dma-fence (`kcondvar_t`-backed), dma-resv + ww_mutex shim, sync_file.
- dma-buf fd-sharing — the one primitive with no clean illumos analogue
  (design-open, flagged in DESIGN.md D); needed for cross-driver + Vulkan
  render-node buffer sharing.
- the drm GPU scheduler.
- Gates C2 (Mesa/GBM/Vulkan) and the whole compute stack above it.

## Anti-scope reminder (from the task + design docs)
Do NOT chase a working driver here — that is C1b/C1c and multi-quarter. The
500k-LOC Linux DRM drivers in `netbsd-ref/.../dist/` are reference only; solnix
adapts the ~18-20k-LOC shim+glue boundary, it does not lift Linux .c. virtio-gpu
first (no VRAM => no TTM on the critical path); i915/amdgpu/nouveau are far later.
