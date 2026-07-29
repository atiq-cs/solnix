# Desktop, Wayland, and GPU/CUDA on illumos — state of the art & a phased plan for solnix

Research task (read + analyze + write, no builds). Honesty rule holds: this
document is deliberately pessimistic where illumos is genuinely weak. Where a
claim is verifiable it is cited; where it rests on absence-of-evidence that is
stated as such.

Read first: `docs/package-universe.md` (desktop section), `docs/roadmap.md`
(Phase 3), `.kiro/specs/solnix-phase3-breadth/tasks.md` (T3.7).

Evidence gathered 2026-07-29 by fetching public sources (URLs inline). Primary
smoking gun is OpenIndiana's own `oi-userland` mesa recipe and the
`illumos/gfx-drm` gate — both are authoritative, not third-party summaries.

---

## TL;DR verdict

| Question | Answer |
|---|---|
| Best illumos desktop today | **OpenIndiana Hipster — MATE** (GTK3). Tribblix a close second with Xfce. |
| Wayland on illumos | **Experimental / partial.** The *protocol library* exists (`freeway`, being ported to Solaris). No compositor, no input stack, no Wayland-capable GPU/DRM path. Blocker: **no libinput/evdev/seatd + no Wayland-render backend (mesa built X11-only, no llvmpipe)**. |
| GPU / CUDA | **CUDA impossible** (no NVIDIA kernel driver on modern illumos; Solaris CUDA dropped ~2013). **HW GL: only ancient Intel i915 + AMD r600** via `gfx-drm` mesa 21.3.9. Everything else = **software (softpipe) render**. **Vulkan: none.** LLM = **CPU inference only** for the foreseeable future. |
| COSMIC (System76) | **Aspirational, blocked below the compositor.** cosmic-comp is smithay-on-udev/DRM/libinput; illumos lacks libinput + a Wayland render backend. A *nested/software* COSMIC via smithay's winit+X11 backend is conceivable only *after* the X11 desktop rungs land, and still needs an EGL/Wayland-capable mesa illumos doesn't ship today. Minimal substrate below. |

---

## Q1 — Which illumos distro has the best graphical desktop today?

**Winner: OpenIndiana Hipster, shipping MATE.** Confirmed.

- OI ran GNOME 2 historically and **switched to MATE with release 2016.10**
  (GNOME 2's maintained fork). Source: Wikipedia "OpenIndiana" infobox — desktop
  environment "GNOME 2 … since 2016.10: MATE".
- OI's own handbook documents installing it:
  `pkg install mate_install` then enable the graphical login (lightdm) via
  `svcadm`. Source: docs.openindiana.org handbook, getting-started.
  MATE is GTK3-based, so OI's toolkit floor is **GTK3** (plus GTK2 legacy). Qt5
  is packaged in oi-userland; Qt6 is not a first-class desktop target.
- OI is a **rolling release** built from `oi-userland` with CI; "Hipster is
  actively maintained." Source: Wikipedia. It has real Xorg + DRM (see Q3).

**Tribblix — strong second, Xfce.** Confirmed from tribblix.org "Use" page:
> "To get a basic desktop (twm) using `startx`. To get Xfce, run `startxfce4`."
> and a `setxsession wmaker` multi-window-manager chooser.
So Tribblix ships **Xfce (GTK-based) + twm + WindowMaker**, X11-only, chosen
per-session. Peter Tribble's "omnitribblix" is a variant focused on OmniOS
userland; the dedicated omnitribblix page 404s now, so treat the desktop story
as "Tribblix core = Xfce/twm/wmaker." x86 is described as "pretty solid"; SPARC
"spotty." Source: tribblix.org home + use.html.

**Server-only / no-desktop distros (correctly excluded):**
- **OmniOS** — explicitly server/VM focused ("run servers over the network or
  just building a single VM"), minimal, no bundled desktop. Source: omnios.org.
- **SmartOS** — hypervisor/zone host, runs from RAM, no desktop by design.
- **Nexenta** — effectively dead as a community desktop OS.
- **OpenSolaris / Oracle Solaris 11** — shipped GNOME 2 ("Java Desktop System"
  lineage). Historically the most complete illumos-family desktop, but Oracle
  Solaris is a closed fork, not usable as a solnix source, and is not "modern."

**Toolkit reality across the family:** GTK2 (legacy), **GTK3 (current desktop
floor, MATE/Xfce)**, GTK4 spotty, Qt5 packaged, **Qt6 not a maintained desktop
target**. No modern desktop family ships a Wayland session.

**For solnix:** OI Hipster is the reference. Its `oi-userland` X11/mesa/MATE
recipes are the build recipes to mine (this matches package-universe.md's note).

---

## Q2 — Wayland on illumos: yes / no / experimental?

**Experimental and partial — effectively "no working Wayland session anywhere."**

What exists (evidence):
- `oi-userland/components/wayland/freeway` — **Freeway**, "a small and portable
  implementation of the Wayland protocol for POSIX-compliant operating systems"
  (upstream https://git.sr.ht/~shrub900/freeway, v1.23.0, packaged in OI). Its
  repo log shows a commit literally titled **"solaris backend n portability."**
  Source: oi-userland Makefile + sourcehut summary.
- Freeway ships `wayland-scanner`, `wayland-client-core.h`,
  `wayland-client-protocol*.h`, `wayland-client.h` — i.e. it is a **libwayland
  replacement (the protocol wire library + scanner)**, nothing more. Source:
  freeway.p5m.
- `x11/libxkbcommon` is packaged (keymap handling — a Wayland dependency).

What is **missing** (searched the entire 32,592-path `oi-userland` tree at
`oi/hipster`, recursive): **no `libinput`, no `evdev`, no `seatd`, no
`logind`/`elogind`, no `wlroots`, no `weston`, no `sway`, no `libudev`.** Only
`freeway` under `components/wayland/`. Source: oi-userland git tree API.

**The blocker (the crux the task asked for):** Wayland needs three things
illumos does not have as a stack:
1. **Input** — a working evdev/libinput path. illumos input comes through the
   old Xorg input drivers and `/dev/` kbd/mouse nodes, **not** Linux evdev, and
   **libinput is not ported**. This is the single hardest missing piece.
2. **Buffer/render backend** — a compositor needs GBM+EGL+DRM or a software
   renderer. illumos mesa is built **`-Dplatforms='x11'`** (no `wayland`
   platform) and **`-Dllvm=false`** (no llvmpipe). See Q3. So there is no
   Wayland-EGL and no fast software rasterizer to fall back to.
3. **Session/seat** — seatd/logind-equivalent to arbitrate DRM master + input.
   Not ported.

**Minimally-viable Wayland on illumos** would need, in order: libinput (or a
shim over illumos input), a Wayland render backend (either rebuild mesa with the
`wayland` platform + `gbm`/`egl` — gbm/egl *are* already built, see mesa.p5m —
or a pure-`pixman`/software shm compositor that never touches DRM), and a seat
manager. A **headless/`shm` software compositor** (weston's `headless`/`pixman`
backend, or a wlroots `WLR_BACKENDS=headless`) is the least-blocked path because
it can avoid DRM/KMS and libinput entirely — but it is a curiosity, not a usable
desktop, without input. **Hard-requires DRM/KMS? No** for a nested/headless
compositor; **yes** for a standalone TTY session.

Verdict: **Wayland on illumos is a protocol library + a stalled substrate.** No
distro offers a Wayland session. Blocker = input (libinput/evdev) + a
Wayland-capable render backend.

---

## Q3 — GPU / CUDA / compute on illumos: the blunt truth

**DRM/KMS drivers (kernel):** illumos has exactly one graphics/DRM gate,
`illumos/gfx-drm`. Its README states it "supports **Intel(R) integrated
graphics** with hardware acceleration … GEM … and kernel modesetting (KMS)",
built from an **old (pre-2013-era) freedesktop libdrm snapshot** downloaded at
build time. Kernel modules: **`i915`** (Intel) + DRM misc + AGP. The repo tree
also carries **`radeon`** DRM tests, i.e. an **old AMD `radeon` KMS** driver.
Source: github.com/illumos/gfx-drm README + git tree.

- **No `amdgpu`** (modern AMD), **no `nouveau`** (NVIDIA), **no `vmwgfx`**
  (VMware), **no `virtio-gpu`** in that gate (searched tree — 0 hits). So GPU HW
  accel is limited to **ancient Intel iGPU + old AMD radeon**. Anything from the
  last ~decade of GPUs has **no KMS driver**.

**Mesa (userland):** OI ships **mesa 21.3.9** (2022) with, verbatim from the
`oi-userland` mesa Makefile:
```
-Dgallium-drivers='swrast, i915, r600'
-Dvulkan-drivers=''
-Dplatforms='x11'
-Dllvm=false
-Dgbm=enabled  -Degl=enabled  -Dgles1/2=enabled  -Dosmesa=true
-Ddri-drivers='i965'
```
Reading this honestly:
- **`swrast` (softpipe), NOT llvmpipe** (`-Dllvm=false`). So the software
  renderer is the *slow* softpipe, not the JIT'd llvmpipe. Fixing this needs
  LLVM on illumos + a mesa rebuild — tractable but non-trivial.
- HW gallium: only **i915** (old Intel) and **r600** (old AMD) — matching the
  `gfx-drm` KMS drivers. i965 classic DRI for slightly newer Intel.
- **`-Dvulkan-drivers=''` → NO Vulkan.** None. Not lavapipe, not radv, nothing.
- **`-Dplatforms='x11'` → no Wayland EGL platform** (ties back to Q2).
- gbm/egl/gles/osmesa *are* built — useful primitives, but bound to X11.

**OpenGL:** hardware only on old Intel/AMD via i915/r600; **software (softpipe)**
everywhere else. Real, but slow.
**Vulkan:** **none, on any path.** A software Vulkan (lavapipe) would need
llvmpipe/LLVM first, then a mesa rebuild — multi-quarter, unproven on illumos.

**NVIDIA / CUDA:**
- NVIDIA's proprietary driver did exist for **(Open)Solaris x86** historically,
  but the last Solaris display drivers are legacy (~390-series era) and target
  the **Oracle Solaris kernel ABI**, not modern illumos. There is **no NVIDIA
  kernel driver for modern illumos-gate**.
- **CUDA on Solaris was dropped by NVIDIA ~2013.** CUDA needs the NVIDIA kernel
  driver + a matching userland; **neither exists for illumos**. CUDA is
  therefore **impossible today and for the foreseeable future** — it is a full
  proprietary-driver port that only NVIDIA can realistically deliver.
- **AMD ROCm:** also absent; ROCm hard-requires amdgpu + KFD, neither ported.

**Consequence for LLM hosting (T3.3):** **CPU inference only.** llama.cpp /
bitnet.cpp on CPU (with OpenBLAS) is the realistic path — GPU compute is not on
the table without a kernel-driver porting effort NVIDIA/AMD won't do and the
community hasn't. This exactly matches the honesty note already in T3.3 and the
roadmap.

**Blunt classification:**
- **Impossible (needs vendor/kernel work no one is doing):** CUDA, ROCm,
  modern-GPU HW accel, Vulkan HW.
- **Hard (multi-quarter, community-doable):** llvmpipe (LLVM on illumos + mesa
  rebuild), lavapipe SW-Vulkan, virtio-gpu KMS for VMs, a Wayland mesa platform.
- **Feasible now:** X11 + softpipe SW OpenGL; old Intel/AMD HW GL via gfx-drm.

---

## Q4 — COSMIC (System76): what it needs vs illumos reality

COSMIC (`pop-os/cosmic-epoch`) is a Rust Wayland desktop. Its compositor
`cosmic-comp` is built on **smithay** (Wayland compositor library) and uses
**wgpu** (via iced) for rendering. Mapping each requirement to illumos:

| COSMIC needs | illumos reality | Status |
|---|---|---|
| **Rust toolchain** | rustc/cargo cross+native is in solnix's plan (T3.6); illumos is an upstream Rust target | Feasible (in progress) |
| **smithay DRM/KMS backend** | `smithay`'s `drm`/`udev` are *optional* cargo features (docs.rs/smithay backend module); illumos has only old i915/radeon KMS, no udev | **Blocked** for standalone session |
| **libinput input** | Not ported to illumos (Q2) | **Blocked** |
| **seatd / logind seat mgmt** | Not ported | **Blocked** |
| **udev / devd-equivalent** | illumos uses `devfsadm`/`/devices`, not udev; smithay's udev backend won't bind | **Blocked** (needs a shim) |
| **wgpu backend** | wgpu = Vulkan/Metal/DX12/GL. illumos: no Vulkan, GL = softpipe (no llvmpipe). So wgpu's **GL backend on softpipe** is the *only* candidate | **Hard / software-only** |
| **Wayland protocols + libwayland** | `freeway` provides the protocol lib (Q2); xkbcommon present | Feasible |
| **A Wayland render/present path** | mesa built X11-only, no `wayland` platform, no gbm-on-Wayland | **Hard** (mesa rebuild) |

**smithay's escape hatch:** smithay also ships a **winit backend** and an **x11
backend** (docs.rs/smithay). These let a smithay compositor run **nested inside
an existing X11 (or another Wayland) server**, using winit's window + input
instead of DRM+libinput. That is the *only* plausible COSMIC-on-illumos path:
run `cosmic-comp` **nested in Xorg**, rendering through **wgpu's GL backend on
softpipe** (software). This sidesteps DRM/KMS, libinput, seatd, and udev — the
four hard blockers — at the cost of being **slow, nested, and not a real
session.** Whether upstream cosmic-comp exposes/keeps a winit backend path (vs
hard-wiring the udev backend) is unverified and would need code inspection; the
`cosmic-comp` build deps listed upstream (libinput, udev, dbus) suggest the
standalone udev path is the supported one.

**Honest COSMIC verdict: aspirational, not near-term.** It is **blocked below
the compositor**, not at COSMIC itself. A *software-rendered, X11-nested*
COSMIC is *conceivable* only after: (a) the X11 desktop rungs land, (b) mesa is
rebuilt with **llvmpipe** (so wgpu-GL is tolerable rather than softpipe-slow),
and (c) cosmic-comp's winit/x11 backend is confirmed viable. A *real* COSMIC
Wayland session requires **illumos kernel/userland work that does not exist**:
libinput, a udev/devd shim, seatd/logind, and a Wayland-capable mesa. Those are
multi-quarter porting sub-projects, some (libinput/evdev) touching the kernel
input model.

**Minimal illumos substrate COSMIC would need (least → most blocked):**
1. Rust (in progress) — feasible.
2. X11 + softpipe (feasible) → **llvmpipe** (hard) for usable wgpu-GL.
3. `freeway` libwayland + xkbcommon (have) → confirm wgpu-GL runs on it.
4. smithay **winit/x11 nested** backend → *maybe* a slow, nested COSMIC demo.
5. For a *real* session: **libinput + udev-shim + seatd + Wayland-mesa** — the
   blocked kernel/userland tier.

---

## Dependency ladder for the solnix desktop track

Each rung's status: **feasible-now** / **hard** / **blocked (needs kernel/driver
work)**. Build strictly bottom-up.

```
[R0] Xorg server + xorg libs (mine oi-userland x11/*)                 feasible-now
      └ OI already ships & maintains these; recipes exist.
[R1] mesa 21.3.9 softpipe (SW GL) + gbm/egl/gles (X11 platform)       feasible-now
      └ copy OI's mesa Makefile flags verbatim; softpipe SW render.
[R1b] mesa rebuilt with LLVM → llvmpipe (fast SW GL)                   hard
      └ needs LLVM on illumos first; big usability win for any GUI.
[R2] libxkbcommon, fontconfig(have), freetype(have), cairo, pango     feasible-now
[R3] GTK3 + Qt5 toolkits                                              feasible-now
[R4] A WORKING X DESKTOP: MATE or Xfce (OI/Tribblix recipes)          feasible-now  <-- FIRST REAL GOAL
      └ this is the honest "modern-ish desktop" solnix can actually ship.
--- everything below is the Wayland frontier ---
[R5] freeway (libwayland protocol lib) + wayland-scanner              feasible-now (packaging)
[R6] input stack: libinput / evdev port (or an X-input shim)          BLOCKED (kernel input model)
[R7] session/seat: seatd + logind-equivalent; udev/devd shim          BLOCKED
[R8] Wayland render backend: mesa `wayland` platform + gbm/DRM,       hard→blocked
      or a pixman/shm software compositor (no DRM)                     (shm path: hard; DRM path: blocked)
[R9] a SW-rendered Wayland compositor (weston-headless / wlroots-shm) hard (curiosity w/o R6)
[R10] COSMIC nested-in-X11 via smithay winit + wgpu-GL(softpipe)      hard (needs R1b + backend confirm)
[R11] COSMIC real Wayland session (smithay udev+DRM+libinput+seatd)   BLOCKED (needs R6+R7+R8)
```

Reading the ladder: **R0–R4 are shippable** and give solnix a genuine modern-ish
desktop (MATE/Xfce, GTK3) using OI's proven recipes — this is the realistic
"modern desktop" target. **R5 is easy packaging.** **R6/R7/R8 are the wall** —
input, seat, and Wayland-render are unported and some touch the kernel. COSMIC
lives at **R10 (slow, nested, needs work) / R11 (blocked)**.

---

## Phased desktop TODO (to append to `.kiro/specs/solnix-phase3-breadth`, T3.7)

Split T3.7 into a desktop track with explicit feasibility gates:

- **P-D1 — X11 + SW-mesa + MATE/Xfce (FIRST, feasible-now).**
  Build R0–R4: Xorg server + xorg libs, mesa 21.3.9 (softpipe, copy OI's flags),
  libxkbcommon, cairo/pango, GTK3+Qt5, then **MATE (from OI's `mate_install`
  recipes) OR Xfce (from Tribblix)**. Package + cache all. *Gate:* solnix boots
  to a graphical **X11** MATE/Xfce session (SW-rendered), lightdm/startx works.
  This is the deliverable "modern desktop" for the foreseeable future.
  - **P-D1b (optional, hard):** LLVM on illumos → rebuild mesa with llvmpipe for
    usable SW GL. Prereq for any wgpu/COSMIC experiment.

- **P-D2 — Wayland substrate inventory + input/DRM (hard→blocked).**
  Package `freeway` (R5, easy). Then the research/port sub-project: **libinput
  or an X-input shim (R6), seatd + a udev/devd shim (R7)**. Treat as a
  multi-quarter, kernel-adjacent porting effort — inventory the illumos input
  model gap honestly; do NOT represent Wayland input as "a package build."
  *Gate:* a documented, tested libinput-equivalent enumerating input devices on
  illumos (or a decision that the X-nested path is the only viable one).

- **P-D3 — SW Wayland compositor (hard).**
  Rebuild mesa with the `wayland` platform (R8) OR stand up a pixman/shm
  software compositor that avoids DRM. Bring up **weston-headless / a
  wlroots-shm demo (R9)**. *Gate:* a Wayland client (weston-terminal) renders in
  a software compositor on illumos. Explicitly a proof-of-life, not a desktop.

- **P-D4 — COSMIC (aspirational).**
  With Rust (T3.6) + R1b(llvmpipe): attempt **cosmic-comp nested in Xorg via
  smithay's winit/x11 backend + wgpu-GL** (R10). *Gate:* COSMIC renders a
  window on illumos (slow, nested, SW). The **real Wayland-session COSMIC (R11)
  stays BLOCKED** pending P-D2/P-D3. Document as a tracked long-horizon
  sub-project, not a scheduled deliverable.

- **P-D5 (separate long-horizon, likely-infeasible) — GPU/CUDA/Vulkan.**
  NOT part of the desktop track's critical path. **CUDA/ROCm = impossible**
  without a vendor kernel-driver port; **HW GL limited to old Intel i915 / AMD
  r600 via gfx-drm**; **Vulkan = none** (SW lavapipe needs llvmpipe first). LLM
  work (T3.3) stays **CPU-inference-only**. Keep this as an honest "do not
  promise" note; revisit only if a virtio-gpu KMS or lavapipe port lands.

---

## Sources

- OpenIndiana desktop = MATE since 2016.10 (was GNOME 2): Wikipedia "OpenIndiana"
  infobox; `pkg install mate_install` + lightdm: docs.openindiana.org handbook.
- Tribblix Xfce/twm/wmaker: tribblix.org home + use.html.
- OmniOS server-focused: omnios.org. SmartOS/Nexenta: general knowledge.
- illumos DRM/KMS = i915 + radeon, old libdrm snapshot: github.com/illumos/gfx-drm
  README + git tree (no amdgpu/nouveau/nvidia/vmwgfx/virtio-gpu).
- mesa 21.3.9 flags (swrast/i915/r600, vulkan='' , platforms='x11', llvm=false):
  raw.githubusercontent OpenIndiana/oi-userland .../x11/mesa/Makefile + mesa.p5m.
- No libinput/evdev/seatd/wlroots/weston/sway in oi-userland (32,592-path tree
  search); `wayland/freeway` present: github oi-userland git-tree API.
- Freeway = portable Wayland protocol lib, "solaris backend" commit:
  git.sr.ht/~shrub900/freeway + oi-userland freeway Makefile/p5m.
- smithay drm/libinput/udev optional features + winit/x11 backends:
  docs.rs/smithay backend module; github.com/Smithay/smithay README.
- wgpu backends (Vulkan/Metal/DX12/GL): github.com/gfx-rs/wgpu README.
- COSMIC = smithay + wgpu; cosmic-comp deps libinput/udev/dbus:
  github.com/pop-os/cosmic-epoch README.
- NVIDIA dropped Solaris CUDA ~2013; last Solaris display driver = legacy
  (~390-series, Oracle Solaris ABI): NVIDIA driver archive / general knowledge.
