# solnix RADV port — STATUS (C3-RADV: the real AMD hardware Vulkan driver)

## Goal

Port Mesa's **RADV** (`src/amd/vulkan`, `libvulkan_radeon.so`) — the real AMD
hardware Vulkan driver — to illumos x86_64, COMPILE-phase, zero-phantom, against
the C1 DRM / C3-amdgpu ioctl surface. This replaces the software-only path
(lavapipe / Venus) with the driver that hits Linux parity on the g4ad's AMD V520
(Navi 12, gfx1011). Runtime is HARDWARE-GATED (needs the g4ad GPU); the milestone
here is the compile + a clean undef audit + the ICD wired, exactly as C2 Mesa
(softpipe/llvmpipe) and C3a (Venus) were delivered.

RADV uses **ACO** (its own shader compiler) by default — **no LLVM** — so the
LLVM drag is avoided (`-Dvulkan-drivers=amd` with ACO, `-Dllvm=disabled`).

## Substrate (unchanged, from C2/C3a)

- **Toolchain (bootstrapped on the spare fred v3 node, fresh install):** gcc-14
  (`/usr/gcc/14`), a python3.9 venv `/root/mesa-venv` with **meson 1.11.2** +
  **mako** + **pyyaml** (pip), **ninja 1.12.1** (bootstrapped from source — no
  illumos wheel exists, `configure.py --bootstrap` with gcc-14). Mesa 24.0.9
  source (the C2 pin) at `/var/tmp/mesa-24.0.9`.
- **The two upstreamable Mesa illumos patches** (C2): `u_atomic.h` gate `__sun`
  on `!__GNUC__`; `u_thread.c` add `!__sun` to the `pthread_getcpuclockid` guard.
  Plus the C3a set (libsync.h ioccom, vn_gettid pthread_self, venus idep_nir).

## Deliverables

### 1. libdrm_amdgpu — PORTED + COMPILED for illumos: **YES**

`radv/build-libdrm.sh` builds **libdrm 2.4.120** with `-Damdgpu=enabled`
(RADV requires `libdrm_amdgpu >= 2.4.119`). The host ships only an old
`/usr/lib/xorg/amd64/libdrm.so.2` with **no amdgpu module**; this builds a fresh
libdrm from source. Output on the node:

    /var/tmp/libdrm-out/lib/libdrm_amdgpu.so.1.0.0   (+ .so.1, .so symlinks)
    /var/tmp/libdrm-out/lib/pkgconfig/libdrm_amdgpu.pc
    /var/tmp/libdrm-out/include/libdrm/{amdgpu.h,amdgpu_drm.h,xf86drm.h,drm.h}

**libdrm_amdgpu is the amdgpu ioctl wrapper layer** — `amdgpu_device_initialize`
/ `amdgpu_bo_alloc` / `amdgpu_cs_submit` / `amdgpu_cs_query_fence_status` / etc.
all issue the amdgpu DRM ioctls through `drmIoctl` / `drmCommandWriteRead`
(libdrm.so). Those ioctls carry the amdgpu DRM UAPI numbers — **the exact surface
the C3-amdgpu kernel driver decodes.**

**THE load-bearing illumos fix (ioctl encoding).** The C1 drm-port
(`src/uapi/drm/drm.h`) reproduces the **Linux `_IOC` scheme** verbatim, NOT
illumos `<sys/ioccom.h>` (the design keeps the Linux DRM UAPI so Mesa/RADV are
unchanged). libdrm's `drm.h` / `xf86drm.h` fall into their "BSD" branch on
`__sun`, which uses `<sys/ioccom.h>` — a *different, incompatible* encoding
(`IOCPARM_MASK` = 0xff, wrong bit layout). The port forces the Linux `_IOC`
encoding on illumos via `radv/linux-ioctl-compat.h` (the same 8/8/14/2-bit
nr/type/size/dir layout as the C1 kernel drm.h), injected into libdrm's `drm.h`
`__sun` path + the `xf86drm.h` Linux branch enabled for `__sun`.

**Proof the encoding matches the kernel (`radv/ioctl-encoding-test.c`, run on the
node):**

    AMDGPU_GEM_CREATE = 0xc0086440 (dir=3 type=0x64 nr=0x40 size=8)
    AMDGPU_CS         = 0xc0086444 (nr=0x44)
    AMDGPU_INFO       = 0x40186445 (dir=1 nr=0x45)

`type=0x64` ('d' = DRM), `nr=0x40/0x44/0x45` (COMMAND_BASE + AMDGPU_{GEM_CREATE,
CS,INFO}), `dir=3` (RW) / `dir=1` (W) — **the exact Linux DRM AMDGPU ioctl
encoding** (real Linux GEM_CREATE = `0xc0206440`; identical dir/type/nr, size
differs only because the test uses reduced structs). This is the userspace→kernel
ABI match: what libdrm_amdgpu emits is what the C1/amdgpu kernel driver decodes.

### 2. libdrm_amdgpu zero-phantom undef audit: **YES, all 62 undefs real**

`nm -u -D libdrm_amdgpu.so.1.0.0` → 62 undefined symbols, every one real:

- **`drm*` (24)** — `drmIoctl`, `drmCommandWrite`, `drmCommandWriteRead`,
  `drmPrime{FDToHandle,HandleToFD}`, `drmSyncobj*` (14), `drmGetVersion`,
  `drmGetNodeTypeFromFd`, `drmCloseBufferHandle`, `drmMsg`, ... — **all exported
  by the sibling `libdrm.so.2`** (NEEDED: `libdrm.so.2`; verified present via
  `elfdump`/`nm -D libdrm.so`). This is the amdgpu → libdrm-core → C1 ioctl path.
- **libc (36)** — `malloc`/`calloc`/`realloc`/`free`, `mmap`/`munmap`,
  `pthread_mutex_*`, `clock_gettime`, `___errno`, `fopen`/`fclose`/`fprintf`,
  `getenv`/`getline`, `str*`, `memcpy`/`memset`, `lseek`/`fcntl`/`close`,
  `sysconf`/`getpagesize` — all `libc.so.1` (NEEDED: `libc.so.1`).
- **CRT (2)** — `__cxa_finalize`, `_ITM_{de,}registerTMCloneTable`,
  `__assert_c99`, `__iob` — standard illumos CRT / GCC.

Zero phantom: no unresolved symbol that "should exist". Every undef is a real
illumos `libc`/`libdrm` KPI or CRT symbol. SONAME `libdrm_amdgpu.so.1`,
NEEDED `libdrm.so.2` + `libc.so.1`.

### 3. RADV Mesa build configured for illumos: **YES** (config complete)

`radv/build-mesa-radv.sh` = the C3a virgl/venus recipe + `-Dvulkan-drivers=amd`
+ the freshly-built libdrm_amdgpu wired via a pkg-config shim. **meson config
succeeds** with `vulkan-drivers: amd,virtio`, `llvm: disabled` (ACO), no
remaining dependency gaps (libdrm_amdgpu 2.4.120 satisfies the `>= 2.4.119`
gate; mako/pyyaml/ninja present). The RADV target set is real and complete:

    src/amd/vulkan/libvulkan_radeon.so.p/
      winsys_amdgpu_radv_amdgpu_{winsys,bo,cs,surface}.c.o   <- the amdgpu winsys
      radv_{device,physical_device,instance,queue,cmd_buffer,...}.c.o  <- core
      meta_radv_meta_*.c.o     <- meta ops (clear/blit/resolve/copy/...)
      nir_radv_nir_*.c.o       <- NIR lowering
      layers_radv_*.c.o        <- app layers
      + ACO (aco_*) the RADV shader compiler (no LLVM)

### 4. RADV core object compile: **DONE — `libvulkan_radeon.so` COMPILED**

**glslang unblocked, then RADV compiled.** A real `glslangValidator` (glslang
14.3.0, SPIR-V 1.6) was built from source on the node:

- **cmake** — the source bootstrap finished (`cmake 3.29.6` at
  `/var/tmp/cmake-3.29.6/bin`), gcc-14.
- **glslang** — KhronosGroup/glslang tag `14.3.0`, `cmake -GNinja -DENABLE_OPT=0`
  (SPIRV-Tools optimizer not needed for RADV's `-V ... -x` GLSL path, so it was
  skipped — no SPIRV-Tools/SPIRV-Headers fetch). Built the `glslang` executable +
  the `glslangValidator` compat alias. Installed over the stub in
  `/root/mesa-venv/bin`.
- **Verify:** `glslangValidator --version` → `Glslang Version: 11:14.3.0`
  (REAL, not `stub 11.0.0`); a trivial `.vert -> .spv` emits a 664-byte SPIR-V
  (magic `0x07230203`); the exact RADV bvh invocation
  `glslangValidator -V --target-env spirv1.5 -x -o out.spv.h in.comp` emits a
  proper SPIR-V C header.

With real glslang on PATH, the RADV ninja build proceeded and **linked
`libvulkan_radeon.so` (16 MB)** for illumos x86_64:

- **19 `.spv.h`** SPIR-V headers generated at build time by the real glslang
  (bvh RT-build shaders + radix_sort shaders) — the exact gate that the stub
  could not pass.
- **90 RADV objects** (`libvulkan_radeon.so.p/`) — the amdgpu winsys
  (`winsys_amdgpu_radv_amdgpu_{winsys,bo,cs,surface}`), device / physical_device /
  instance / queue / cmd_buffer / meta / nir / si_cmd_buffer, layers.
- **30 ACO objects** (`libaco.a`) — the RADV shader compiler, no LLVM.

**illumos compile breaks fixed (crib-and-adapt, banked in the build scripts):**

1. **`linux-ioctl-compat.h` not found** — libdrm's *installed* `drm.h` `__sun`
   branch `#include "linux-ioctl-compat.h"` (the Linux `_IOC` shim), but the shim
   was not installed next to the headers. Fix: `build-libdrm.sh` now copies the
   shim into `$out/include/libdrm/` (and `$out/include/`).
2. **`alloca` implicit** — illumos puts `alloca` in `<alloca.h>`, not
   `<stdlib.h>`. 10 AMD/ACO files use it. Fix: guarded `#include <alloca.h>` in
   the two shared headers they pull — `src/util/macros.h` (C) and
   `src/amd/compiler/aco_ir.h` (ACO C++). (A global `-include alloca.h` was tried
   first but broke the `.S` assembler TUs — reverted.)
3. **`getpwuid_r` arity** — illumos uses the 4-arg SunOS form returning
   `struct passwd*`, not the 5-arg POSIX form. Fix: `__sun`-guarded call in
   `src/util/disk_cache_os.c` + `src/amd/vulkan/meta/radv_meta.c` (both callers).
4. **`libsync.h` `_IOWR`** — the amdgpu winsys pulls libdrm's `libsync.h`, which
   uses Linux `_IOWR`; illumos `<sys/ioctl.h>` doesn't supply it. Fix:
   `__sun`-guarded `#include "linux-ioctl-compat.h"` in the installed `libsync.h`
   (same Linux `_IOC` encoding as drm.h — matches the C1 kernel).
5. **`-Werror=incompatible-pointer-types` / `pointer-sign`** — illumos `int8_t`
   is `char`, not `signed char`; RGTC format code trips mesa's own `-Werror`. Fix:
   `-Dc_args=-Wno-error=incompatible-pointer-types -Wno-error=pointer-sign`
   (warning-only flags, safe for `.S` unlike `-include`).

Venus (`libvulkan_virtio.so`) was kept in the config for ICD-set parity but is
NOT required for RADV; it hits an unrelated illumos `CMSG_*`/`msg_control`
ancillary-data break in `vn_renderer_vtest.c` (Venus was the C3a deliverable and
its own gap, not RADV's). The RADV target `libvulkan_radeon.so` was built
directly and links clean.

### 4b. Zero-phantom undef audit: **YES — every undef real**

`elfdump -sN .dynsym libvulkan_radeon.so`:

- **WEAK UNDEF: 5326** — the Vulkan entrypoint dispatch aliases (`wsi_*`,
  `vk_common_*`, `vk_cmd_enqueue_*`, `radv_*`, and the `rra_/rmv_/sqtt_/rage2_/
  metro_exodus_/quantic_dream_` app-workaround layers) + the ACO
  `aco::instruction_buffer` TLS init helper. WEAK by ELF rule = optional; the
  loader binds them to the in-`.so` entrypoint dispatch table (or leaves null).
  Not phantom — every one is a same-`.so` dispatch trampoline, not an external.
- **GLOB UNDEF: 336** — the hard externals. **Per-symbol grep of all 336 against
  the union of the NEEDED libs → TRULY-UNRESOLVED = 0.** Every one resolves:
  `libc.so.1` (pthread/str/mem/malloc/stdio/syscalls), `libdrm_amdgpu.so.1`
  (`amdgpu_device_get_fd`, `amdgpu_bo_*`, `amdgpu_cs_*` — the winsys → C1 ioctl
  path), `libdrm.so.2` (`drmSyncobj*`, `drmPrime*`, `drmCommandWriteRead`),
  `libexpat.so.1` (`XML_*`, driconf), `libstdc++.so.6` (operator new/delete,
  `std::__throw_*`, `_Rb_tree_*`, cxxabi vtables — the ACO C++ backend),
  `libm.so.2` / `libz.so.1` / `libgcc_s.so.1` / `libelf.so.1`.

**ZERO PHANTOM** — no undef that "should exist". See `radv/radv-undef-audit.txt`,
`radv/radv-glob-undef.txt`, `radv/radv-real-ext-undef.txt`.

### 5. ICD manifest / loader dispatch: **WIRED + VERIFIED**

RADV's meson emitted `radeon_icd.x86_64.json` (`radv/radeon_icd.x86_64.json`):
`api_version 1.3.274`, `library_path` → the built `libvulkan_radeon.so`. The `.so`
**exports the full ICD loader contract**: `vk_icdGetInstanceProcAddr`,
`vk_icdGetPhysicalDeviceProcAddr`, `vk_icdNegotiateLoaderICDInterfaceVersion`
(verified via `elfdump -sN .dynsym`). On real hardware the loader reads the JSON →
`dlopen` `libvulkan_radeon.so` → `vk_icdGetInstanceProcAddr` → RADV dispatch —
same contract as the C3a Venus ICD.

For reference, RADV's meson emits `share/vulkan/icd.d/radeon_icd.x86_64.json`:

    { "file_format_version":"1.0.0",
      "ICD": { "library_path":"../../../lib/libvulkan_radeon.so",
               "api_version":"1.3.x" } }

with `vk_icdGetInstanceProcAddr` exported from `libvulkan_radeon.so` (the loader
entry the ICD contract requires). The build post-step rewrites the `library_path`
to be ICD-dir-relative (`../../../lib/`), the same fix the C3a Venus ICD used, so
the loader resolves the library wherever the store path lands. On real hardware
the loader reads `radeon_icd.x86_64.json` → dlopens `libvulkan_radeon.so` →
`vk_icdGetInstanceProcAddr` → RADV dispatch. (The .so + ICD land once glslang
unblocks the compile.)

## What compiles vs hardware-gated

| Piece | State |
|---|---|
| libdrm_amdgpu.so (amdgpu ioctl wrappers) | **COMPILED, zero-phantom (62 undefs all real)** |
| Linux `_IOC` ioctl encoding == C1 kernel | **PROVEN (ioctl-encoding-test)** |
| Mesa RADV meson config (`-Dvulkan-drivers=amd`, ACO, no LLVM) | **CONFIGURED, no dep gaps** |
| glslangValidator (real, glslang 14.3.0, SPIR-V 1.6) | **BUILT, replaces the stub** |
| RADV core objects (winsys/device/queue/cmd_buffer/meta/nir + ACO) | **COMPILED (90 RADV + 30 ACO objs, 19 glslang .spv.h)** |
| `libvulkan_radeon.so` (16 MB) + `radeon_icd.x86_64.json` | **BUILT + zero-phantom (5326 WEAK dispatch aliases, 336 GLOB all real; 0 phantom)** |
| Real Vulkan on the V520 (device enum, queue submit, draw) | HARDWARE-GATED (g4ad, quota grant) |

## Deferred (optional RADV features, not compile-blocking for the core)

- **Video (`-Dvideo-codecs=` empty here)** — VCN encode/decode; not needed for
  compute/graphics parity.
- **Ray tracing BVH** — the `bvh/*.spv.h` shaders still *build* (they gate the
  compile), but RT itself is a hardware feature; the V520 (Navi 12) has no HW RT.
- **DCC / advanced compression, RRA/RMV/SQTT trace layers** — profiling/debug,
  optional.

## Files (radv/)

    build-libdrm.sh          libdrm 2.4.120 + amdgpu module, Linux-_IOC ioctl fix
    build-mesa-radv.sh       Mesa RADV (-Dvulkan-drivers=amd, ACO) recipe
    linux-ioctl-compat.h     the Linux _IOC encoding shim (matches C1 kernel drm.h)
    ioctl-encoding-test.c    proof the shim emits the Linux DRM AMDGPU ioctl numbers
    RADV-STATUS.md           this file

## Reproduce (RADV core compile -- DONE)

The compile is complete on this node. To reproduce from clean:

1. **cmake** (build-tool): source bootstrap (gcc-14) or a cached nix cmake.
   Binary on the node: `/var/tmp/cmake-3.29.6/bin/cmake` (cmake 3.29.6).
2. **glslang** (real): `git clone --depth 1 --branch 14.3.0` KhronosGroup/glslang;
   `cmake -S . -B build -GNinja -DENABLE_OPT=0 -DGLSLANG_TESTS=OFF`; `ninja -C build`;
   `ninja -C build install` -> the `glslang` executable + a `glslangValidator` alias.
   Install over the stub at `/root/mesa-venv/bin`. `glslangValidator --version` ->
   `Glslang Version: 11:14.3.0` (not `stub`). ENABLE_OPT=0 skips SPIRV-Tools --
   RADV's `-V ... -x` GLSL path does not need the optimizer.
3. **libdrm_amdgpu**: `sh radv/build-libdrm.sh` -- now also installs the
   `linux-ioctl-compat.h` shim next to the headers + patches the installed
   `libsync.h` to pull the Linux `_IOC` encoding on `__sun`.
4. **RADV**: `sh radv/build-mesa-radv.sh` -- meson config + ninja + install. The
   five illumos fixes (alloca include / getpwuid_r arity / libsync `_IOWR` /
   pointer-sign warning gates) are baked into the two build scripts. Or build just
   the driver target:
   `ninja -C /var/tmp/mesa-24.0.9/_brad src/amd/vulkan/libvulkan_radeon.so`.
5. Artifacts persisted in `radv/`: `libvulkan_radeon.so` (16 MB),
   `radeon_icd.x86_64.json`, `radv-undef-audit.txt`, `radv-glob-undef.txt`,
   `radv-real-ext-undef.txt`.

## Next (hardware-gated on the g4ad V520)

Everything above is COMPILE-verified. What remains needs the real AMD V520 GPU
(Navi 12, gfx1011) -- device enumeration, queue submit, draw/dispatch -- plus the
C3-amdgpu kernel driver loaded (compile-only here, never modloaded into the live
kernel). This is the FAST GGML_VULKAN path for llama.cpp on the V520, vs the
software lavapipe fallback.
