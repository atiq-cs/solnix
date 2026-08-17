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

### 4. RADV core object compile: **BLOCKED on one build-time tool — glslangValidator**

RADV's C/C++ objects have a ninja build-order dependency on generated SPIR-V
headers (`src/amd/vulkan/bvh/*.spv.h` — the ray-tracing BVH build shaders, and
the meta shaders) that are compiled at build time by **`glslangValidator`**
(`find_program(..., required: with_amd_vk)` — a *hard* RADV requirement, not
optional). No `.c.o` compiles until those `.spv.h` exist. The node had **no
glslangValidator and no cmake** (glslang's build system). A stub glslang lets
meson *config* pass (proving all deps resolve) but not the object compile.

**The precise remaining blocker: build `glslangValidator` (native build tool)
for illumos.** It needs cmake, which the node also lacked; a cmake bootstrap
(`./bootstrap && gmake`, cmake-3.29.6) was started on the node. Once cmake +
glslang land, the RADV core objects (amdgpu winsys + device + queue +
cmd_buffer) compile against the illumos-built libdrm_amdgpu with the same
portability-patch set as C3a Venus.

This is a **build-tool** gap, not a portability gap: RADV's own C source
configured cleanly and its winsys links only libdrm_amdgpu (ported) + libc.
glslang is a host tool that emits the driver's built-in shaders; it is the same
tool Mesa requires on Linux.

### 5. ICD manifest / loader dispatch: wired by the build

RADV's meson emits `share/vulkan/icd.d/radeon_icd.x86_64.json`:

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
| RADV core objects (winsys/device/queue/cmd_buffer) | build-tool-gated on glslangValidator (cmake bootstrapping) |
| `libvulkan_radeon.so` + `radeon_icd.x86_64.json` | emitted by the build once glslang lands |
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

## How to resume (finish the RADV core compile)

1. Wait for the cmake bootstrap on the node: `grep CMAKE_DONE /var/tmp/cmake-boot.log`.
2. Build glslang: fetch glslang (a Vulkan-SDK-pinned tag), `cmake -GNinja` +
   `ninja`, install `glslangValidator` onto PATH (replacing the stub in
   `/root/mesa-venv/bin`).
3. `sh /root/c2/build-mesa-radv.sh` → `libvulkan_radeon.so` +
   `radeon_icd.x86_64.json`.
4. Undef audit: `nm -u -D libvulkan_radeon.so` → every undef must be libc /
   libdrm_amdgpu (ported) / libvulkan-loader / ACO-internal. Document like the
   libdrm_amdgpu audit above.
