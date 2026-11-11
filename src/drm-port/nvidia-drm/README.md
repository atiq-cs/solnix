# nvidia-drm on illumos

NVIDIA's DRM driver (`kernel-open/nvidia-drm` of the pinned open-gpu-kernel-modules tree, 8da2326, 615.71.09)
built over solnix's OpenBSD drm layer, the one i915 runs on (OpenBSD `sys/dev/pci/drm` at 37a498de plus
`../obsd-compat`). It drives the display through NVKMS's kernel API, which `nvidia_modeset` exports
(`nvKmsKapiGetFunctionsTable`); it programs no registers itself. The plan and its gates are D2.0 to D2.5 of the
RTX 3080 Ti track (lixi).

Every nvidia-drm file is MIT. `nvidia-drm-linux.c`, the Linux module wrapper, is the only one that says
"Dual MIT/GPL", and it is not built; the illumos module shell (`nvidia_drm_illumos.c`) replaces it.

Package: `pkgs.solnix.nvidia-drm-driver` (`pkgs/illumos/nvidia-drm-driver.nix`), `kernel/drv/amd64/nvidia_drm`.
A system lays it with `hardware.graphics.nvidia.drm` (which turns on `hardware.graphics.nvidia.modeset` and needs
`attachAtBoot`); both default to off.

## What is here

- `patches/0001-nvidia-drm-illumos-obsd-compat.patch`, applied to the pinned `kernel-open/` (`nvidia-drm/` and
  `common/inc/`), with `patch -p1 --fuzz=0`:
  - `NV_DRM_AVAILABLE` for `NV_SUNOS`, and `nvidia-drm-sunos.h`, the quirk block for the OpenBSD layer, in the role
    the `NV_BSD` block plays for FreeBSD. In that layer a Linux `struct mutex` is OpenBSD's `struct rwlock` and a
    `spinlock_t` is an illumos `kmutex_t`.
  - `NV_DRM_OBSD` arms in `common/inc`: `nv-timer.h` over OpenBSD `timeout(9)`, `nv-kthread-q-os.h` and
    `nv-kthread-q.c` as the queue of `kernel-illumos/nvidia-modeset/nvkms_q.c` (kmutex, condvar, `list_t`, a
    one-thread `ddi_taskq`), and `nv-mm.h` with no Linux VM. It is a separate macro from `NV_SUNOS` because
    nvidia_uvm's illumos build compiles the same headers with `NV_SUNOS` over its own Linux shadow headers.
- `patches/0002-nvidia-drm-lazy-nvkms-device.patch`: the NVKMS device exists only while it is used. Upstream
  allocates it once at load, which opens the GPU in RM for as long as the driver is loaded, so the coarse runtime
  D3cold of the illumos nvidia module (`hardware.graphics.nvidia.rtd3`, usage count 0) would never power the dGPU
  off. With the patch, load builds the mode objects (CRTCs, planes, encoders, connectors) from a device it then
  frees. Each open DRM file and each GEM object holds a reference: the first open allocates the device, enables
  NVKMS events and reprobes the connectors. When the last reference goes, a work item resets the atomic state,
  frees the LUT surfaces and frees the device. With no device, connector detection asks NVKMS nothing and reads
  disconnected, so probe and poll work cannot keep the GPU powered.
- The shell: `nvidia_drm_illumos.c` (DDI entry points, the character device), `nvidia_drm_glue.c` (what the
  shell needs from inside nvidia-drm and the OpenBSD drm structures), `nvidia_drm.conf` (one pseudo node). Its
  attach makes only a `ctl` minor and touches no GPU. The first open of `/devices/pseudo/nvidia_drm@0:ctl`
  (root only) runs `nv_drm_init()`: NVKMS enumerates the GPUs, and for each one the shell builds the drm_device
  the way OpenBSD's `drm_attach_pci()` does and makes the `card<N>` and `renderD<128+N>` minors, counted from
  `drm-card-base` (1: i915 is card0). site/solnix-nvidia opens `ctl` after its guarded probe. The cdev uses the
  clone-minor scheme and the Linux-to-OpenBSD ioctl translation of i915 (`../i915/i915_drmioc.h`).
- `conftest-run.sh` generates `conftest/*.h` with NVIDIA's own `conftest.sh`, compiled against the OpenBSD
  headers with i915's flags. Nothing in it is picked by hand.
- `nvidia-drm.mapfile` makes every symbol local except `_init`, `_fini`, `_info` and `_depends_on`, as
  `i915.mapfile` does: nvidia-drm links a private copy of the OpenBSD drm core and obsd-compat, whose globals
  i915 also defines.

## Measured (lixi, 2026-11-11, store gcc 15.3.0, i915's compile flags; nothing here has run on hardware)

- Compile: 0 errors. 17 of the 18 `.c` give objects with functions. `nv-pci-table.c` is data only.
  `nvidia-drm-color-pipeline.c` is empty because it needs `drm_colorop`, which OpenBSD's drm does not have
  (Linux has had it only since 6.19).
- Link: the OpenBSD drm core (i915's 84 "drm" files, with i915's `obsd-norcu` and `obsd-errno` patches),
  obsd-compat (6 objects) and the 19 nvidia-drm objects, `ld -r -Breduce -M nvidia-drm.mapfile`: 1.14 MB,
  198 undefined. Against kernel-nd (unix, genunix) plus `drv/nvidia_modeset` and `drv/nvidia`, 4 are unresolved,
  and they are the shell's: `_depends_on`, `nv_drm_sunos_dev_alloc`, `nv_drm_sunos_ioremap_wc` and
  `nv_drm_sunos_iounmap`. The module exports no other global.
- The package (both patches and the shell): `nvidia_drm`, 1,156,976 bytes, 111 objects, 210 undefined, 0
  unresolved against kernel-nd (unix, genunix, misc/gfx_private) and nvidia-oss-modules (drv/nvidia_modeset,
  drv/nvidia). The only globals are `_init`, `_fini`, `_info` and `_depends_on`. No collisions with the 58,895
  kernel-nd globals. i915's SIMD gate passes: 10 SIMD instructions, all in OpenBSD's `drm_cache.c`
  (`drm_memcpy_from_wc`, inside `fpu_kernel_enter/exit`), the object i915 exempts too. The negative controls fail
  as they should: one more unresolved symbol (named), and an nvidia-drm object rebuilt with SSE.

## GEM mmap (D2.3)

`mmap(2)` of a card or renderD fd at the fake offset `DRM_IOCTL_MODE_MAP_DUMB` (or NVIDIA's `GEM_MAP_OFFSET`)
returns maps the object's range of the GPU's FB BAR (BAR1), write-combined, which is what upstream's `nv_drm_mmap`
plus `drm_gem_mmap_obj` give on Linux. Pieces:

- `patches/0003-nvidia-drm-sunos-gem-mmap.patch`: `nv_drm_sunos_gem_mmap_pa`, upstream's `__nv_drm_gem_nvkms_mmap`
  without the Linux VMA part: the NVKMS USER mapping (`__nv_drm_gem_nvkms_map`), the GC6 blocker taken once per
  object (dropped when the object is freed, as upstream), and the CPU physical address and size. Anything but nvkms
  video memory is EOPNOTSUPP.
- `nvidia_drm_glue.c` `nv_drm_sunos_gem_map`: the exact vma-offset lookup of `nv_drm_mmap`, the reference taken
  only if the object is not being freed (`kref_get_unless_zero`, one compare-and-swap with i915's
  `obsd-norcu.patch`), `drm_vma_node_is_allowed` for the calling file.
- `nvidia_drm_illumos.c`: `nvd_devmap` checks all of that with a temporary reference and calls
  `devmap_devmem_setup` on the nvidia node with the FB BAR's `reg` index and the offset into it (`DDI_MERGING_OK_ACC`:
  rootnex makes it `HAT_MERGING_OK`, the PAT write-combining entry). `devmap_setup` frees its handles without a
  callback when making the mapping fails, so the lasting reference is taken by the `devmap_map` callback, after a
  second lookup that must land on the same pages; until then, or if it does not, the mapping holds nothing and
  `devmap_access` refuses its faults (EFAULT). `devmap_map` never fails (a failure leaves a segment with no handles
  behind). dup and partial unmaps share the reference; the last `devmap_unmap` releases it from a taskq, since it
  runs under the address space's writer lock and the release calls NVKMS and RM. Only `MAP_SHARED` (`nvd_segmap`).
- The reference keeps the GEM object, so the object keeps the NVKMS device (patch 0002): the dGPU stays powered
  while any mapping exists.
- `nvidia_drm_bar1.h`: the arithmetic, kernel-free: which `reg` entry is the FB BAR (the second memory BAR in
  `assigned-addresses`, as the nvidia module's `nv_pci_map_bars` picks the BAR RM uses as `gpuPhysFbAddr`), the fake
  offset request, the object's range inside the BAR. `test/test_bar1.c` runs it in userland on the X1E's real
  properties (BAR1 16 GB at 0x60_0000_0000); the derivation runs it and two sabotaged builds, which must fail.
- Same limit as upstream: the object is mapped as one contiguous BAR1 range from the address NVKMS returns (RM
  returns range 0 of the aperture; upstream's fault handler adds the page offset to it the same way).

Built and gated, not run on hardware yet.

## Not ported yet (they fail at run time with an error, never a fake success)

- GEM mmap of anything but nvkms memory in video memory: sysmem nvkms objects (mapped by page on Linux), dma-buf
  imports and user memory get EOPNOTSUPP from the devmap path (D2.3, below).
- Importing user memory (page pinning) and `nv_drm_vmap` of page lists: the compat `vmap()` takes OpenBSD
  `vm_page`s.
- `drm_prime_pages_to_sg` (PRIME, D2.4); `prime_dup` between two NVIDIA GPUs (OpenBSD's `dma_buf` has no `owner`).
- The `DRM_IOCTL_MODE_REVOKE_LEASE` hook (Linux `file_operations` only).
- fbdev emulation (`nvidia-drm-sunos.h` refuses to build with it).
- dma-buf fds (PRIME, D2.4): the shell has no dma-buf minor.
- A GPU that appears after the start gets no minor nodes (one enumeration).
- Detach: refused once started, as for i915.
