# amdkfd/ — the KFD (/dev/kfd) compute surface on illumos (C3-KFD)

The AMD Kernel Fusion Driver (amdkfd) port: `/dev/kfd` + the AMDKFD_IOC_*
compute ioctls + user-mode compute queues (doorbell submission), the ROCm/HIP
**compute** entry point on illumos — beyond the graphics Vulkan (RADV) surface.

A second char-device minor (`KFD_MINOR`) on the same illumos char device the C1
DRM core owns and the C3-amdgpu transport attaches to; the KFD carves
per-process doorbell pages out of the amdgpu BAR2 aperture and creates user-mode
compute queues whose submission is a doorbell ring (no per-submit syscall).

## Contents

    uapi/kfd_ioctl.h              the KFD UAPI (Linux ABI preserved verbatim, base 'K')
    kfd_priv.h                    kfd_dev / kfd_process / kfd_queue / kfd_mem / doorbell model
    kfd_device.c                  device init + gfx10 apertures + the BAR2 doorbell manager
    kfd_process.c                 per-process compute context (keyed by illumos pid)
    kfd_device_queue_manager.c    queue create/destroy + doorbell alloc + memory alloc/map
    kfd_chardev.c                 the /dev/kfd ioctl dispatch + per-command handlers
    test_kfd.c                    userland self-check (ABI encoding / doorbell math / apertures)
    KFD-STATUS.md                 the full status: ioctl surface, zero-phantom audit,
                                  the ROCm-userspace next step, what's hardware-gated

## Build + verify (from ../)

    make kfd            # C1 + amdgpu + KFD -> drm-full (ET_REL AMD64) + zero-phantom check
    make test-kfd       # -> "C3-KFD logic self-check: PASS"

Result: 25 objects compile, 131 undefs, ZERO phantom, self-check PASS.

## Design + crib

  - the full status + the ROCm userspace path: KFD-STATUS.md
  - the amdgpu layering (KFD is A3-f there): ../docs/design-gpu-amdgpu.md
  - crib: Linux drivers/gpu/drm/amd/amdkfd/ (kfd_chardev.c / kfd_process.c /
    kfd_device_queue_manager.c / kfd_doorbell.c / kfd_device.c) + the verbatim
    UAPI include/uapi/linux/kfd_ioctl.h @ v1.14. No Linux .c lifted — each
    primitive re-expressed against illumos DDI/kmem/ksynch + the C1 shim + the
    C3-amdgpu device, the same crib-and-adapt doctrine as C3-amdgpu.

## Next

The kernel compute surface compiles zero-phantom. The next layer is userspace:
build **libhsakmt** (the HSA kernel-mode thunk — its hsaKmt* ioctl wrappers map
1:1 onto the AMDKFD_IOC_* this dir dispatches; the one solnix gap is its
topology reader, which assumes Linux /sys), then **ROCr** (the HSA runtime),
then **HIP**. The live queue dispatch (HWS/MES MQD map, GPUVM PTE program,
doorbell mmap fault) is hardware-gated on a powered V520 (the C3-amdgpu-d gate).
