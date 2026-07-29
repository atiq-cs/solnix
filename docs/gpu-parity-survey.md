# GPU graphics + AI/LLM-hosting parity survey for solnix (illumos)

Research task (read/analyze/write, **NO builds**). Honesty rule holds: this
document is deliberately pessimistic where illumos is genuinely weak, and blunt
about what is proprietary/blocked vs. multi-year vs. shippable-in-quarters. The
maintainer's stated goal is **Linux parity** for (a) GPU graphics (OpenGL /
Vulkan) and (b) hosting AI/LLM models on machines with one or more GPUs, across
solnix's platforms. Realistically GPUs mean **x86_64** and **aarch64**; sparcv9
and riscv64 have no discrete-GPU story worth surveying and are noted only where
a source tree happens to help them.

Read first (this doc builds on both):
- `docs/desktop-gpu-research.md` — the illumos GPU/CUDA/Vulkan baseline (Q3: DRM
  = old i915/radeon via `illumos/gfx-drm`; Mesa 21.3.9 softpipe, no Vulkan, no
  llvmpipe; CUDA impossible; LLM = CPU-only).
- `docs/netbsd-driver-substrate.md` — the NetBSD `drm2` linux-KPI shim analysis
  (the ~20k-LOC shim adapt path, first modeset ~3–4q, input = the wall).

Evidence gathered 2026-07-29 by fetching public repos/licenses (URLs inline).
Every license below was read from the actual `COPYING`/`LICENSE`/header or the
project's meson/build files, not from third-party summaries. Nothing was
hoarded — all fetches were piped to stdout; no gigabyte checkouts kept.

---

## TL;DR verdict (blunt)

| Goal tier | Achievable? | Horizon |
|---|---|---|
| **SW Vulkan + SW GL parity** (lavapipe + llvmpipe on illumos, X11) | **YES** — real, conformant, GPU-less | **quarters** (gated on LLVM-on-illumos + Mesa rebuild) |
| **CPU LLM hosting** (llama.cpp CPU + OpenBLAS) | **YES — already the baseline** | now |
| **GPU-less "GPU" LLM** (llama.cpp Vulkan backend on lavapipe SW Vulkan) | **YES** as a *correctness/validation* path — slow, not fast | quarters (rides on the SW-Vulkan rung) |
| **HW OpenGL/Vulkan on AMD/Intel** (LinuxKPI-style DRM port → RADV/ANV) | **HARD** — a real port, not a rebuild | **1–2 years** single-engineer |
| **HW GPU LLM on AMD via Vulkan-compute** (RADV on a ported amdgpu DRM) | **HARD** — rides on the HW-DRM rung | 1–2 years (after HW DRM) |
| **CUDA / NVIDIA HW at Linux parity** | **NEAR-IMPOSSIBLE** | not on any credible horizon |
| **ROCm compute stack (HIP/ROCr/rocBLAS)** | **NEAR-IMPOSSIBLE** on illumos (needs amdgpu **+ amdkfd** kernel + a KFD uAPI) | not on any credible horizon |
| **Metal / Apple GPU reuse** | **DEAD END** — proprietary, apple-oss has nothing usable | never |

The one-sentence version: **software Vulkan/GL parity and CPU/Vulkan-compute LLM
are genuinely reachable in quarters with zero kernel work; hardware GL/Vulkan on
AMD/Intel is a 1–2 year LinuxKPI-shim port; CUDA and hardware-NVIDIA parity and
Metal are not happening.**

---

## Source / license matrix

Columns: component | source repo | license | what it provides | illumos-portable? | effort.

### Kernel DRM/KMS (the foundation graphics AND compute both need)

| Component | Repo | License | Provides | illumos-portable? | Effort |
|---|---|---|---|---|---|
| **NetBSD drm2** | `github.com/NetBSD/src` `sys/external/bsd/drm2` | **BSD-2** shim (30/31 shim `.c` NetBSD Foundation BSD-2) over Linux `dist/` (MIT/GPL per-file, ~5.6-era) | Linux DRM/KMS on a non-Linux kernel via a linux-KPI shim; `/dev/dri/*` Linux UAPI; i915/amdgpu/nouveau/radeon/virtio-gpu | **ADAPT the ~20k-LOC shim** to illumos DDI (per netbsd-substrate doc) | ~3–4q to first modeset |
| **FreeBSD drm-kmod** | `github.com/freebsd/drm-kmod` (+ `freebsd-src` `sys/compat/linuxkpi`) | **BSD-2** LinuxKPI (Mellanox/FreeBSD Foundation headers, read verbatim) over Linux DRM (MIT/GPL per-file) | **The most current BSD DRM** — tracks **Linux 6.12** (tag `drm_v6.12.85`); amdgpu **gfx11/RDNA3 present** (`gfx_v11_0.c`, `gmc_v11_0.c`, `soc21.c`, `nv.c`), i915, nouveau; loadable kernel modules via LinuxKPI | **ADAPT** — same shim shape as NetBSD but newer + arguably cleaner-separated (LinuxKPI is a first-class in-tree subsystem) | ~1–2yr for HW GL/Vulkan on one vendor |
| **NVIDIA open-gpu-kernel-modules** | `github.com/NVIDIA/open-gpu-kernel-modules` | **Dual MIT / GPLv2** ("individual files MIT; when linked into a Linux kernel module the result is MIT/GPLv2") | The **only** open NVIDIA kernel path; Turing+ GPUs; **requires GSP firmware blobs + the proprietary NVIDIA userland** (README, verbatim) | **NO (near-impossible)** — 89 Linux-specific `kernel-open/nvidia/nv-*.c` glue files bind hard to Linux kernel APIs; the `src/nvidia/arch/nvalloc/unix/` "unix" seam is the *shared-proprietary-codebase* Unix side, **not** a portable OS-abstraction you can retarget without NVIDIA | 5+ years / vendor-only; see verdict |
| **AMD ROCK-Kernel-Driver / amdgpu** | `github.com/ROCm/ROCK-Kernel-Driver` | **GPL-2.0** (`COPYING`: `SPDX GPL-2.0 WITH Linux-syscall-note`) | AMD amdgpu + **amdkfd** (compute/KFD) kernel driver — the ROCm compute foundation | **LICENSE PROBLEM** for statically-linked CDDL kernel (see §crux); reachable only via a loadable-module + shim, and only *after* a DRM shim exists | multi-year, blocked-adjacent |
| **Intel i915 / xe** | Linux kernel (`drivers/gpu/drm/i915`, `.../xe`) | **GPL-2.0** (MIT on some UAPI headers) | Intel iGPU/dGPU DRM (i915 = older, xe = Arc/Xe) | Same GPL-vs-CDDL issue; **but** i915 rides in NetBSD drm2 / FreeBSD drm-kmod already, so the loadable-shim path applies | rides on the DRM-shim rung |

### Userspace GL / Vulkan (Mesa — the good news)

| Component | Repo | License | Provides | illumos-portable? | Effort |
|---|---|---|---|---|---|
| **Mesa core** | `gitlab.freedesktop.org/mesa/mesa` | **MIT** (core; per-file others in `licenses/`) | GL/GLES/EGL/GBM/Vulkan loader + drivers | **YES — Mesa already knows illumos.** `meson.build` lists `'sunos'` in `system_has_kms_drm` and has an explicit `elif host_machine.system() == 'sunos'` (`-D__EXTENSIONS__`) branch. OI already ships Mesa 21.3.9. | rebuild, not port |
| **lavapipe** (`swrast` Vulkan) | Mesa `src/gallium/frontends/lavapipe` | **MIT** | **A software Vulkan 1.3 that needs NO GPU** — runs on any CPU. Built via `-Dvulkan-drivers=swrast`. | **YES** — needs LLVM-on-illumos (uses llvmpipe underneath) + Mesa rebuild; **zero kernel work** | **~1–2q (LLVM + rebuild)** — the SW-Vulkan parity path |
| **llvmpipe** (SW GL) | Mesa `src/gallium/drivers/llvmpipe` | **MIT** | JIT'd software OpenGL 4.x — the *fast* SW rasterizer (vs. OI's slow softpipe) | **YES** — needs LLVM-on-illumos + `-Dllvm=true` | ~1–2q (same LLVM dependency; per desktop-gpu R1b) |
| **RADV** (AMD Vulkan) | Mesa `src/amd/vulkan` | **MIT** | Hardware Vulkan on AMD (RDNA etc.) | **YES to build; needs a working amdgpu `/dev/dri` node** — i.e. rides on the HW-DRM rung | rebuild once DRM exists |
| **NVK** (NVIDIA Vulkan) | Mesa `src/nouveau/vulkan` (`-Dvulkan-drivers=nouveau`) | **MIT** | The new open NVIDIA Vulkan driver | **YES to build; needs the NVIDIA open kernel module (or nouveau) + its DRM/uAPI** — which is the near-impossible rung on illumos | blocked below (needs NVIDIA kernel) |
| **ANV** (Intel Vulkan) | Mesa `src/intel/vulkan` (`-Dvulkan-drivers=intel`) | **MIT** | Hardware Vulkan on Intel | **YES to build; needs i915/xe `/dev/dri` node** — rides on the HW-DRM rung | rebuild once DRM exists |
| **zink** (GL-on-Vulkan) | Mesa `src/gallium/drivers/zink` | **MIT** | OpenGL implemented on top of any Vulkan (incl. lavapipe) | **YES** — pure userland; gives GL parity anywhere a Vulkan ICD exists | rebuild |

### Compute / AI-LLM (the hosting goal)

| Component | Repo | License | Provides | illumos-portable? | Effort |
|---|---|---|---|---|---|
| **llama.cpp / ggml** | `github.com/ggml-org/llama.cpp` | **MIT** | LLM inference; backends: **CPU/BLAS, Vulkan, SYCL, CUDA, HIP, Metal** (all selectable at build) | **YES for CPU + Vulkan + SYCL**; CUDA/HIP/Metal need the respective proprietary/kernel stacks | CPU: now. Vulkan: rides on SW/HW Vulkan rung |
| **CUDA** | proprietary (no source) | **Proprietary** | NVIDIA compute userland (drives the CUDA llama.cpp backend) | **NO — near-impossible.** Closed userland, Linux/Windows only; needs the NVIDIA kernel driver too. Even the *open* NVIDIA kernel module doesn't help: CUDA's userspace is not open. | vendor-only / never |
| **ROCm — HIP** | `github.com/ROCm/HIP` | **MIT** (read verbatim) | CUDA-like C++ runtime → drives llama.cpp HIP backend | userland is permissive, **but hard-requires amdgpu + amdkfd (GPL kernel) + KFD uAPI** | blocked below (needs amdkfd) |
| **ROCm — ROCR-Runtime** | `github.com/ROCm/ROCR-Runtime` | **NCSA** (U. Illinois/NCSA, BSD-like; read verbatim) | HSA runtime (ROCr) | permissive userland, same amdkfd kernel dependency | blocked below |
| **ROCm — rocBLAS etc.** | `github.com/ROCm/*` | mostly **MIT/Apache-2.0/NCSA** | GEMM/BLAS libraries | permissive; same kernel dependency | blocked below |
| **oneAPI / SYCL** | Intel oneAPI / DPC++ | **Apache-2.0** (mostly) | SYCL compute → drives llama.cpp SYCL backend; also CPU-fallback | **CPU-SYCL conceivable long-term; GPU-SYCL needs Intel Level-Zero + i915/xe kernel** | CPU path hard; GPU path blocked below |
| **OpenBLAS** | `github.com/OpenMathLib/OpenBLAS` | **BSD-3** | CPU BLAS for llama.cpp CPU backend | **YES** — already in the illumos CPU-LLM plan (T3.3) | now |
| **Metal / Apple GPU** | proprietary; `apple-oss-distributions` | **Proprietary** (open bits useless) | macOS GPU/compute | **DEAD END** — apple-oss ships only `IOGraphics` (legacy VESA/display-mode family), `AppleADBDisplay` (1990s ADB), `IOKitUser/Tools`. **No Metal, no GPU accel, no compute, no IOAccelerator family** is open. | never |

---

## The kernel-license crux (CDDL vs. GPL) — and the verdict

**The problem.** The illumos kernel is **CDDL**. `amdgpu`, `i915`, `xe`, and the
Linux DRM core are **GPL-2.0** (`ROCK-Kernel-Driver/COPYING` = `SPDX GPL-2.0`).
GPLv2 and CDDL are widely regarded as **mutually incompatible for a combined
derivative work**: you cannot statically link GPL driver code into a CDDL kernel
and lawfully redistribute the result, because GPLv2 §2 would require the whole
combined work be GPL, which CDDL sources cannot satisfy. This is the exact same
reasoning that keeps ZFS (CDDL) out of the mainline Linux kernel, run in the
opposite direction.

**How NetBSD and FreeBSD sidestep it.** Neither BSD *relicenses* the Linux
drivers. They do two things:

1. **The shim is BSD-licensed, the Linux code is imported verbatim.** The
   linux-KPI compat layer — FreeBSD `sys/compat/linuxkpi` (BSD-2, Mellanox /
   FreeBSD Foundation headers, confirmed verbatim: `linux_pci.c`,
   `linux_kthread.c`, `linux_idr.c`, `linux_dma_*`, …) and NetBSD
   `drm2/linux` + `common/linux` (BSD-2, NetBSD Foundation) — is *their own BSD
   code*. The imported Linux drivers keep their own MIT/GPL per-file headers.
2. **Loadable kernel module, not statically linked.** The DRM driver ships as a
   **separately-built, separately-licensed loadable `.ko`/kmod** that binds to a
   stable in-kernel KPI at load time. The argument is **"mere aggregation"** /
   dynamic linking at a defined interface — the GPL driver and the BSD/CDDL
   kernel are separate works combined only at runtime by the user, not a single
   distributed derivative. FreeBSD's `drm-kmod` is literally shipped this way
   (out-of-base port, matched to kernel sources, loaded as a module). NetBSD's
   `drmkms` is a loadable module against `files.drmkms_linux`.

Whether "loadable module = not a derivative work" holds is legally **contested**
(the FSF disputes it for Linux; the BSDs and many downstreams operate on it
routinely). But the salient point for solnix: **the BSD projects already ship
Linux-derived GPL DRM against a non-GPL kernel using exactly this loadable-shim
posture, and have for years.** illumos is in the *same* legal posture as the
BSDs here (permissive/weak-copyleft kernel + GPL driver via a stable ABI), and
illumos *already does the analogous thing twice*: the `illumos/gfx-drm` gate
(old i915/radeon Linux DRM as loadable modules) and the `lx` brand's Linux-KPI
emulation. So there is prior illumos practice for "load Linux-derived kernel
code as a module behind a shim."

**VERDICT — loadable-shim path viable? → YES, with a documented caveat.**
The license-clean route for *any* Linux-derived GPU driver on illumos is the
**FreeBSD-drm-kmod / NetBSD-drm2 model**: a **BSD/CDDL-licensed linux-KPI shim +
the Linux DRM driver imported verbatim with its own headers, shipped as a
loadable CDDL-kernel module** that binds the Linux DRM UAPI to `/dev/dri/*`.
This is the same model `gfx-drm` already uses. It is **viable and has precedent**
— it is *not* a static-link CDDL/GPL merge, so it does not create the classic
conflict. Caveats that must be handled per-driver, not hand-waved: (a) keep the
GPL driver as a distinct module with its headers intact; (b) the shim is your
own BSD/CDDL code; (c) firmware blobs (amdgpu ucode, NVIDIA GSP) carry their own
redistribution terms and must be checked separately; (d) NVIDIA's dual MIT/GPLv2
open module is fine to *build from* but useless without its proprietary
userland/GSP firmware. **The licensing is the *smaller* problem; the engineering
(the ~20k-LOC shim adapt + a moving illumos DDI) is the real cost.**

Bottom line: **the kernel license does NOT block a Linux-derived DRM on illumos**
— the loadable-shim path (proven by gfx-drm, NetBSD, FreeBSD) is the answer.
CUDA and ROCm are blocked by *engineering and proprietary-userland* reasons, not
primarily by the kernel license.

---

## Parity ladder A — GRAPHICS (OpenGL / Vulkan)

SW-first (zero kernel work) → HW (the LinuxKPI-shim port).

```
[G0] X11 + Mesa softpipe (SW GL)                                   FEASIBLE NOW
      └ OI already ships Mesa 21.3.9 softpipe; slow but real GL. (desktop-gpu R1)

[G1] LLVM-on-illumos + Mesa rebuild -Dllvm=true → LLVMPIPE (fast SW GL)   ~1-2q
      └ big usability win; JIT'd GL 4.x. Independent of any kernel/DRM.

[G2] Same rebuild -Dvulkan-drivers=swrast → LAVAPIPE (SW VULKAN 1.3)      ~1-2q  <-- REAL VULKAN PARITY, ZERO KERNEL
      └ lavapipe = a conformant software Vulkan needing NO GPU. This is the
        single biggest parity win available: it gives illumos a *correct*
        Vulkan on any CPU with zero DRM/KMS work. Add zink (GL-on-Vulkan)
        for a second GL path. Mesa already knows 'sunos' (meson.build).
      └ MILESTONE G-A: vulkaninfo + a Vulkan sample render, GPU-less, on illumos.

--- everything below needs the kernel DRM shim (the 1-2yr wall) ---

[G3] LinuxKPI-style DRM shim on illumos (FreeBSD drm-kmod / NetBSD drm2 model):
     adapt the BSD-2 linux-KPI (~20k LOC) to illumos DDI/taskq/kthread/seg-hat;
     ship the Linux DRM driver as a loadable CDDL-kernel module; expose
     /dev/dri/{card,render}* with the Linux DRM UAPI.
     Bring up ONE HW driver first: i915 (old Intel) or amdgpu.              ~1-2yr
      └ MILESTONE G-B: first HW DRM/KMS modeset on illumos at modern-DRM level.
        (netbsd-substrate S1; the keystone — turns Mesa HW drivers into a rebuild.)

[G4] Rebuild Mesa HW Vulkan/GL drivers against the G3 node:
     RADV (AMD Vulkan), ANV (Intel Vulkan), radeonsi/iris (HW GL).          rebuild
      └ MILESTONE G-C: hardware Vulkan/GL on AMD or Intel on illumos.

[G5] (long-shot) NVIDIA: open-gpu-kernel-module port + NVK.                 NEAR-IMPOSSIBLE
      └ requires porting 89 Linux-specific nv-*.c glue files + GSP firmware +
        NVIDIA's proprietary userland pieces. NVK (MIT) could then run, but the
        kernel port alone is a multi-year vendor-scale effort. Do NOT promise.
```

Honest reading: **G0 now; G1/G2 (fast SW GL + SW Vulkan) in quarters and this is
genuine Vulkan/GL parity for correctness — zero kernel work**; G3 (HW DRM) is
the **1–2 year wall**; G4 is a rebuild *once G3 lands*; G5 (NVIDIA HW) is
near-impossible.

---

## Parity ladder B — AI / LLM hosting

CPU now → Vulkan-compute (the CUDA-free GPU path) → long-shot NVIDIA.

```
[L0] llama.cpp CPU backend + OpenBLAS                              FEASIBLE NOW
      └ MIT; already the T3.3 baseline. Real LLM hosting today, CPU-bound.

[L1] llama.cpp VULKAN backend on LAVAPIPE (SW Vulkan from G2)             ~riding on G2
      └ -DGGML_VULKAN=ON. This is a GPU-less "GPU" LLM path: exercises the exact
        Vulkan-compute code path with NO GPU and NO CUDA/ROCm. It will NOT be
        fast (SW Vulkan on CPU ~ CPU speed, minus overhead) — its value is
        VALIDATION: prove the Vulkan-compute LLM path works on illumos before
        any hardware exists.
      └ MILESTONE L-A: llama.cpp Vulkan backend runs a model on illumos, GPU-less.

[L2] llama.cpp VULKAN backend on RADV (HW AMD Vulkan from G4)     rides on G3+G4 (1-2yr)
      └ THE REALISTIC HW-GPU-LLM PATH ON ILLUMOS. Vulkan-compute sidesteps
        CUDA and ROCm entirely: no amdkfd, no HIP runtime, no proprietary
        userland — just a Vulkan ICD (RADV) on a ported amdgpu DRM node.
        Same for ANV on Intel, and NVK on NVIDIA *if* G5 ever happened.
      └ MILESTONE L-B: LLM inference on a real AMD GPU on illumos via Vulkan.

[L3] (blocked) CUDA backend                                       NEAR-IMPOSSIBLE
      └ proprietary userland, no source, needs NVIDIA kernel driver. The open
        NVIDIA kernel module does NOT unlock CUDA (CUDA's userspace is closed).
[L3'] (blocked) ROCm/HIP backend                                  NEAR-IMPOSSIBLE
      └ HIP(MIT)/ROCr(NCSA) userland is permissive, but hard-requires amdgpu +
        AMDKFD kernel + a KFD uAPI on illumos — many quarters past even G3, and
        redundant given L2 (Vulkan-compute) already reaches AMD hardware.
[L3''] (blocked) SYCL/oneAPI GPU backend                          BLOCKED below
      └ needs Intel Level-Zero + i915/xe kernel. CPU-SYCL is a maybe; GPU-SYCL
        rides on the Intel DRM rung. Vulkan-compute (L2) is the simpler path.
```

Honest reading: **L0 now; L1 (Vulkan-compute on lavapipe) is a quarters-scale
*validation* path that needs zero kernel work; L2 (Vulkan-compute on RADV) is
the realistic HW-GPU-LLM path but rides on the 1–2yr HW-DRM wall; CUDA/ROCm/SYCL
are blocked.** The strategic insight: **Vulkan-compute (llama.cpp `GGML_VULKAN`)
is the CUDA-free, ROCm-free GPU-LLM path** — it needs only a Vulkan ICD, which
Mesa gives us (lavapipe in SW today, RADV/ANV on HW once the DRM shim exists).

---

## Blunt parity verdict per tier

- **ACHIEVABLE (quarters, zero kernel work):**
  - **SW Vulkan parity** via **lavapipe** (MIT, Mesa) — a conformant software
    Vulkan 1.3 on any CPU. This *is* Vulkan parity for correctness/portability.
  - **Fast SW OpenGL** via **llvmpipe** (both gated only on LLVM-on-illumos +
    a Mesa rebuild — Mesa already recognizes `sunos`).
  - **CPU LLM hosting** (llama.cpp + OpenBLAS) — already the baseline.
  - **GPU-less "GPU" LLM** (llama.cpp Vulkan backend on lavapipe) — a real
    validation path with no GPU, no CUDA, no ROCm.

- **HARD (1–2 years, real port):**
  - **Hardware OpenGL/Vulkan on AMD or Intel** via a FreeBSD-drm-kmod /
    NetBSD-drm2-style **LinuxKPI shim** ported to illumos (~20k-LOC shim adapt
    against a moving DDI; loadable CDDL-kernel module + verbatim Linux driver).
    FreeBSD `drm-kmod` at **Linux 6.12 with gfx11/RDNA3 amdgpu** is the most
    current, most complete donor.
  - **Hardware GPU LLM on AMD via Vulkan-compute** (RADV on the ported amdgpu
    node) — rides on the above; sidesteps CUDA/ROCm entirely.

- **NEAR-IMPOSSIBLE (do NOT promise):**
  - **CUDA** — proprietary closed userland, Linux/Windows only. The open NVIDIA
    kernel module does not change this; CUDA's userspace is not open.
  - **NVIDIA hardware at Linux parity** — the open kernel module has 89
    Linux-specific glue files + a GSP-firmware + proprietary-userland
    dependency; porting it is a multi-year vendor-scale effort. NVK (MIT) is
    ready in userland but has no illumos kernel to talk to.
  - **ROCm compute stack** — permissive userland, but needs amdgpu **+ amdkfd**
    kernel + KFD uAPI on illumos; redundant with Vulkan-compute anyway.
  - **Metal / Apple GPU reuse** — proprietary; apple-oss ships only legacy
    `IOGraphics`/`AppleADBDisplay`/`IOKitUser` — **nothing GPU-accelerated,
    nothing compute, no Metal, no IOAccelerator family**. Dead end.

---

## Recommended FIRST concrete steps (in order)

1. **LLVM-on-illumos → Mesa rebuild with `-Dllvm=true -Dvulkan-drivers=swrast`.**
   This lands **lavapipe (SW Vulkan) + llvmpipe (fast SW GL)** in one effort and
   gives **immediate Vulkan/GL parity for correctness** with **zero kernel
   work**. Mesa already knows `sunos` (its `meson.build` has an explicit branch
   and lists `sunos` in `system_has_kms_drm`), so this is a *rebuild + fix
   illumos compile breakage*, not a port. **This is the single highest-value,
   lowest-risk first step.** *Gate:* `vulkaninfo` reports lavapipe and a Vulkan
   triangle renders on illumos with no GPU.

2. **llama.cpp Vulkan backend (`-DGGML_VULKAN=ON`) on lavapipe.** Validate the
   **GPU-less "GPU" LLM path** end-to-end. Slow (it's SW Vulkan), but it proves
   the Vulkan-compute LLM pipeline works on illumos *before* any GPU driver
   exists — de-risking the whole HW-GPU-LLM ladder. *Gate:* llama.cpp runs a
   model through its Vulkan backend on illumos.

3. **Evaluate a FreeBSD-drm-kmod-style LinuxKPI shim as the HW gateway.**
   Prefer **FreeBSD `drm-kmod` (Linux 6.12, gfx11/RDNA3, BSD-2 LinuxKPI)** as
   the donor over NetBSD drm2 for currency, but mine both. Do the netbsd-doc's
   **S0 spike** (does `gfx-drm`'s existing `/dev/dri` node already modeset old
   Intel?) cheaply first, then scope the ~20k-LOC shim adapt. This is the 1–2yr
   wall that unlocks HW RADV/ANV → HW Vulkan graphics **and** HW Vulkan-compute
   LLM (L2) in one shot. *Gate:* a scoped port plan + a first HW modeset
   milestone.

4. **Explicitly shelve CUDA, ROCm, NVIDIA-HW, and Metal** as
   documented-not-promised. Revisit only if the HW-DRM shim lands and an amdkfd
   port ever becomes worth the quarters (it likely never beats Vulkan-compute).

---

## Report summary (as requested)

- **Source/license matrix summary:** Kernel DRM donors — NetBSD drm2 (BSD-2
  shim / Linux MIT+GPL), **FreeBSD drm-kmod (BSD-2 LinuxKPI, Linux 6.12,
  gfx11/RDNA3 — the most current BSD DRM)**, NVIDIA open kernel modules (dual
  MIT/GPLv2, but 89 Linux glue files + GSP + proprietary userland), AMD
  ROCK/amdgpu (GPL-2.0), Intel i915/xe (GPL-2.0). Userspace — **Mesa (MIT), and
  Mesa already recognizes `sunos`**; lavapipe/llvmpipe/RADV/ANV/NVK/zink all
  **MIT**. Compute — llama.cpp (MIT, has Vulkan/SYCL/CUDA/HIP/CPU backends), HIP
  (MIT), ROCr (NCSA), rocBLAS (MIT/Apache), oneAPI (Apache), OpenBLAS (BSD-3),
  CUDA/Metal (proprietary, closed).
- **Kernel-license verdict (loadable-shim path viable y/n): YES.** GPL DRM
  statically linked into a CDDL kernel is a conflict, but the
  **FreeBSD-drm-kmod / NetBSD-drm2 loadable-module + BSD-licensed-LinuxKPI-shim**
  model avoids it (BSD shim is our code; Linux driver imported verbatim; combined
  only at load as a module). illumos already does the analogous thing
  (`gfx-drm`, `lx` brand). Licensing is the *smaller* problem; the shim
  engineering is the real cost.
- **Graphics ladder — SW-now / HW-hard:** SW Vulkan (lavapipe) + fast SW GL
  (llvmpipe) = **real parity in quarters, zero kernel work**; HW GL/Vulkan
  (LinuxKPI DRM shim → RADV/ANV) = **1–2 years**; NVIDIA HW = near-impossible.
- **LLM ladder — CPU-now / Vulkan-compute-path / CUDA-blocked:** CPU llama.cpp
  now; **llama.cpp Vulkan backend on lavapipe = GPU-less validation path in
  quarters**; **Vulkan-compute on RADV = the realistic HW-GPU-LLM path
  (CUDA/ROCm-free), riding on the 1–2yr DRM wall**; CUDA + ROCm + GPU-SYCL =
  blocked.
- **Blunt parity verdict per tier:** ACHIEVABLE (quarters) = SW Vulkan/GL parity
  + CPU/Vulkan-compute LLM. HARD (1–2yr) = HW amdgpu/i915 via LinuxKPI port →
  HW Vulkan graphics + HW Vulkan-compute LLM. NEAR-IMPOSSIBLE = CUDA,
  NVIDIA-HW-at-parity, ROCm stack, Metal.
- **Recommended first steps:** (1) LLVM-on-illumos + Mesa rebuild → lavapipe SW
  Vulkan + llvmpipe SW GL (immediate parity, no kernel work); (2) llama.cpp
  `GGML_VULKAN` on lavapipe (validate the GPU-less GPU-LLM path); (3) scope a
  FreeBSD-drm-kmod-style LinuxKPI shim for illumos as the HW gateway (S0 spike
  first); (4) shelve CUDA/ROCm/NVIDIA-HW/Metal as documented-not-promised.

**Do NOT promise CUDA or hardware-NVIDIA parity or Metal — all near-impossible.**

**Confirmations:** no simplification-corner markers written (grep-clean per
instruction); NO git commit;
wrote `docs/gpu-parity-survey.md`; appended `docs/progress.md`; all repo/license
fetches were piped (nothing hoarded — no persisted artifacts).
