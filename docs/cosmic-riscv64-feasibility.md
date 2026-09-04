# COSMIC on riscv64 (Milk-V Jupiter / SpacemiT K1): feasibility + first-build study

Measured on a `solnix-cosmic-riscv` Ubuntu 24.04 x86_64 dev box (m5.4xlarge,
16 cores) as a cross-build study. Every claim below is backed by an artifact
that was built and `readelf`-verified in this session; where something was NOT
proven, it says so.

## Headline

**COSMIC-on-riscv64 is not blocked by Rust, not blocked by the COSMIC crate
graph, and not blocked by the software renderer. All three cross-build today.**
The blocker is the one that was already known: the riscv64 illumos **OS
userland** (libc + crt) does not exist yet, and there is no `/dev/fb`-style
scanout node for a compositor to draw into.

The pleasant surprise: nothing in the 426-crate COSMIC dependency graph, and
nothing in Mesa's llvmpipe/lavapipe, needed a single riscv64 source patch.

---

## Readiness table

| Component | Verdict | Detail |
|---|---|---|
| **Rust riscv64 target (Linux)** | **WORKS** | `riscv64gc-unknown-linux-gnu` is a **Tier 2** upstream target with prebuilt std. Nothing to do. |
| **Rust riscv64 target (illumos)** | **NEEDS-WORK** (target JSON + 1 libc patch + a real libc) | No `riscv64*-illumos` target exists upstream (only `aarch64-unknown-illumos`, `x86_64-unknown-illumos`, `x86_64-pc-solaris`, `sparcv9-sun-solaris`). A custom target JSON is **accepted by rustc and builds full `std`**; one libc patch closes the arch gap; linking needs a real illumos riscv64 libc. See §1. |
| **COSMIC crate graph** | **WORKS** | `libcosmic` 1.0.0 cross-built clean on the **first try**: 359/359 rlibs EM_RISCV, 426 crates, ZERO patches. `cosmic-term` 1.8.0 built to a real riscv64 ELF **and runs** under qemu-user. See §2. |
| **smithay (compositor substrate)** | **WORKS** | Cross-built for riscv64 with the **full** backend set incl. `backend_drm`/`backend_gbm`/`backend_egl`/`renderer_gl`/`backend_libinput`/`backend_session_libseat`/`backend_udev` -> `libsmithay.rlib` EM_RISCV (33 MB). See §2. |
| **lavapipe + llvmpipe (SW renderer)** | **WORKS** | Mesa 25.1.4 cross-built **1124/1124 targets, ~1m43s, ZERO patches**: `libvulkan_lvp.so` (lavapipe) + `libgallium-25.1.4.so` (llvmpipe) + `libEGL_mesa.so` advertising `EGL_KHR_platform_wayland`, all EM_RISCV, against riscv64 LLVM 20.1.2. See §3. |
| **RVV1.0 acceleration of the rasterizer** | **NEEDS-WORK** (not a blocker) | LLVM 20 has full RISC-V vector codegen, but Mesa has **no** riscv SIMD path: `u_cpu_detect.c` knows only x86/NEON/ALTIVEC, and `lp_bld_misc.cpp` only ever pushes `+avx`/`+neon`/`+altivec` into the JIT's MAttrs. So the K1's RVV is **unused** and the rasterizer is scalar. Bounded upstream-shaped change. See §3.3. |
| **Framebuffer / scanout seam** | **NEEDS-WORK** (kernel node + ~250 lines of Rust) | The device half exists and is QEMU-proven (`src/riscv-port/rp64/kernel/virtio_gpu.c`). Missing: the `/dev/fb` node (mmap + 3 ioctls), RISC-V cache maintenance on flush, and a smallvil fb backend (smithay has **no** fbdev backend — verified). Full spec written: `docs/riscv64-scanout-seam.md`. See §4. |
| **illumos Rust patch set carrying to riscv64** | **WORKS** | All existing illumos rust-patches are **OS-gated only** — zero `target_arch` predicates across the whole patch directory. They apply to riscv64 unchanged, and the riscv64-illumos build reproduced **exactly** the same wayland-backend errors those patches already fix. See §2.3. |

---

## 1. Rust for riscv64 illumos — the critical-path question, answered

### 1.1 What exists upstream

`rustc --print target-list` (nightly, 331 targets):

- **riscv64 targets: 15+**, including Tier 2 `riscv64gc-unknown-linux-gnu` plus
  `-freebsd`, `-netbsd`, `-openbsd`, `-fuchsia`, `-redox`, `-musl`, `-none-elf`.
- **illumos/solaris targets: exactly 4** — `x86_64-unknown-illumos` (Tier 2),
  `aarch64-unknown-illumos` (Tier 3), `x86_64-pc-solaris`, `sparcv9-sun-solaris`.
- **There is NO riscv64 illumos or solaris target.** As expected.

### 1.2 A `riscv64gc-unknown-illumos` target is FEASIBLE — proven, not estimated

Built the target spec by crossing the two specs rustc already ships
(`aarch64-unknown-illumos` for the illumos/Solaris base, `riscv64gc-unknown-linux-gnu`
for the riscv64 codegen base). Persisted:
`pkgs/os-specific/illumos/rust-targets/riscv64gc-unknown-illumos.json`.

Key fields (the ones that are decisions, not copies):

```
"arch": "riscv64",  "os": "illumos",  "target-family": ["unix"]
"llvm-target": "riscv64-unknown-solaris2.11"   <- matches the GCC triple
                                                  src/riscv/gcc/config.gcc.riscv-solaris.md
                                                  already targets
"data-layout": "e-m:e-p:64:64-i64:64-i128:128-n32:64-S128"   (from the riscv64 spec)
"llvm-abiname": "lp64d",  "code-model": "medium",  "cpu": "generic-rv64"
"features": "+m,+a,+f,+d,+c,+zicsr,+zifencei"    (RV64GC; the K1 is RV64GCVB)
"is-like-solaris": true,  "linker-is-gnu": false,  "has-rpath": true
"late-link-args": {"unix-cc": ["-lc","-lssp"]}   (the illumos convention)
"max-atomic-width": 64
```

Results, in order:

1. **rustc accepts the JSON** and round-trips it via `--print target-spec-json`.
2. **`-Zbuild-std=std,panic_abort` builds the FULL standard library** for it —
   `core`, `alloc`, `std`, `panic_abort`, `panic_unwind`, `unwind`, `proc_macro`,
   `std_detect`, and **`libc` 0.2.189** — all EM_RISCV, in 13 seconds. This is
   the single most important result in the study: *`std` itself needs no riscv64
   illumos work at all.*
3. **The whole thing LINKS** into a 1.5 MB EM_RISCV PIE executable (§1.4).

Note: cargo now requires `-Zjson-target-spec` alongside `-Zbuild-std` for `.json`
targets; without it you get a confusing "`.json` target specs require
-Zjson-target-spec" error. `RUSTC_BOOTSTRAP=1` on a stable toolchain works the
same way `docs/aarch64-cross-rust.md` describes.

### 1.3 The ONE libc gap — measured exactly, and closed

`libc`'s `src/unix/solarish/mod.rs` picks an arch submodule with a `cfg_if` that
knows only `x86_64` and `x86`. On riscv64 the machine-dependent surface is
therefore absent. Probed it directly; the gap is **exactly five types**:

```
cannot find type `ucontext_t`   in crate `libc`
cannot find type `mcontext_t`   in crate `libc`
cannot find type `fpregset_t`   in crate `libc`
cannot find type `Elf64_Phdr`   in crate `libc`
cannot find type `dl_phdr_info` in crate `libc`
```

The same probe on `x86_64-unknown-illumos` compiles clean, confirming these are
the arch surface and nothing else. `std` does not reference them (which is why
step 2 above succeeded), but downstream crates do.

**Closed** by `pkgs/os-specific/illumos/rust-patches/libc-solarish-riscv64-arch-module.patch`
— a new `src/unix/solarish/riscv64.rs` (RV64: 32 gregs, 32 D-extension fpregs +
fcsr, RISC-V ABI `REG_*` names, the arch-independent `Elf64_*`/`dl_phdr_info`
block copied from the x86_64 module, plus `AV_RISCV_*` hwcap bits including
`AV_RISCV_V` for the K1's RVV) and a three-line `cfg_if` arm in `mod.rs`.
**Verified: with the patch applied, the probe compiles to EM_RISCV.**

The one thing in that patch a real illumos riscv64 `<sys/regset.h>` could order
differently is `NGREG` and the `REG_*` index order; the patch says so in a
comment and follows the NetBSD riscv `_NGREG`/`__gregset_t` layout already cribbed
into `src/riscv/bsd-ref/netbsd/nb_mcontext.h`. Re-verify when the header lands.

### 1.4 The link seam — proven end to end, and it names the OS's homework

Linking for riscv64-illumos fails only for want of illumos libraries. Harvested
the complete list by iterating the real link:

- **Illumos-only LIBRARIES** the target/libc crate name:
  `-lsocket -lposix4 -lnsl -lumem -lsendfile -llgrp -lssp -lresolv` (+ `-lmd -lmp`
  transitively). Same class as the aarch64 wave's `/tmp/aa-syslibs` shim.
- **Illumos-libc-only SYMBOLS** rust `std` references that glibc lacks — **exactly
  twelve**:
  `___errno`, `__posix_getpwuid_r`, `__xnet_bind`, `__xnet_connect`,
  `__xnet_getaddrinfo`, `__xnet_getsockopt`, `__xnet_sendto`, `__xnet_socket`,
  `__xnet_socketpair`, `getexecname`, `pset_info`, `stack_getbounds`.

With those stubbed, **the riscv64-illumos target produces a complete EM_RISCV PIE
executable.** Reproducible via
`pkgs/os-specific/illumos/rust-patches/make-riscv64-illumos-syslib-shim.sh`
(re-ran it from scratch to confirm the persisted script reproduces the link).

That twelve-symbol list is the concrete, finite deliverable this study extracts
for the OS side: **it is the illumos-libc ABI surface the riscv64 userland must
supply for Rust — and therefore all of COSMIC — to run natively.**

### 1.5 Effort estimate: adding riscv64 illumos to Rust properly

| Task | Effort | Notes |
|---|---|---|
| Target spec (JSON, out-of-tree) | **DONE** | persisted; works today |
| Target spec upstreamed (`riscv64gc_unknown_illumos.rs` in rustc) | 1–2 d | mechanical; mirrors `aarch64_unknown_illumos.rs`; Tier 3 needs a maintainer pledge, not code |
| libc solarish riscv64 module | **DONE** (patch) + ~1 d to upstream | verify `NGREG`/`REG_*` against the real header first |
| std bootstrap | **DONE / none needed** | `-Zbuild-std` builds it; std has no riscv64-illumos-specific code |
| The GCC side (`riscv64-unknown-solaris2.11`) | already designed | `src/riscv/gcc/config.gcc.riscv-solaris.md` has the config.gcc delta + `t-sol2` fragment |
| **A real illumos riscv64 libc + crt** | **weeks–months** — the actual critical path | this is the OS userland port, not a Rust task |

**Verdict on §1: a `riscv64gc-unknown-illumos` Rust target is feasible now, and
the Rust-side work is essentially complete (a JSON + a 150-line libc patch). What
gates it is the illumos riscv64 userland, which was always going to gate it.**

---

## 2. The COSMIC crate graph on riscv64 — clean

### 2.1 libcosmic (the toolkit)

`libcosmic` 1.0.0 (pop-os HEAD, submodules incl. the `iced`/`winit`/`softbuffer`
forks), built `--no-default-features --features wayland,tokio` — the same Wayland
software configuration the illumos work uses:

```
Finished `release` profile in 1m 55s
libcosmic.rlib  15.8 MB
359/359 dependency rlibs   EM_RISCV      (NON_RISCV = 0)
426 crates in the graph
ZERO source patches required
```

It worked on the first attempt. Everything that took patches on illumos —
wayland-backend, reis, winit, softbuffer, smithay — needed **nothing** for
riscv64, because those were all OS gaps, not arch gaps.

### 2.2 A real app, and it runs

`cosmic-term` 1.8.0 (the flagship COSMIC app) cross-built in 3m25s to a
**58 MB riscv64 ELF PIE executable** (`Machine: RISC-V`), and **executes** under
qemu-user — `--help` prints the real COSMIC Terminal banner and option list. That
is a genuine riscv64 COSMIC binary running, not just linking.

`smithay` (HEAD) cross-built for riscv64 twice: once at the illumos feature floor
(`wayland_frontend,desktop`) and once with the **full hardware backend set**
(`renderer_pixman,backend_drm,backend_gbm,backend_egl,renderer_gl,backend_libinput,backend_session_libseat,backend_udev`)
— both produced `libsmithay.rlib` EM_RISCV. Notably the DRM/GBM/udev/libseat
`-sys` crates that are the *illumos* wall cross-compile fine for riscv64-Linux;
they are an OS boundary, not an arch one.

`smallvil` (the illumos COSMIC compositor substrate) did **not** build — but for
an upstream API drift entirely unrelated to riscv64: smithay HEAD's winit backend
doesn't compile against current `winit` (`WindowEvent::DragMoved` removed,
`MouseScrollDelta` became `#[non_exhaustive]` → 3–4 errors in
`src/backend/winit/input.rs`). Pinning the smithay/winit pair the illumos wave
uses resolves it; the smithay *library* itself builds for riscv64, which is the
part that matters.

### 2.3 Arch-specific asm/SIMD audit — no blockers

Scanned all 426 crates for `target_arch = "x86*/aarch64"` cfgs and
`core::arch::*` / `asm!` usage. 54 crates have per-arch code. **None blocks
riscv64** — every one either already has a riscv64 arm or falls back to portable
Rust (they all compiled, which is the proof).

Notable: **`getrandom` 0.3/0.4, `rustix` 0.38/1.1, `linux-raw-sys`, `sha2` 0.11,
and `libc` are already explicitly riscv64-aware.** `rustix` mattering is good
news, since it is the crate the illumos work fights most.

The "SIMD-heavy" crates in the graph — `tiny-skia` (the `ICED_BACKEND=tiny-skia`
renderer illumos uses), `swash`, `zune-jpeg`, `png`, `image`, `simd-adler32`,
`memchr`, `glam` — all have scalar fallbacks and all compiled. Expect them to be
*slower* on riscv64 without RVV paths, not broken.

**The illumos patch set is arch-independent.** Grepped the entire
`rust-patches/` directory: zero `target_arch` predicates (only `target_os =
illumos/solaris/linux/android/freebsd`). And the riscv64-illumos build of
`cosmic-config` reproduced **precisely** the errors those patches already fix —
`wayland-backend-0.3.17/src/rs/socket.rs:77` `RecvFlags::CMSG_CLOEXEC`, and the
`common_poll.rs` epoll sites. So **the entire illumos COSMIC patch investment
carries to riscv64 unchanged.** That is the most valuable transferable asset here.

---

## 3. Software Vulkan/GL on riscv64 — works, unaccelerated

### 3.1 The build

Mesa 25.1.4 cross-built for riscv64 with `-Dgallium-drivers=llvmpipe
-Dvulkan-drivers=swrast -Dplatforms=wayland -Dllvm=enabled`:

```
1124/1124 ninja targets      real 1m43s (16 cores)      ZERO source patches
libvulkan_lvp.so        12.2 MB   lavapipe   EM_RISCV   NEEDED libLLVM.so.20.1
libgallium-25.1.4.so    18.4 MB   llvmpipe   EM_RISCV   LLVMInitializeRISCVTarget* present
libEGL_mesa.so.0.0.0     392 KB              EM_RISCV
dri_gbm.so                64 KB              EM_RISCV
```

`libEGL_mesa.so` advertises **`EGL_KHR_platform_wayland` +
`EGL_EXT_platform_wayland`** — the exact extension the x86 wave had to rebuild
Mesa to obtain (`docs/cosmic-rust-stack.md`). It is present by default here, so
the riscv64 desktop does not inherit that fight.

Contrast with the illumos x86 build, which is **softpipe-only, `-Dllvm=disabled`**
(`scripts/build-mesa-waylandegl-softpipe.sh`) to dodge the Solaris libLLVM
soname-search problem. On riscv64-Linux, **full llvmpipe + LLVM works**, which
means a meaningfully faster rasterizer than illumos-x86 has today.

Recipe persisted: `scripts/build-mesa-riscv64-lavapipe.sh`.

### 3.2 The non-obvious requirement

llvmpipe and lavapipe **JIT** the rasterizer, so they need a *target-side* LLVM
and meson must be able to *run* `llvm-config` for that target. Solution: stage
the riscv64 llvm-20 debs and let meson invoke the riscv64 `llvm-config` through
qemu-user binfmt (`exe_wrapper` in the cross file). The riscv64 LLVM 20.1.2
reports all 22 targets built and satisfies llvmpipe's module list
(`bitwriter core engine executionengine instcombine mcdisassembler mcjit native
scalaropts transformutils coroutines lto`) — **`mcjit` + `native` on riscv64 are
present**, which is the fact the whole SW-render story hinges on.

Two traps worth recording: `llvm-config` ships in the `llvm-20` deb, **not**
`llvm-20-dev`; and meson can configure fully and then die at `compress.c:38
zstd.h: No such file or directory` because staged-deb headers aren't in the
cross-gcc's sysroot search path.

### 3.3 RVV1.0 — available in LLVM, unused by Mesa

- **LLVM 20 riscv64 has full vector support**: `llc -march=riscv64 -mattr=help`
  lists `v`, `zve32x/f`, `zve64x/f/d`, `zvl128b`…`zvl16384b`; the shared library
  carries the RISCV vector codegen symbols.
- **Mesa does not use any of it.** `src/util/u_cpu_detect.c` has detection arms
  only for x86 (CPUID), ARM NEON, and ALTIVEC/VSX — no `__riscv` arm at all.
  `src/gallium/auxiliary/gallivm/lp_bld_misc.cpp` builds the JIT's `MAttrs` from
  `+avx*`/`+neon`/`+altivec` only. `src/util/detect_arch.h` *does* detect
  `__riscv` / `__riscv_xlen == 64` (so `DETECT_ARCH_RISCV64` exists), but nothing
  consumes it for SIMD.

So on the K1: **the rasterizer runs scalar on 8 cores at ~1.6 GHz.** The
upstream-shaped fix is small and well-bounded — add a `__riscv` arm to
`u_cpu_detect` (read `AV_RISCV_V` from the illumos hwcap / `hwprobe` on Linux)
and push `+v,+zvl<N>b` into `MAttrs` so LLVM auto-vectorizes the JIT-ed shaders.
Estimate **1–2 weeks** including measurement, and it is a pure performance win,
not a correctness gate. Leave the vector length a **tuning knob** — it varies by
SoC and the K1's X60 is not the only RVV part that matters.

---

## 4. The scanout seam — specified

Full specification: **`docs/riscv64-scanout-seam.md`**. Summary of what it pins
down, since this was the vaguest part of the mission:

**What the compositor needs is only three things** (traced end to end through
softbuffer → wl_shm → smithay → the kernel): an mmap-able linear framebuffer,
mode info, and a synchronous "present" call. It needs **no** DRM/KMS, GBM,
dmabuf, or atomic modeset — that is what `cosmic-comp` wants, and why smallvil is
the substrate (`docs/cosmic-comp-illumos-finding.md`).

**The contract:**

- `/dev/fb` via illumos `visual_io` (the seam `gfx_private`/`vgatext` already use).
- `mmap(fd, 0, stride*height)` → linear, row `y` at byte `y*stride`, physically
  contiguous, offset 0 = pixel (0,0).
- `FBIOGMODE` → `{width, height, stride, format, size}`. **`stride` is a real
  field, not `width*4`** — the K1 DPU needs plane-pitch alignment and QEMU does
  not; a compositor that recomputes it renders a sheared desktop.
- `FBIOFLUSH(damage_rect)` → synchronous present. The kernel does the RISC-V
  `fence` + CMO clean (`src/riscv/uts/cmo.c`), then virtio-gpu's
  `TRANSFER_TO_HOST_2D` + `RESOURCE_FLUSH` (or nothing per-frame on a DPU already
  pointed at the buffer).
- `FBIOSMODE` optional, **may return `ENOTSUP`** — first light inherits U-Boot's
  mode.
- **Format: `XRGB8888`, with no conversion path anywhere.** The whole chain
  already agrees: `virtio_gpu.c` uses `VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM`,
  `WL_SHM_FORMAT_XRGB8888` is the same bytes, smithay-pixman and softbuffer match,
  and the K1 DPU supports it. A per-frame CPU format conversion would cost more
  than the compositing.

**Kernel gap list** (items 1–4 done in `virtio_gpu.c`, 5–8 are the work, all
generic rather than K1-specific): the `/dev/fb` node itself, the mmap
(devmap/segmap), the cache maintenance on flush, and dropping the compile-time
`FB_MAX_W/H 1024x768` cap in favour of mode-sized allocation (a 1920x1080 desktop
needs 8.3 MB).

**Userland gap:** smithay has **no fbdev backend** — verified, `src/backend/` has
drm/egl/x11/winit/libinput/udev/vulkan and no `/dev/fb` reference anywhere in the
tree. A smallvil fb backend is needed: **~250 lines** replacing the winit backend
(open, `FBIOGMODE`, mmap, wrap as a pixman target, `FBIOFLUSH` per frame).
Everything above it — the Wayland frontend, the layer-shell support that already
carries cosmic-panel, the space/window management — is untouched.

**Honest limits of this seam:** no GPU acceleration ever (accepted scoping); no
page flip, so fast motion can tear (add a flip ioctl only if visible); full-screen
flush is O(w·h) per frame unless the damage rect is used; no hardware cursor, so
pointer latency equals frame time.

---

## 5. The single biggest blocker

**The illumos riscv64 userland — libc + crt.** Everything else in the desktop
stack cross-builds today.

Why it is the blocker and nothing else is:

- Rust codegen for riscv64-illumos: **works** (std builds, executables link).
- The COSMIC crate graph: **works** (359 rlibs, a running app binary).
- The software renderer: **works** (llvmpipe + lavapipe, no patches).
- The illumos patch investment: **transfers unchanged** (OS-gated, not arch-gated).
- So the *only* thing standing between these artifacts and a native riscv64
  illumos desktop is an illumos libc for riscv64 to link against — the twelve
  symbols in §1.4 plus, obviously, the rest of libc.

Effort: **weeks to months**, and it is an OS-port task (it is really the riscv64
userland item already in `docs/design-riscv-port.md`), not a COSMIC task. The good
news is that this study makes its *requirements* exact rather than speculative:
the 12-symbol list, the 8 illumos-only libraries, the `riscv64-unknown-solaris2.11`
GCC triple already designed in `src/riscv/gcc/config.gcc.riscv-solaris.md`, and
the `NGREG`/`REG_*` layout the libc patch needs confirmed.

Second-order blocker, much smaller and independently workable: **the scanout node
+ smallvil fb backend** (§4) — days of kernel work plus ~250 lines of Rust, and it
needs **no hardware** because QEMU virtio-gpu exercises it.

---

## 6. Cross-buildable vs must-be-built-on-the-board

**Cross-buildable (proven this session, on a plain x86 Linux box):**

- The entire COSMIC Rust stack: libcosmic, cosmic-term, smithay, cosmic-config.
- Mesa llvmpipe + lavapipe + EGL/GBM.
- `std` + `libc` for the custom riscv64-illumos target.
- The riscv64-illumos link itself (with the syslib shim).
- The `/dev/fb` node work and the smallvil fb backend — QEMU virtio-gpu is the
  test target, and `src/riscv-port/rp64/kernel/virtio_gpu.c` already proves
  scanout there.

**Must be on the board (or a faithful emulation of it):**

- Anything touching the **K1 DPU/HDMI** — the actual plane base, pitch alignment,
  and whether U-Boot leaves a usable framebuffer (`riscv-jupiter-driver-plan.md`
  §7(a) vs §7(b)). Leave mode/stride/format as knobs; U-Boot's default varies by
  board and monitor.
- **RVV performance measurement** — a QEMU RVV model tells you nothing useful
  about X60 vector throughput or the real vector length.
- **`NGREG`/`REG_*` confirmation** against the real illumos riscv64
  `<sys/regset.h>` once it exists (the one uncertain field in the libc patch).
- Desktop **responsiveness** judgement — whether scalar llvmpipe on 8×1.6 GHz X60
  is *pleasant* is an empirical question no cross-build answers.

**Explicitly NOT needed on the board:** every Rust/Mesa compile in this study. The
cross path is fast (libcosmic 2 min, Mesa 1m43s) and should stay the build model.

---

## 7. Artifacts produced

Persisted in the repo:

| Path | What |
|---|---|
| `pkgs/os-specific/illumos/rust-targets/riscv64gc-unknown-illumos.json` | the Rust target spec — rustc-accepted, builds full std |
| `pkgs/os-specific/illumos/rust-patches/libc-solarish-riscv64-arch-module.patch` | the libc solarish riscv64 arch module — closes the measured 5-type gap |

> **⚠️ ARTIFACT STATUS (orchestrator).** Of the four fork-side/repo artifacts, the
> Rust **target JSON** was recovered and is committed to the solnix-pkgs fork at
> `pkgs/os-specific/illumos/rust-targets/riscv64gc-unknown-illumos.json`. The
> **libc patch** and the **syslib shim script** did NOT make it off the build node
> before it terminated, so their *bodies* are lost. They are reconstructable from
> this document, which preserves the full specification:
>   * shim: the illumos-only libraries (`-lsocket -lposix4 -lnsl -lumem -lsendfile
>     -llgrp -lssp -lresolv`, + `-lmd -lmp` transitively) and the **complete
>     twelve-symbol** list in section 1.4 -- that list, not the script, is the
>     deliverable.
>   * libc patch: a new `src/unix/solarish/riscv64.rs` (RV64: 32 gregs, 32
>     D-extension fpregs + fcsr, RISC-V ABI `REG_*`, the arch-independent
>     `Elf64_*`/`dl_phdr_info` block copied from the x86_64 module, `AV_RISCV_*`
>     hwcaps incl. `AV_RISCV_V`) plus a three-line `cfg_if` arm in `mod.rs`, with
>     `NGREG`/`REG_*` following `src/riscv/bsd-ref/netbsd/nb_mcontext.h` pending a
>     real illumos riscv64 `<sys/regset.h>`.
> Cost of reconstruction is roughly an hour, versus the multi-week libc/crt work
> that actually gates this. Lesson applied: see `docs/durability-account-loss.md`
> -- artifacts must be copied off a node as they are produced, not at task end.

| `pkgs/os-specific/illumos/rust-patches/make-riscv64-illumos-syslib-shim.sh` | the link shim + **the 12-symbol illumos-libc ABI surface** rust std needs |
| `scripts/build-mesa-riscv64-lavapipe.sh` | the Mesa riscv64 llvmpipe+lavapipe cross recipe (1124/1124 verified) |
| `docs/riscv64-scanout-seam.md` | the full scanout contract (ioctls, mmap, stride, format, gap list, first-light order) |
| `docs/cosmic-riscv64-feasibility.md` | this report |

Verified on the dev box (terminated at end of session; artifacts are reproducible
from the scripts above):

- `libcosmic.rlib` + 359 dep rlibs, EM_RISCV
- `cosmic-term` 58 MB riscv64 ELF PIE — **runs** under qemu-user
- `libsmithay.rlib` 33 MB EM_RISCV (full backend set)
- `libvulkan_lvp.so` / `libgallium-25.1.4.so` / `libEGL_mesa.so` / `dri_gbm.so`, EM_RISCV
- `rvillumos` 1.5 MB EM_RISCV PIE — the riscv64-**illumos** target linking end to end
- 96 riscv64-illumos std/libc rlibs

---

## 8. Recommended next steps, in order

1. **Confirm the libc patch's `NGREG`/`REG_*` against a real illumos riscv64
   `<sys/regset.h>`** — cheap, and it is the one guess in an otherwise measured
   patch.
2. **Finish the `/dev/fb` seam under QEMU** (§4 items 5–8 + the ~250-line smallvil
   backend). No hardware needed, and it puts the *already-proven* COSMIC session
   on a riscv64 framebuffer. Highest value per unit effort available right now.
3. **Land the riscv64 illumos libc + crt.** The real critical path; §1.4 gives
   the minimum symbol set to target first.
4. **Then** the K1 DPU/HDMI back end behind the same `/dev/fb` node
   (`riscv-jupiter-driver-plan.md` §7(a) first).
5. **Later, for speed:** the Mesa RVV path (§3.3). Pure win, no gate.

Do **not** spend effort on: porting the COSMIC crates to riscv64 (done),
patching Mesa for riscv64 (unnecessary), or a riscv64 Rust std bootstrap
(`-Zbuild-std` handles it).
