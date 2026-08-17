# solnix ANV port — STATUS (C4-ANV: the real Intel hardware Vulkan driver)

## Goal

Port Mesa's **ANV** (`src/intel/vulkan`, `libvulkan_intel.so`) — the real Intel
hardware Vulkan driver (Arc / xe, plus older i915 gens) — to illumos x86_64,
COMPILE-phase, zero-phantom, against the C1 DRM / i915+xe ioctl surface. This is
the Intel arm of the Vulkan-compute-reaches-every-vendor vector (RADV=AMD,
ANV=Intel): one `GGML_VULKAN` reaches every vendor once a DRM node runs. Runtime
is HARDWARE-GATED (needs an Intel GPU + the C1 i915/xe kernel driver); the
milestone here is the compile + a clean undef audit + the ICD wired, exactly as
RADV (C3) was delivered.

ANV uses its **own compiler** (`brw`/`elk` + `isl`/`blorp`/`genxml`) — **no
LLVM** — so the LLVM drag is avoided (`-Dvulkan-drivers=intel`,
`-Dllvm=disabled`).

## Fast follow-on to RADV — the shared substrate

The entire RADV toolchain was reused unchanged:

- **gcc-14** (`/usr/gcc/14`), the `/root/mesa-venv` python venv (**meson
  1.11.2** + mako + pyyaml), **ninja 1.12.1**, **cmake 3.29.6**, and the **real
  glslang 14.3.0** (SPIR-V 1.6) built for RADV — ANV's 5 internal `.glsl`
  shaders (`memcpy_compute`, `generated_draws`, `query_copy_{compute,fragment}`,
  `float64`) compile through the same real glslang.
- Mesa 24.0.9 source at `/var/tmp/mesa-24.0.9` (the C2 pin).
- The freshly-built **libdrm 2.4.120** at `/var/tmp/libdrm-out` supplies
  `dep_libdrm` (syncobj / prime-fd helpers). ANV needs **no libdrm_intel** — see
  below.

## Key architectural finding: ANV needs NO libdrm_intel

Unlike RADV (which links `libdrm_amdgpu.so` for its amdgpu ioctl wrappers),
modern ANV talks the **i915 and xe DRM ioctls directly**. It issues them through
`intel_ioctl(fd, request, arg)` (a plain `ioctl(2)` wrapper in
`src/intel/common/intel_gem.h`), with the ioctl *numbers* coming from the
bundled `include/drm-uapi/{drm,i915,xe}_drm.h` uapi headers — compiled straight
into `libvulkan_intel.so`. There is no separate winsys `.so` to build. ANV picks
i915 vs xe at runtime via its `anv_kmd_backend` abstraction
(`src/intel/vulkan/{i915,xe}/`). Both backends are compiled in.

**xe is the modern uapi** (Arc / Xe kernel driver); i915 is the legacy path.
Both were built (no `-Dintel-xe-kmd` option exists in Mesa 24.0.9 — xe is
unconditional here).

## Deliverables

### 1. ANV `libvulkan_intel.so` — COMPILED for illumos x86_64: **YES**

`anv/build-mesa-anv.sh` = the RADV meson recipe with `-Dvulkan-drivers=intel`
(no amd, no virtio), `-Dllvm=disabled`, `dep_libdrm` wired via the same
pkg-config shim. **meson config succeeds** (`vulkan-drivers: intel`, `llvm:
disabled`, no dep gaps); the genxml python codegen (`intel_genxml.py`,
`gen_zipped_file.py`) ran on the venv python producing **16 genxml headers**;
the real glslang produced the **5 `*_spv.h`** internal shaders; **266 ANV
objects** (device / physical_device / queue / cmd_buffer / allocator /
batch_chain / descriptor_set / pipeline / blorp / the per-gen `libanv_per_hw_ver`
archives for gen90/110/120/125/200 + isl + brw compiler) linked into:

    /var/tmp/mesa-anv-out/lib/libvulkan_intel.so   (22 MB, ELF64 AMD64)
    /var/tmp/mesa-anv-out/share/vulkan/icd.d/intel_icd.x86_64.json

**illumos compile breaks fixed:**

The 5 RADV Mesa-wide fixes carried over unchanged (they are not AMD-specific):

1. **`u_atomic.h`** — gate `__sun` on `!__GNUC__` (C2 patch).
2. **`u_thread.c`** — add `!__sun` to the `pthread_getcpuclockid` guard (C2).
3. **`alloca` in `<alloca.h>`** — guarded `#include <alloca.h>` in
   `src/util/macros.h`.
4. **`getpwuid_r` 4-arg SunOS form** — `__sun`-guarded call in
   `src/util/disk_cache_os.c`.
5. **`-Wno-error=incompatible-pointer-types` / `-Wno-error=pointer-sign`** —
   illumos `int8_t` is `char`; Mesa's own `-Werror` trips on format code.

Plus the ANV-specific illumos fixes:

6. **THE load-bearing ioctl-encoding fix.** The bundled
   `include/drm-uapi/drm.h` "one of the BSDs" branch pulls illumos
   `<sys/ioccom.h>` — a *different, incompatible* `_IOC` encoding
   (`IOCPARM_MASK` = 0xff, wrong bit layout) than the Linux DRM UAPI the C1
   kernel decodes. All the i915/xe ioctl numbers (`DRM_IOCTL_XE_*`,
   `DRM_IOCTL_I915_*`) are built from `_IOWR`/`_IOW`/`_IOR` in that header. Fix:
   inject `anv/linux-ioctl-compat.h` (the same Linux 8/8/14/2-bit
   nr/type/size/dir layout as the RADV port + the C1 kernel drm.h) right after
   the `<sys/ioccom.h>` so the Linux `_IOC` macros win. Same shim, same fix as
   RADV's libdrm drm.h. `src/util/libsync.h` got the same shim on `__sun`.

7. **`futex_wake` / `futex_wait` (ANV-specific).** `anv_allocator.c` calls the
   Mesa util futex unconditionally (state-pool grow path), but
   `src/util/futex.h` only declares them on Linux/FreeBSD/OpenBSD/Win32 — illumos
   has no `futex(2)`. Fix: a portable illumos impl in `src/util/futex.c` — one
   global `pthread_mutex_t` + `pthread_cond_t`, `futex_wake` broadcasts,
   `futex_wait` rechecks the value word under the lock and waits on the condvar.
   Spurious wakeups are fine (every caller loops). Sets `UTIL_FUTEX_SUPPORTED=1`
   for `__sun`. `simple_mtx.c` / `u_queue.h` already had a pthread fallback so
   only anv_allocator needed this. **NOTE:** global lock + one shared condvar
   for all addresses — fine for the low-contention pool-grow path; per-address
   hashing if it ever matters.

### 2. i915 / xe DRM ioctls ported (which uapi): **BOTH (xe modern + i915 legacy)**

Both `include/drm-uapi/xe_drm.h` and `i915_drm.h` compile in with the Linux
`_IOC` encoding forced. **Proof the encoding matches the C1 kernel**
(`anv/anv-ioctl-encoding-test.c`, run on the node — `anv-ioctl-encoding.out`):

    DRM_IOCTL_XE_DEVICE_QUERY  = 0xc0286440 (dir=3 type=0x64 nr=0x40 size=40)
    DRM_IOCTL_XE_GEM_CREATE    = 0xc0386441 (dir=3 type=0x64 nr=0x41 size=56)
    DRM_IOCTL_XE_VM_CREATE     = 0xc0206443 (dir=3 type=0x64 nr=0x43 size=32)
    DRM_IOCTL_XE_EXEC          = 0x40386449 (dir=1 type=0x64 nr=0x49 size=56)
    DRM_IOCTL_I915_GETPARAM    = 0xc0106446 (dir=3 type=0x64 nr=0x46 size=16)
    DRM_IOCTL_I915_GEM_CREATE  = 0xc010645b (dir=3 type=0x64 nr=0x5b size=16)
    DRM_IOCTL_SYNCOBJ_CREATE   = 0xc00864bf (dir=3 type=0x64 nr=0xbf size=8)
    DRM_IOCTL_GEM_CLOSE        = 0x40086409 (dir=1 type=0x64 nr=0x09 size=8)

`type=0x64` ('d' = DRM), `nr = DRM_COMMAND_BASE(0x40) + opcode`, `dir=3` (RW) /
`dir=1` (W). `DRM_IOCTL_GEM_CLOSE = 0x40086409` and `DRM_IOCTL_XE_GEM_CREATE =
0xc0386441` are **identical to real Linux** — the userspace→kernel ABI match:
what ANV's `intel_ioctl` emits is what the C1 / i915+xe kernel driver decodes.
The illumos `<sys/ioccom.h>` BSD encoding was overridden.

### 3. Zero-phantom undef audit: **YES — truly-unresolved = 0**

`elfdump -sN .dynsym libvulkan_intel.so`:

- **WEAK UNDEF: 6357** — the Vulkan entrypoint dispatch aliases (`anv_*`,
  `vk_common_*`, `wsi_*`, `vk_cmd_enqueue_*`). WEAK by ELF rule = optional; the
  loader binds them to the in-`.so` entrypoint dispatch table. Not phantom —
  every one is a same-`.so` dispatch trampoline, not an external.
- **GLOB UNDEF: 254** — the hard externals. **Per-symbol comm of all 254 against
  the union of the NEEDED libs → TRULY-UNRESOLVED = 0.** Categories:
  - **libc.so.1 (80)** — malloc/calloc/free/realloc, mmap/munmap, str/mem,
    pthread_*, clock_gettime, `___errno`, stdio, open/close/read/write/**ioctl**
    (the i915/xe ioctl path via `intel_ioctl`).
  - **libdrm.so.2 (43)** — `drmGetDevices2`, `drmSyncobj*`, `drmPrime*`,
    `drmGetCap`, `drmCrtc*`, `drmAuthMagic` — the `dep_libdrm` helpers.
  - **libz.so.1 (7)** — `deflate*` / `crc32` (disk cache / genxml).
  - **libstdc++.so.6 + libgcc_s.so.1 (19)** — `operator new/delete`
    (`_Znwm`/`_ZdlPvm`), `std::__throw_*`, cxxabi vtables, `_Unwind_Resume` — the
    brw C++ compiler backend. All 15 C++ ABI symbols verified defined in
    `libstdc++.so.6` (`T`/`V`) except `_Unwind_Resume` (defined in
    `libgcc_s.so.1`); both are NEEDED.
  - **libm.so.2** — `cos`/`ceilf` etc.

**ZERO PHANTOM** — no undef that "should exist". See `anv/anv-glob-undef.txt`
(the 254 GLOB) and `anv/anv-unresolved.txt` (the 15 C++ ABI symbols, all
confirmed resolved in libstdc++/libgcc). SONAME `libvulkan_intel.so`, NEEDED
`libdrm.so.2 libz.so.1 libstdc++.so.6 libm.so.2 libgcc_s.so.1 libc.so.1`.

### 4. ICD manifest / loader dispatch: **WIRED + VERIFIED**

ANV's meson emitted `intel_icd.x86_64.json` (`anv/intel_icd.x86_64.json`):
`api_version 1.3.274`, `library_path` → the built `libvulkan_intel.so`. The `.so`
**exports the full ICD loader contract** (verified via `nm -D`):
`vk_icdGetInstanceProcAddr`, `vk_icdGetPhysicalDeviceProcAddr`,
`vk_icdNegotiateLoaderICDInterfaceVersion`. On real hardware the loader reads the
JSON → `dlopen` `libvulkan_intel.so` → `vk_icdGetInstanceProcAddr` → ANV
dispatch — the same contract as RADV's `radeon_icd`.

## What compiles vs hardware-gated

| Piece | State |
|---|---|
| i915 + xe DRM ioctls (Linux `_IOC` == C1 kernel) | **PROVEN (anv-ioctl-encoding-test)** |
| Mesa ANV meson config (`-Dvulkan-drivers=intel`, no LLVM) | **CONFIGURED, no dep gaps** |
| genxml codegen (16 headers) + brw/isl/blorp compiler | **COMPILED (266 objs)** |
| glslang internal shaders (5 `*_spv.h`) | **BUILT (real glslang 14.3.0)** |
| illumos futex fallback (pthread condvar) | **COMPILED** |
| `libvulkan_intel.so` (22 MB) + `intel_icd.x86_64.json` | **BUILT + zero-phantom (6357 WEAK aliases, 254 GLOB all real; 0 phantom)** |
| Real Vulkan on Intel hw (device enum, queue submit, dispatch) | HARDWARE-GATED (Intel Arc/xe GPU + C1 i915/xe kernel) |

## Deferred (optional, not compile-blocking)

- **intel-clc / Ray Tracing** — `-Dintel-clc=disabled` (RT needs the intel-clc
  OpenCL compiler + LLVM; RT is a hardware feature). ANV core builds without it.
- **Video (`-Dvideo-codecs=` empty)** — VCN-equivalent Intel media; not needed
  for compute/graphics parity.
- **anv_hasvk** (the older Haswell/Broadwell Vulkan driver, separate target) —
  not built; xe/i915 modern ANV is the Arc target.

## Files (anv/)

    build-mesa-anv.sh          Mesa ANV (-Dvulkan-drivers=intel, no LLVM) recipe
                               + the 5 RADV Mesa fixes + the ANV ioctl/futex fixes
    linux-ioctl-compat.h       the Linux _IOC encoding shim (== RADV / C1 kernel)
    anv-ioctl-encoding-test.c  proof the i915/xe ioctl numbers match Linux DRM
    anv-ioctl-encoding.out     the proof output
    libvulkan_intel.so         the built driver (22 MB)
    intel_icd.x86_64.json      the ICD manifest (vk_icdGetInstanceProcAddr)
    anv-glob-undef.txt         the 254 GLOB undefs
    anv-unresolved.txt         the 15 C++ ABI symbols (all resolved in stdc++/gcc)
    ANV-STATUS.md              this file

## Reproduce (ANV compile — DONE)

The compile is complete on this node. From the RADV toolchain (glslang/meson/
ninja/libdrm all present):

1. `sh /tmp/patch-futex.sh` — add the illumos futex fallback to Mesa util
   (idempotent; also baked into build-mesa-anv.sh).
2. `sh anv/build-mesa-anv.sh` — meson config + ninja + install. All 7 illumos
   fixes are baked in (idempotent seds/python). Or the driver target only:
   `ninja -C /var/tmp/mesa-24.0.9/_banv src/intel/vulkan/libvulkan_intel.so`.
3. Artifacts persisted in `anv/`.

## Next (hardware-gated on an Intel GPU)

Everything above is COMPILE-verified. What remains needs a real Intel GPU
(Arc/xe or an i915 gen) + the C1 i915/xe kernel driver loaded (compile-only here,
never modloaded into the live kernel) — device enumeration, queue submit,
dispatch. Together with RADV (AMD), this is the two-vendor Vulkan-compute reach:
`GGML_VULKAN` for llama.cpp on Intel and AMD, both real hardware drivers, on
illumos.
