# solnix desktop + local-AI roadmap (DRM/KMS via NetBSD, Wayland, COSMIC, local LLMs)

## Correction to the earlier "Wayland/Vulkan is a non-goal" assessment

An earlier note (PS-GRAPHICS-STACK) called Wayland/Vulkan/GDM permanent non-goals
because "illumos has no DRM/KMS." That was too pessimistic. **NetBSD has a working,
actively-maintained Linux-DRM compatibility layer** (`src/sys/external/bsd/drm2` —
the `drmkms` framework: `drm_*` core, KMS, GEM/TTM, and per-GPU drivers i915/amdgpu/
radeon/nouveau adapted from Linux). NetBSD runs Mesa DRI on real GPUs through it. That
makes an illumos DRM/KMS port a **porting problem with a proven BSD reference**, not a
from-scratch invention — the same pattern that worked for the ena NIC driver (cribbed
from FreeBSD/illumos-gate). So the desktop stack is long-horizon but ACHIEVABLE.

## Target end state
- **COSMIC desktop** (System76, Rust/Wayland/`smithay`) as the solnix DE.
- **Local LLM inference** via the popular harnesses (llama.cpp / ollama / vLLM-class),
  ideally GPU-accelerated once Vulkan/compute lands, CPU-fallback before that.
- Full X11 apps via **XWayland** (already have the X11 client-lib graph built).

## Phased plan (each phase gated on the prior)

### Phase G0 — X11 desktop first (near-term, achievable NOW)
Already built: X11 client-lib graph + GTK deps. Next: Xorg server (illumos xsvc/FB path,
libdrm-free), gtk3 (finish libepoxy/libglvnd), a lightweight WM/DE over X11, and a
**Mesa `llvmpipe` software-GL** probe (the only GL without DRM). Ship a usable X11
desktop while the DRM work proceeds in parallel. This is the current graphics track.

### Phase G1 — illumos DRM/KMS shim (crib NetBSD drmkms) [the keystone, multi-quarter]
Port NetBSD `external/bsd/drm2` to illumos: the `drm_*` core + KMS + GEM/TTM buffer
mgmt, exposing `/dev/dri/*` + the drm ioctl ABI Mesa/Wayland expect. NetBSD already
solved the "Linux-DRM-on-a-non-Linux-kernel" impedance (linux_* shims, workqueues,
dma-buf, reservation objects) — that shim layer is the crib. Start with a single GPU
family (whatever the target hw / QEMU virtio-gpu is) + GEM. QEMU `virtio-gpu` +
`virtio-gpu-drm` is the cheapest first target (no real GPU needed).
REFERENCE: obtain NetBSD-current `src/sys/external/bsd/drm2` + `src/sys/dev/pci/drm`
(mirror to ~/ws/netbsd-src or the cache). Map NetBSD's `linux/` compat headers to
illumos equivalents (ddi/sunddi, cv/mutex, taskq for workqueues, ...).

### Phase G2 — Mesa DRI + GBM [gated on G1]
With `/dev/dri` + GBM (Generic Buffer Management) from the DRM shim, build Mesa with
the DRI/Gallium drivers + a real (or virtio) hardware driver. This gives GL + EGL +
the GBM platform Wayland compositors need.

### Phase G3 — Vulkan [gated on G2]
Vulkan ICD (Mesa's `vulkan` drivers, e.g. `venus` over virtio, or lavapipe as the
software fallback that needs NO GPU — a good early Vulkan target). lavapipe (CPU
Vulkan) may even precede G1 for compute-only local-LLM use.

### Phase G4 — Wayland + wlroots/smithay [gated on G2/GBM]
wayland libs (needs GBM/DRM from G1/G2) + libinput (needs illumos evdev-equivalent or
a shim) + wlroots or smithay. Then XWayland for X11 apps (X11 libs already built).

### Phase G5 — COSMIC + a display manager [gated on G4]
COSMIC (needs Rust — a Rust-on-illumos toolchain is a prerequisite, currently absent)
+ its Wayland compositor (`cosmic-comp`/smithay) + greeter. Session/seat mgmt: illumos
has no logind — needs a `seatd`-style shim (seatd is simpler than logind and BSD-ported).

### Phase L — Local LLM harnesses (partially independent of graphics)
- **CPU-only now-ish**: llama.cpp builds as portable C++ (needs the C++ toolchain we
  have + BLAS/OpenBLAS — openblas is queued in a sci wave). ggml CPU inference works
  without any GPU. This is the near-term local-LLM path, no DRM needed.
- **GPU-accelerated (gated on G2/G3)**: llama.cpp Vulkan backend once Vulkan lands;
  ollama (Go — needs a Go-on-illumos toolchain, currently absent).
- Prereq toolchains: **Rust** (COSMIC + many LLM tools) and **Go** (ollama) are not yet
  ported to illumos — both are their own porting efforts and gate large parts of this.

## Prerequisites this exposes (track separately)
- **Rust toolchain on illumos** — gates COSMIC + much of the modern LLM tooling.
- **Go toolchain on illumos** — gates ollama + Go-based tools.
- **seatd** (session/seat) — the logind replacement.
- **libinput + evdev shim** — input for Wayland.
- NetBSD-current source mirror as the DRM/KMS crib reference.

## Sequencing note
G0 (X11 desktop + llama.cpp CPU) delivers a usable graphical + local-AI solnix WITHOUT
the deep kernel work. G1 (DRM/KMS from NetBSD) is the keystone that unlocks G2–G5 +
GPU LLMs. Rust/Go toolchain ports run in parallel and gate COSMIC/ollama. This is a
multi-quarter arc, correctly sequenced so each phase ships something usable.

## MILESTONE (2026-08-13): Phase L beachhead — llama.cpp CPU inference LIVE on solnix
llama.cpp (ggml-org tag b4991) built from source for x86_64-solaris + RAN real inference:
`llama-cli -m stories260K.gguf -p "Once upon a time" -n 20` -> "Once upon a time, there was a little
girl named Lily. She loved to play in the par" @ 70 tok/s, prompt-eval 342 tok/s, exit 0. Real ggml
forward pass with OpenMP threads on illumos. CPU backend (LLAMAFILE=1 OPENMP=1); all accelerators OFF.
Binaries: llama-cli/quantize/bench/embedding/perplexity/run + libggml/libllama .so, host-free, published
(pzdqc1lgzkrjxc06mbmqn3x2f0837pyj-llama-cpp-b4991). Recipe: solnix-pkgs pkgs/illumos/llama-cpp.nix.
illumos fixes (baked): RLIMIT_MEMLOCK->__sun guard (illumos has RLIMIT_VMEM), termios winsize include,
CMAKE_SYSTEM_PROCESSOR=x86_64 + explicit AVX/AVX2/FMA/F16C (uname -p=i386 misses ggml SIMD regex),
GGML_BUILD_NUMBER (no git in stdenv), from-source (nixpkgs attr throws unsupported-system on a GPU dep).
=> solnix runs local LLMs on CPU TODAY, ahead of all the GPU/Vulkan/DRM work. GPU-accel comes with
G3 Vulkan (llama.cpp has a Vulkan backend); ollama needs a Go toolchain (separate port).
