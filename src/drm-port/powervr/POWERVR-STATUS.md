# solnix PowerVR port — STATUS (C-PVR-a: Imagination's open Vulkan driver)

## Goal

Port Mesa's **PowerVR** driver (`src/imagination/vulkan`,
`libvulkan_powervr_mesa.so`) — Imagination Technologies' *open* Vulkan driver —
to illumos x86_64, COMPILE-phase, zero-phantom, against the open PowerVR DRM
uapi / pvr ioctl surface. This is the userspace half of driving the Milk-V
Jupiter's **Imagination PowerVR BXE-2-32** GPU (so COSMIC + local LLMs can be
GPU-accelerated instead of falling back to llvmpipe software render). The kernel
half is C-PVR-b (the `drivers/gpu/drm/imagination` DRM driver). Fast follow-on to
RADV/ANV/NVK: same Mesa 24.0.9 tree, same meson+ninja+gcc-14+glslang toolchain,
the same 5 Mesa-wide illumos fixes, the same Linux `_IOC` ioctl shim.

## Verdict (the honest maturity finding)

**`libvulkan_powervr_mesa.so` COMPILED for illumos x86_64, zero-phantom
(truly-unresolved = 0), dlopen(RTLD_NOW) OK, ICD entry points exported. NO
Rust, NO LLVM required — the shader compiler is "rogue" (NIR-based, pure C), the
relief the task predicted vs NVK's Rust NAK.**

Maturity, precisely stated (Rogue/AXE vs B-series/BXE):

- Mesa 24.0.9's `src/imagination` **exists and is a full driver** (not app-side
  samples): `vulkan/` (the VK driver, ~21.6k LOC), `rogue/` (the shader
  compiler, ~10k LOC), `common/`, `csbgen/`, plus the open `winsys/powervr`
  (direct-ioctl to the open DRM kernel driver) and the closed `winsys/pvrsrvkm`
  (Imagination Services backend, not built here).
- Upstream still names the driver **`imagination-experimental`** in this pin —
  its own signal that PowerVR VK is early in Mesa 24.0.9.
- The **shader compiler is `rogue/`, NOT `pco/`.** `pco` (the newer PowerVR
  compiler with mature B-series codegen) landed in Mesa *after* 24.0.9. This pin
  ships the older Rogue compiler.
- `common/pvr_device_info.c` enumerates exactly **three** supported parts:
  - `GX6250`  — series **Rogue**   (bvnc 4.V.2.51)
  - `AXE-1-16M` — series **A-Series** (bvnc 33.V.11.3)
  - `BXS-4-64` — series **B-Series** (bvnc 36.V.104.796, device_id 0x36104796)
- The Jupiter's GPU is the **BXE-2-32**. That exact BVNC is **not** in Mesa
  24.0.9 — the only B-Series part present is the BXS-4-64. `BXE` appears
  *nowhere* in `src/imagination`. So the driver has B-Series *scaffolding* (the
  `pvr_device_features_36_V_104_796` feature table, the B-Series render path)
  but not the BXE-2-32 device identity/feature table. Runtime on the Jupiter's
  BXE-2-32 is therefore **hardware-gated on a device table Mesa 24.0.9 does not
  ship** — see "Jupiter-hardware-gated" below.

So: the illumos *portability* work is complete and proven (the whole ~97k-LOC
imagination tree compiles to a zero-phantom `.so` with the ICD contract), but
*BXE-2-32 bring-up* needs a Mesa new enough to carry the BXE-2-32 BVNC + the
`pco` compiler (Mesa 25.x-era). Everything below is COMPILE-ready and delivered.

## Fast follow-on to RADV/ANV/NVK — the shared substrate (reused unchanged)

- **gcc-14** (`/usr/gcc/14`), the `/root/mesa-venv` python venv (meson 1.11.2 +
  mako + pyyaml), ninja 1.12.1, the real glslang 14.3.0.
- Mesa 24.0.9 source at `/var/tmp/mesa-24.0.9` (the C2 pin).
- The libdrm 2.4.120 build at `/var/tmp/libdrm-out` (core libdrm + the Linux
  `_IOC` shim). PowerVR needs **only core libdrm** — no `libdrm_powervr` module
  exists; the `winsys/powervr` talks to the kernel via direct
  `drmIoctl(fd, DRM_IOCTL_PVR_*, ...)`, the ANV model, not the libdrm-module
  model of RADV/NVK.
- The 5 Mesa-wide illumos fixes (`u_atomic.h` GNU-atomics guard, `u_thread.c`
  `__sun` guard, `macros.h` `<alloca.h>`, `disk_cache_os.c` 4-arg `getpwuid_r`,
  the drm.h `_IOC` shim) — all applied idempotently by the build script.

## Deliverables

### 1. `libvulkan_powervr_mesa.so` — COMPILED for illumos: **YES**

    /var/tmp/mesa-powervr-out/lib/libvulkan_powervr_mesa.so   (6.9 MB)
    /var/tmp/mesa-powervr-out/lib/libpowervr_rogue.so         (9.5 MB, the Rogue compiler, split-out)
    /var/tmp/mesa-powervr-out/share/vulkan/icd.d/powervr_mesa_icd.x86_64.json

Meson config: `-Dvulkan-drivers=imagination-experimental -Dimagination-srv=false
-Dllvm=disabled` (imagination-srv=false selects the OPEN `winsys/powervr`, not
the closed Services backend). The config resolves EVERY dependency (libdrm
2.4.120 found, glslang found, python3 found) with **no Rust and no LLVM** — the
one structural difference from NVK, which gated on rustc.

**LOC compiled:** the imagination tree is ~97k LOC total (71,052 lines of `.c`
across 83 files + ~26k lines of `.h` across 98 files): `vulkan/` 21,611 `.c`,
`rogue/` 10,025 `.c`, `common/` 906 `.c`, plus csbgen/pds/usc generated code.

`SONAME libvulkan_powervr_mesa.so`; NEEDED: `libpowervr_rogue.so libdrm.so.2
libz.so.1 libstdc++.so.6 libm.so.2 libgcc_s.so.1 libc.so.1`.

### 2. PowerVR-specific illumos breaks — fixed crib-and-adapt

**One powervr-specific break** beyond the 5 shared fixes:
`include/drm-uapi/pvr_drm.h` is the *only* drm-uapi header that pulls
`<linux/const.h>` (for `_BITULL`) + `<linux/types.h>` (for `__u16/32/64/__s32`)
AFTER `#include "drm.h"`. Two-part fix:

- Added the `linux/const.h` bit helpers (`_UL/_ULL/_BITUL/_BITULL`) to the Linux
  `_IOC` shim (`pvr-linux-ioctl-compat.h`). The `_BITULL` had to be added to
  **the `libdrm-out` copy of the shim**, not just Mesa's — because
  `pvr_drm_bo.c` includes `<xf86drm.h>` (line 33, from libdrm) *before*
  `drm-uapi/pvr_drm.h` (line 35). libdrm's `drm.h` sets the `_DRM_H_` guard
  first, so Mesa's shim-injected `drm.h` is skipped, and the shim that actually
  wins the shared `_SOLNIX_LINUX_IOCTL_COMPAT_H_` include-guard is libdrm's. Give
  *that* one `_BITULL` and pvr_drm.h resolves.
- Guarded pvr_drm.h's two linux includes under `#ifdef __sun` → include the
  shim instead (drm.h's BSD branch + the shim supply the `__uN`/`_BITULL` set).
  See `pvr_drm.h.patched`.

The `rogue` compiler and the `vulkan` code otherwise compiled with only the 5
shared fixes + the standard `-Wno-error=incompatible-pointer-types`/`pointer-sign`
relaxes.

### 3. ZERO-PHANTOM undef audit: **YES — truly-unresolved = 0**

`nm -u -D libvulkan_powervr_mesa.so` → **2603 undefs**, split:

- **2345 WEAK** (`w`) — intra-`.so` Vulkan dispatch (the `vk*` /
  `vkCmd*` entry-point table the loader/trampoline fills), exactly as RADV/ANV/
  NVK. Not phantom by construction (`pvr-weak-undef.txt`).
- **258 GLOB** (`U`) — every one resolves to a NEEDED lib (`pvr-glob-undef.txt`):
  - `libpowervr_rogue.so` — the Rogue shader compiler (`rogue_MOV`,
    `rogue_EMITPIX`, `rogue_WOP`, … the split-out compiler .so, NEEDED).
  - `libdrm.so.2` — `drmIoctl`, `drmCommandWrite*`, `drmPrime*`, `drmGetDevices`…
  - `libz.so.1` — `crc32`, `deflate*`, `inflate*` (shader cache).
  - `libstdc++.so.6` — `_Znwm`/`_ZdlPvm` (new/delete), `_ZSt*` throw helpers,
    `_Prime_rehash_policy` (the C++ bits of the compiler).
  - `libgcc_s.so.1` — `_Unwind_Resume`. `libm.so.2` — `cos`/`exp2f`/`floor`/`fma`…
  - `libc.so.1` — `malloc`/`calloc`/`mmap`/`pthread_*`/`___errno`/…

  Machine-checked: `comm -23` of (GLOB undefs) vs (union of `nm -D
  --defined-only` over all 7 NEEDED libs), version-suffix-stripped, `LC_ALL=C`
  → **0 truly-unresolved**. (The naive run showed false positives purely from a
  locale-collation mismatch between `sort` and `comm`; `LC_ALL=C` on both sides
  = 0.)

**dlopen machine-check:** `dlopen("libvulkan_powervr_mesa.so", RTLD_NOW |
RTLD_GLOBAL)` → **OK** (every WEAK dispatch + every GLOB symbol bound at load),
and `dlsym(vk_icdGetInstanceProcAddr)` → non-NULL. Same rigor as RADV/ANV/NVK.

### 4. The ICD — WIRED: **YES**

`libvulkan_powervr_mesa.so` exports all three loader entry points:

    vk_icdGetInstanceProcAddr
    vk_icdGetPhysicalDeviceProcAddr
    vk_icdNegotiateLoaderICDInterfaceVersion

Mesa's imagination meson emits the ICD manifest itself:
`powervr_mesa_icd.x86_64.json` (`api_version 1.0.274`). The install-relative
copy in `powervr/` uses `"library_path": "../../../lib/libvulkan_powervr_mesa.so"`
(the RADV/ANV/NVK convention). Drop it in a Vulkan `icd.d` and point
`VK_ICD_FILENAMES` at it.

### 5. The pvr_drm ioctl surface for C-PVR-b — DOCUMENTED

`winsys/powervr` issues **14 ioctls** via `drmIoctl(fd, DRM_IOCTL_PVR_*, ...)`.
`PVR_IOCTL(nr, dir, data)` = `dir(DRM_COMMAND_BASE + nr, struct
drm_pvr_ioctl_<data>_args)`. Encoded on illumos through the Linux `_IOC` shim
(NOT `<sys/ioccom.h>`) so the numbers match what the C-PVR-b kernel decodes —
`type = 0x64` ('d' = DRM), `nr = 0x40 (DRM_COMMAND_BASE) + opcode`
(`pvr-ioctl-encoding.out`):

| opcode | ioctl                            | encoded     | dir  | args struct                          | size |
|--------|----------------------------------|-------------|------|--------------------------------------|------|
| 0x00   | DRM_IOCTL_PVR_DEV_QUERY          | 0xc0106440  | IOWR | drm_pvr_ioctl_dev_query_args         | 16   |
| 0x01   | DRM_IOCTL_PVR_CREATE_BO          | 0xc0186441  | IOWR | drm_pvr_ioctl_create_bo_args         | 24   |
| 0x02   | DRM_IOCTL_PVR_GET_BO_MMAP_OFFSET | 0xc0106442  | IOWR | drm_pvr_ioctl_get_bo_mmap_offset_args| 16   |
| 0x03   | DRM_IOCTL_PVR_CREATE_VM_CONTEXT  | 0xc0086443  | IOWR | drm_pvr_ioctl_create_vm_context_args | 8    |
| 0x04   | DRM_IOCTL_PVR_DESTROY_VM_CONTEXT | 0x40086444  | IOW  | drm_pvr_ioctl_destroy_vm_context_args| 8    |
| 0x05   | DRM_IOCTL_PVR_VM_MAP             | 0x40286445  | IOW  | drm_pvr_ioctl_vm_map_args            | 40   |
| 0x06   | DRM_IOCTL_PVR_VM_UNMAP           | 0x40186446  | IOW  | drm_pvr_ioctl_vm_unmap_args          | 24   |
| 0x07   | DRM_IOCTL_PVR_CREATE_CONTEXT     | 0xc0286447  | IOWR | drm_pvr_ioctl_create_context_args    | 40   |
| 0x08   | DRM_IOCTL_PVR_DESTROY_CONTEXT    | 0x40086448  | IOW  | drm_pvr_ioctl_destroy_context_args   | 8    |
| 0x09   | DRM_IOCTL_PVR_CREATE_FREE_LIST   | 0xc0206449  | IOWR | drm_pvr_ioctl_create_free_list_args  | 32   |
| 0x0a   | DRM_IOCTL_PVR_DESTROY_FREE_LIST  | 0x4008644a  | IOW  | drm_pvr_ioctl_destroy_free_list_args | 8    |
| 0x0b   | DRM_IOCTL_PVR_CREATE_HWRT_DATASET| 0xc088644b  | IOWR | drm_pvr_ioctl_create_hwrt_dataset_args| 136 |
| 0x0c   | DRM_IOCTL_PVR_DESTROY_HWRT_DATASET|0x4008644c  | IOW  | drm_pvr_ioctl_destroy_hwrt_dataset_args| 8  |
| 0x0d   | DRM_IOCTL_PVR_SUBMIT_JOBS        | 0x4010644d  | IOW  | drm_pvr_ioctl_submit_jobs_args       | 16   |

`DEV_QUERY` sub-queries (the C-PVR-b kernel must answer these — they feed
`pvr_device_info`): `GPU_INFO_GET`, `RUNTIME_INFO_GET`, `QUIRKS_GET`,
`ENHANCEMENTS_GET`, `HEAP_INFO_GET`, `STATIC_DATA_AREAS_GET`. Heaps:
`GENERAL`, `PDS_CODE_DATA`, `USC_CODE`, `RGNHDR` (BRN63142 only), `VIS_TEST`,
`TRANSFER_FRAG`. Job types: `GEOMETRY`, `FRAGMENT`, `COMPUTE`, `TRANSFER`.
Context priorities: `LOW`/`NORMAL`/`HIGH` (-512/0/512). Plus the standard
`vk_drm_syncobj` path (`drmSyncobj*` via core libdrm) for sync.

This is the exact ABI C-PVR-b must implement (the `libdrm_amdgpu ↔ amdgpu
kernel` analogue — here direct-ioctl ↔ the imagination DRM driver). The uapi
header is Mesa's `include/drm-uapi/pvr_drm.h` (== the Linux
`drivers/gpu/drm/imagination` uapi); the illumos-patched copy is `pvr_drm.h.patched`.

## Compile-complete vs Jupiter-hardware-gated

**Compile-complete (delivered here):**
- The whole ~97k-LOC imagination tree compiles clean on illumos x86_64.
- `libvulkan_powervr_mesa.so` + `libpowervr_rogue.so`, zero-phantom, dlopen OK.
- The ICD manifest + all three loader entry points.
- The 14-ioctl pvr_drm surface, encoded to match the Linux `_IOC` scheme the
  C-PVR-b kernel decodes.

**Jupiter-hardware-gated (needs the real BXE-2-32 + a live pvr DRM node):**
- **The BXE-2-32 device table.** Mesa 24.0.9 ships only GX6250 / AXE-1-16M /
  BXS-4-64. Running on the Jupiter's BXE-2-32 needs its BVNC + feature table —
  present only in a newer Mesa (25.x-era, which also brings the `pco` compiler).
  Path: rebuild `src/imagination` from a Mesa new enough to carry BXE-2-32
  against this same illumos toolchain (the port work here — the shim, the
  pvr_drm guard, the 5 fixes — carries forward unchanged).
- **The C-PVR-b kernel DRM driver** exposing a `/dev/dri` pvr node that decodes
  the 14 ioctls above. Until that node exists, the winsys has nothing to
  `drmIoctl`.
- All actual rendering / job submission / GPU-VM (runtime = the BXE hardware,
  not this x86_64 build node).

## Files (`src/drm-port/powervr/`)

- `build-mesa-powervr.sh` — the full build (5 fixes + `_BITULL` shim + pvr_drm.h
  `__sun` guard + meson `imagination-experimental` config). Idempotent.
- `powervr_mesa_icd.x86_64.json` — the ICD manifest (install-relative path).
- `pvr-ioctl-encoding.out` — the 14 encoded `DRM_IOCTL_PVR_*` numbers.
- `pvr-glob-undef.txt` / `pvr-weak-undef.txt` — the undef audit inputs.
- `pvr-linux-ioctl-compat.h` — the `_IOC` shim + the added `_BITULL` helpers.
- `pvr_drm.h.patched` — the illumos-guarded pvr_drm.h (the C-PVR-b ABI header).

## Reproduce

    export PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
    sh /root/drm-port/powervr/build-mesa-powervr.sh
    # -> /var/tmp/mesa-powervr-out/lib/libvulkan_powervr_mesa.so
