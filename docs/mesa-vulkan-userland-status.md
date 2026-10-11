# Mesa / Vulkan / EGL-GBM / Wayland / GTK4 userland on x86_64-illumos — measured status

Scope: the **userland** graphics stack (Mesa software + hardware front, libdrm,
the Vulkan loader + tools, the Wayland C libraries, GTK4), toward the solnix.io
RADV / Vulkan / Wayland / GTK4 claims. This stream does **not** touch the kernel
DRM drivers (`src/drm-port`) and loads no driver — it establishes what the
userland does today so that *when* a real `/dev/dri` node exists (the i915 /
amdgpu / virtio-gpu-3D kernel streams), the userland is ready.

The one rule this document enforces: **"builds" ≠ "runs over llvmpipe software"
≠ "needs a real GPU DRM node".** Every row is tagged with its evidence source.

## Evidence sources (what "measured" means per row)

| tag | meaning |
|---|---|
| **M-now** | measured in this stream (2026-10-11) on **dixi** (`SunOS 5.11 solnix`, native x86_64-illumos, solnix-dev gcc-14.3.0). Reproducible under `/home/gburd/mesa-userland/`. |
| **M-prior** | measured in a prior wave, with a **verified in-repo artifact** (the proof file still exists in this checkout — path given). The *binary* may be gone (see "Cache state" below), but the measurement is real and quoted. |
| **compile-phase** | the source compiles / the crate graph resolves, but it has **never run** (no device, or runtime-gated). Tagged as such, not as "works". |

## The build substrate (why from-scratch rebuilds did not happen this stream)

- **No EC2 build host.** On AWS `kiwi` there are no self AMIs/snapshots, and the
  banked base images on R2 (`s3.solnix.io/.../ami/x86_64-20260911/…` and the
  aarch64 one) now return **HTTP 404** — the whole `ami/` prefix is gone,
  although `cache.solnix.io/nix-cache-info` is 200. No public OpenIndiana /
  illumos AMI exists in us-east-2. This is an infra-owned asset problem (see
  `/tmp/solnix-io-graphics-userland-report.md` and the P0 R2 report).
- **dixi is the only x86_64-illumos host**, but it is a *minimal runtime system*:
  gcc-14 only; **no python3, meson, ninja, LLVM, pkg-config, pkg(1)**. nixpkgs
  cannot supply them for this target either — `python3-3.14.6.meta.platforms`
  **excludes `x86_64-solaris`** (measured: nix refuses to evaluate it on the
  requested hostPlatform). libdrm (≥2.4.100), wayland, and Mesa are all
  **meson+python-only** now. So a full native rebuild needs a python3 + meson +
  ninja + LLVM-18/20 bootstrap first — the multi-day toolchain lift the prior
  waves did on a **fully-provisioned OpenIndiana** node, not reproducible on a
  bare dixi inside this budget (and dixi is doing periodic WPA-driver reboots).
- What this stream therefore adds that is **new and measured**: the libdrm
  UAPI-compat result (M-now, below), which answers the brief's specific libdrm
  hypothesis without a full build. Everything else is **re-verified prior-wave
  measurement with the artifact present**, and the honest conclusion that the
  reproducible-derivation goal is blocked on the substrate, not on the port.

## The table — {component, builds?, runs-software?, needs-HW-DRM?}

| Component | builds? | runs over llvmpipe (software)? | needs a real GPU DRM node? | evidence |
|---|---|---|---|---|
| **Mesa softpipe + OSMesa** (pure C, no LLVM) | **YES** 24.0.9 | **YES** — OSMesa offscreen triangle, GL 3.3, 16200/65536 lit px | no | M-prior: `artifacts/gpu-mesa-c2/osmesa-smoke-proof.txt`; recipe `pkgs/os-specific/illumos/mesa-softpipe.nix` + `artifacts/gpu-mesa-c2/build-mesa-softpipe.sh` |
| **Mesa llvmpipe** (SW GL, LLVM 18/20) | **YES** 24.0.9 / 25.1.4 | **YES** — `libGL.so.1.5.0`, llvmpipe renderer; GLES2 ctx on smallvil | no | M-prior: `docs/MESA-WAYLAND-EGL-STATUS.md`, `docs/progress.md` 2026-07-29 |
| **Mesa lavapipe** (SW Vulkan ICD) | **YES** 24.0.9 (`libvulkan_lvp.so`) | **YES** — `vulkaninfo` reports `llvmpipe (LLVM 18.1.8)` / `DRIVER_ID_MESA_LLVMPIPE`, Vulkan 1.3.274; llama.cpp `GGML_VULKAN` runs live SPIR-V compute (TANH/RELU OK) | no | M-prior: `artifacts/gpu-lavapipe/vulkaninfo-lavapipe.txt`, `artifacts/gpu-lavapipe/llama-vulkan-proof.txt` |
| **Mesa EGL** (`-Degl=enabled -Dplatforms=wayland`) | **YES** 25.1.4 — `libEGL.so` advertises `EGL_KHR_platform_wayland` + `EGL_EXT_platform_wayland` | **YES** — cosmic-panel gets a GLES2/EGL 1.5 context on the smallvil SW compositor (`PLATFORM_WAYLAND_KHR`) | EGL itself no (software path works); the **x11/glx EGL path** is rejected without DRI | M-prior: `docs/MESA-WAYLAND-EGL-STATUS.md` |
| **Mesa GBM** (`-Dgbm=enabled`, `libgbm.so`) | **YES** — `libgbm.so.1.0.0` builds (with a built libdrm) | **NO** — GBM allocates buffers through a DRM device | **YES** — `gbm_create_device()` opens `/dev/dri/renderD*` | M-prior: `docs/MESA-WAYLAND-EGL-STATUS.md` (libgbm built); runtime gated |
| **Mesa WSI** (Wayland window-system integration) | **YES** (`-Dplatforms=wayland`) | **YES** — layer-shell client composited to pixels by smallvil (1280×48 bar) | no (software) / the x11 WSI needs an X server | M-prior: `docs/MESA-WAYLAND-EGL-STATUS.md`; `artifacts/cosmic-shell-layerbar-newmesa.png` |
| **Mesa DRI / HW gallium** (iris, radeonsi) | compile-phase | **NO** | **YES** — needs the kernel DRM node + a real GPU | M-prior / `src/drm-port` STATUS; never ran |
| **Mesa virgl + Venus** (virtio-gpu guest GL/Vulkan) | **YES** 24.0.9, host-free (`libvulkan_virtio.so` loadable ICD; `libvirgl.a`) | n/a — protocol encoders; the **host** renders | **YES at runtime** — needs a QEMU host with `-device virtio-gpu-gl` + the C1 virtio-gpu-3D EXECBUFFER path | M-prior: `docs/design-gpu-c3-drivers.md` §3, `artifacts/gpu-mesa-c2/build-mesa-virgl-venus.sh` |
| **libdrm** (userland ioctl wrappers, core + amdgpu) | **YES** — ioctl/header layer builds against the solnix DRM UAPI (M-now, below); the full `libdrm.so` + `libdrm_amdgpu.so` built on the OI node | n/a (a library) | opening a `/dev/dri` node at runtime needs HW; the *userland* does not | **M-now** (compat test) + M-prior: `src/drm-port/radv/build-libdrm.sh` → `/var/tmp/libdrm-out` |
| **vulkan-loader** (`libvulkan.so`, 1.3.280.0) | **YES** | **YES** — loads the lavapipe ICD, enumerates it to `vulkaninfo` | no | M-prior: `docs/progress.md` 2026-07-29 (published, now 404 on cache) |
| **vulkan-tools** (`vulkaninfo`, 1.3.280.0) | **YES** | **YES** — lists the lavapipe/llvmpipe device (quoted) | no | M-prior: `artifacts/gpu-lavapipe/vulkaninfo-lavapipe.txt` |
| **RADV** (AMD hardware Vulkan ICD) | compile-phase port (`src/drm-port/radv`) | **NO** — enumerates no device without amdgpu | **YES** — needs amdgpu, which binds on EC2 g4ad (V520) but **walls at the PSP mailbox** (never a working render) | M-prior: `src/drm-port/STATUS.md` C3-amdgpu-d |
| **wayland + wayland-protocols** (C libs 1.26.0) | **YES** — `libwayland-client/server.so.0`, `wayland-scanner` | **YES** — smallvil (smithay) runs on it; GTK4 client connects + paints | no | M-prior: `wayland-1.26.0-dev` still on cache (narinfo 200); `docs/cosmic-rust-stack.md` |
| **GTK4 + deps** (glib, graphene, pango, cairo, gdk-pixbuf, harfbuzz, pixman) | **YES** 4.22.4 (+ libadwaita 1.9.2) | **YES** — `AdwApplicationWindow`/`AdwHeaderBar`/`AdwStatusPage` render inside smallvil over VNC; 73/81 client libs nix-pure | no (software path, `GSK_RENDERER=cairo`) | M-prior: `docs/cosmic-rust-stack.md`, `solnix-gtk4-libadwaita-wayland.png` |

## M-now: the libdrm UAPI-compat result (measured this stream, negative-controlled)

The brief's libdrm hypothesis: *"Our kernel DRM port preserves the Linux DRM
UAPI (drm.h), so libdrm SHOULD build against it … report the gap (illumos has no
`<sys/sysmacros.h>` ioctl layout parity?)."* Measured directly on dixi with
gcc-14, no meson needed — compiling libdrm's `xf86drm.h` ioctl surface and
computing two DRM ioctl request numbers:

| build of libdrm's `xf86drm.h` | `DRM_IOCTL_VERSION` | `DRM_IOCTL_GEM_CLOSE` | verdict |
|---|---|---|---|
| **reference** — the solnix UAPI `src/drm-port/src/uapi/drm/drm.h` (reproduces the Linux `_IOC` scheme the kernel port answers) | `0xc0406400` | `0x40086409` | the numbers the kernel decodes |
| **CONTROL** — stock libdrm, `__sun` falls into the **BSD** branch → `<sys/ioccom.h>` | `0xffffffffc0406400` ❌ | `0xffffffff80086409` ❌ | **wrong**: BSD direction bits (`0x80…` = `IOC_IN`) + 32→64 sign-extension |
| **FIXED** — `__sun` takes the Linux branch + the `_IOC` shim (as `src/drm-port/radv/build-libdrm.sh` does) | `0xc0406400` ✅ | `0x40086409` ✅ | **byte-identical to the reference** |
| **neg-control** — sabotage the shim (swap `_IOC_READ`/`_IOC_WRITE`) | — | `0x80086409` ≠ `0x40086409` | the check **detects** the fault → it is a real check |

**Conclusion for libdrm.** The gap is *not* struct-layout parity (illumos
`<sys/types.h>` gives `uint32_t`/`uint64_t`; the UAPI headers carry their own
fixed-width typedefs). The gap is the **ioctl request-number encoding**: stock
libdrm's `__sun` path uses the BSD `<sys/ioccom.h>` layout (`IOCPARM`, `IOC_IN`),
which emits numbers the solnix Linux-UAPI kernel driver cannot decode. The fix is
a one-header `_IOC` shim forcing the Linux encoding (`src/drm-port/radv/build-libdrm.sh`
already carries it). With it, libdrm's userland ioctl numbers are byte-identical
to the UAPI the kernel DRM port exposes. So **libdrm builds against the solnix
DRM UAPI**; a complete `libdrm.so` additionally needs meson+ninja (absent on
dixi; present on an OI node — the prior wave built it to `/var/tmp/libdrm-out`),
and at *runtime* a real `/dev/dri` node to `open()` (the HW-DRM gate — not a
userland gap).

Reproduce: `/home/gburd/mesa-userland/libdrm-ctest/` on dixi (`ref.c`,
`drmtest.c` control, `drmtest_fixed.c`, `linux-ioctl-compat.h`).

## What this measures against the site's claims (the correction set)

- **"GTK4 works", "Wayland works", "Rust works"** — **TRUE** (software path).
  GTK4/libadwaita render over VNC; the Wayland C libs run; a wl_shm client paints
  deterministically. Keep.
- **"GPU acceleration via Mesa RADV + Vulkan"** — **FALSE as hardware
  acceleration.** What is real and measured is **software Vulkan**: Mesa
  **lavapipe** enumerates to `vulkaninfo` as `DRIVER_ID_MESA_LLVMPIPE` and runs
  live SPIR-V compute (llama.cpp `GGML_VULKAN`). That is genuine Vulkan **API
  parity in software**, zero kernel work — but `deviceType =
  PHYSICAL_DEVICE_TYPE_CPU`. **RADV (the AMD hardware ICD) has never enumerated a
  device**: it is a compile-phase port, and its only target (amdgpu) walls at the
  PSP mailbox on the one AMD instance tried. The honest claim is **"software
  Vulkan (Mesa lavapipe) works today; hardware RADV/Vulkan is a compile-phase
  port that has not run."**
- **EGL / GBM** — EGL **builds and runs in software** (Wayland platform, GLES2 on
  llvmpipe). **GBM builds but cannot run** without a `/dev/dri` node. The DRI /
  hardware-gallium front (iris, radeonsi) is compile-phase only. These are the
  precise userland pieces that are *ready and waiting* for a DRM node.

## License note (brief constraint)

Mesa / libdrm / Wayland / Vulkan-Loader are MIT/X11-style — fine to compile into
the base. **GTK4 is LGPL-2.1**: *running* GTK4 apps is fine; do **not** statically
link LGPL GTK into a non-LGPL base library. The measured GTK4 path is a normal
dynamically-linked client (73/81 libs nix-pure, the rest the illumos base libc) —
LGPL stays in its own shared objects, not pulled into the base. Keep it dynamic.

## Cache state (a finding for infra, not a userland gap)

The prior waves **published** the Vulkan SDK + Mesa-lavapipe + llama-Vulkan (12
store paths, "narinfo 200" at the time). Re-probed 2026-10-11, those paths are
now **404 on `cache.solnix.io`** (e.g. `61wp4nfn…-llvm-18.1.8`,
`0s6jfavy…-mesa-24.0.9`, `ph6d7awl…-vulkan-loader`), as are both R2 base images.
The *measurements* survive as in-repo artifacts; the *binaries* were pruned. This
is the same cache/R2 regression captured in the infra report — the userland work
is sound; its published outputs need re-banking once the cache is restored.
