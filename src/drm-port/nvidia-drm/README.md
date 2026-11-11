# nvidia-drm on illumos

NVIDIA's DRM driver (`kernel-open/nvidia-drm` of the pinned open-gpu-kernel-modules tree, 8da2326, 615.71.09)
built over solnix's OpenBSD drm layer, the one i915 runs on (OpenBSD `sys/dev/pci/drm` at 37a498de plus
`../obsd-compat`). It drives the display through NVKMS's kernel API, which `nvidia_modeset` exports
(`nvKmsKapiGetFunctionsTable`); it programs no registers itself. The plan and its gates are D2.0 to D2.5 of the
RTX 3080 Ti track (lixi).

Every nvidia-drm file is MIT. `nvidia-drm-linux.c`, the Linux module wrapper, is the only one that says
"Dual MIT/GPL", and it is not built; an illumos module shell replaces it (D2.1).

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
- `conftest-run.sh` generates `conftest/*.h` with NVIDIA's own `conftest.sh`, compiled against the OpenBSD
  headers with i915's flags. Nothing in it is picked by hand.
- `nvidia-drm.mapfile` makes every symbol local except `_init`, `_fini`, `_info` and `_depends_on`, as
  `i915.mapfile` does: nvidia-drm links a private copy of the OpenBSD drm core and obsd-compat, whose globals
  i915 also defines.

## Measured (lixi, 2026-11-11, store gcc 15.3.0, i915's compile flags)

- Compile: 0 errors. 17 of the 18 `.c` give objects with functions. `nv-pci-table.c` is data only.
  `nvidia-drm-color-pipeline.c` is empty because it needs `drm_colorop`, which OpenBSD's drm does not have
  (Linux has had it only since 6.19).
- Link: the OpenBSD drm core (i915's 84 "drm" files, with i915's `obsd-norcu` and `obsd-errno` patches),
  obsd-compat (6 objects) and the 19 nvidia-drm objects, `ld -r -Breduce -M nvidia-drm.mapfile`: 1.14 MB,
  198 undefined. Against kernel-nd (unix, genunix) plus `drv/nvidia_modeset` and `drv/nvidia`, 4 are unresolved,
  and they are the shell's: `_depends_on`, `nv_drm_sunos_dev_alloc`, `nv_drm_sunos_ioremap_wc` and
  `nv_drm_sunos_iounmap`. The module exports no other global.

## Not ported yet (they fail at run time with an error, never a fake success)

- GEM mmap and its fault handler, for dumb buffers and every other object (D2.3: an illumos devmap path).
- Importing user memory (page pinning) and `nv_drm_vmap` of page lists: the compat `vmap()` takes OpenBSD
  `vm_page`s.
- `drm_prime_pages_to_sg` (PRIME, D2.4); `prime_dup` between two NVIDIA GPUs (OpenBSD's `dma_buf` has no `owner`).
- The `DRM_IOCTL_MODE_REVOKE_LEASE` hook (Linux `file_operations` only).
- fbdev emulation (`nvidia-drm-sunos.h` refuses to build with it).
