# solnix.io graphics claims audit — measured 2026-10-10

Can we **test, demonstrate, and use daily** each graphics/desktop claim solnix.io makes?
This audits every published graphics/desktop/wifi claim against what is real in the repo at
HEAD `f73eda9b`, verifying that each cited artifact actually exists. Refuting a claim with
evidence is the point of this document.

Site snapshot (verbatim quotes + the strip of each page) is at
`/tmp/solnix-site-snapshot/` (fetched with `curl`, static server-rendered HTML — not a JS shell).

## Bottom line

The real, reproducible desktop result is: **COSMIC *applications* (cosmic-term) paint reliably
under the `smallvil` software compositor (Mesa softpipe/llvmpipe GLES2), displayed over VNC on
an SSH tunnel, on an x86_64 EC2 instance.** That is a genuine, re-verified win. It is **not**
hardware GPU acceleration, **not** RADV, **not** Vulkan, **not** cosmic-comp, **not** a
login-to-desktop on bare metal, and **not** usable as a daily driver. The published site
describes a *hardware-accelerated RADV/Vulkan COSMIC desktop* that does not exist today.

No wifi/wireless claim appears anywhere on the public site, so there is nothing to audit there
(the `iwm` attach fix at HEAD is internal, not a published claim).

## Claim-by-claim table

| # | Claim (verbatim + URL) | What REAL means (measured, with artifact/doc path) | VERDICT | The gap |
|---|---|---|---|---|
| 1 | "The COSMIC desktop now runs on solnix" — https://solnix.io/ , /handbook, /download, /news/cosmic-desktop-runs-on-solnix.html | COSMIC **apps** run; the **cosmic-comp compositor does not** and cannot compile on illumos (`rustix::ioctl::opcode` absent for `solarish`, root-caused in `docs/cosmic-comp-illumos-finding.md`). The substrate is `smallvil` (smithay winit→X11, software). cosmic-term paints steadily (byte-identical VNC captures across time, md5 `628cd67b`); the full COSMIC **shell** (cosmic-panel) does **not** render — it exits on a missing EGL wayland platform in system Mesa 21.3.9. (`docs/desktop-connectable-status.md`) | **misleading** | "runs" implies a desktop you log into and use. Reality: single COSMIC app paints under a software compositor over VNC; the shell/panel does not composite; no cosmic-comp. |
| 2 | "the graphical stack works on illumos: Rust, Wayland, GTK4, and GPU acceleration via Mesa RADV + Vulkan" — https://solnix.io/ , /handbook | Rust ✓, Wayland ✓, GTK4 ✓ are real (COSMIC apps build; a raw wl_shm client paints deterministically: `artifacts/solnix-smallvil-wlshm-paint.png`, a real 1280×800 PNG; and cosmic-term paints steadily, md5 `628cd67b`). **"GPU acceleration via Mesa RADV + Vulkan" is false today**: the actual render path is Mesa **softpipe/llvmpipe** (software), proven in `docs/desktop-connectable-status.md` and the Aug-18 build records (`docs/post-stable-backlog.md`, entries dated 2026-08-18: `mesa-swrast-llvmpipe`, `llvmpipe/softpipe`, "**NO DRM**"). RADV never ran — it is a compile-phase port (`src/drm-port/radv`). | **misleading** | Rust/Wayland/GTK4 true. "GPU acceleration via Mesa RADV + Vulkan" is not: it is software rendering (llvmpipe/softpipe). No RADV, no Vulkan, no `/dev/dri` in the stack that produced the demo. |
| 3 | "hardware GPU acceleration through Mesa's RADV Vulkan driver" — https://solnix.io/news/cosmic-desktop-runs-on-solnix.html (2026-08-18) | **No hardware GPU acceleration exists.** The Aug-18 demo (`docs/post-stable-backlog.md` `PS-SOLNIX-AMI` `ami-000a59cf344644604`) is a VNC desktop with `mesa-swrast-llvmpipe`, running twm/xterm/gtk-demo — **not COSMIC** on that AMI, and the binaries are **native OI-pkg, not nix-native**. The COSMIC side (`PS-X86-COSMIC-STAGE6`) is `smallvil` on **llvmpipe/softpipe**, "cosmic-comp SW-backend NOT built (DRM-walled)". No `vulkaninfo`/`vkcube` has ever listed a GPU on illumos. The news article cites **no artifact**. | **misleading** (unverified: no artifact) | The strongest overclaim. "hardware GPU acceleration" via "RADV" is contradicted by the repo's own same-day records. Software rendering only. |
| 4 | "GPU acceleration via Mesa RADV + Vulkan ✓" (green check = done) — https://solnix.io/download (#graphical card) | Same as #2/#3. The checkmark asserts a finished capability. The real state: RADV/anv/iris are **compile-phase ports** that have never run (`docs/x1-gpu-route.md` §4 R2/R4). amdgpu (the only RADV target) **binds but walls at the PSP mailbox** on EC2 g4ad V520 (`src/drm-port/STATUS.md` C3-amdgpu-d) and never reaches a working render. The X1 has **no AMD GPU** at all (Intel UHD 630 iGPU + NVIDIA Pascal dGPU; `docs/x1-gpu-route.md` §1). | **misleading** | A ✓ on a capability that has never executed. RADV is AMD-only; the demo machine and the X1 have no working AMD GPU render path. |
| 5 | Roadmap Phase 6 "GPU & accelerator compute … Mesa RADV + Vulkan now drive the COSMIC desktop on solnix." STATE: **in progress** — https://solnix.io/roadmap | RADV/Vulkan drive **nothing**. See #2–#4. The phase being "in progress" is honest; the sentence "now drive the COSMIC desktop" is not — software (softpipe/llvmpipe) drives it. | **misleading** (phase state ok, sentence wrong) | Remove/soften "now drive"; the GPU path has not reached runtime (T6.1 itself says "runtime bring-up on GPU hardware **in progress**"). |
| 6 | Roadmap Phase 7 "Graphical desktop — COSMIC desktop runs (Rust, Wayland, GTK4, RADV/Vulkan proven); graphical install ISO/DVD; libadwaita + full app set." STATE: **in progress** — https://solnix.io/roadmap | "RADV/Vulkan proven" is false (see #3). "COSMIC desktop runs" is qualified (see #1 — apps, not shell, software, VNC). ISO/DVD + libadwaita + full app set are not yet shipped. Phase state "in progress" is honest. | **true-but-qualified** (the phase); **misleading** ("RADV/Vulkan proven") | Strike "RADV/Vulkan proven". The rest is correctly future/in-progress. |
| 7 | "A graphical install ISO is coming soon" / "A live graphical installer with the COSMIC desktop … What's left is packaging it" — https://solnix.io/ , /handbook, /download | A GUI installer image (`usb-image-20261003-gui3`) was built and KVM-boot-verified. **It renders the TEXT installer, not COSMIC** — the live ramdisk stages no smallvil and no Xorg, so its own guard falls back to the text front-end (`docs/desktop-connectable-status.md`, screenshot `artifacts/install-media/usb-image-20261003-gui3/boot-logs/qemu-framebuffer-text-installer-fallback.png`, a real PNG). "Coming soon" is honest; "What's left is packaging it" understates the gap (a bare-metal compositor backend is also missing — see #8). | **not-yet** (honest "coming soon") | The hard part is not packaging — it is a compositor that paints on the local framebuffer (no `/dev/dri`). gui3 proves the live boot carries no compositor at all. |
| 8 | Handbook: "designed for both server and **desktop** use" + "Desktop is now within reach" — https://solnix.io/handbook | "within reach" / "designed for" are aspirational and the handbook flags planned items. The nearest real desktop is VNC + software + single-app (see #1). Bare-metal boot-to-GUI is blocked: vgatext only, **no `/dev/dri`, no DRM/KMS** on the target hardware class (`docs/bare-metal-gui-framebuffer-gap.md`). Userland `/dev/fb` mmap works (`src/drm-port/test/fbmmap.c`, 10/10 PASS) = software pixels, no modeset/vblank, tearing, read-back 67 MB/s. | **true-but-qualified** | "within reach" is defensible as roadmap language. Daily-driver desktop needs: a framebuffer/DRM compositor backend, seat/input (libinput over illumos devfs), session services, and the Mesa EGL-wayland gap closed. |
| — | WiFi / wireless | **No claim on the public site** (grep of home/handbook/docs/roadmap/news = zero). Nothing to audit. The `iwm` double-free fix at HEAD is an internal kernel fix, not a published capability. | n/a | None (no claim). |

## Can we "test, demonstrate, and use daily"? — the honest answer per thing

| Thing the site implies | test? | demonstrate? | use daily? |
|---|---|---|---|
| Rust / Wayland / GTK4 toolkit on illumos | yes | yes (app paints over VNC) | partially (apps, not a session) |
| A COSMIC **app** (cosmic-term) | yes (re-verified, byte-identical) | yes (VNC) | no (one app, not a desktop) |
| The COSMIC **shell / desktop session** | no | no | no (panel does not composite; needs session services + Mesa EGL-wayland) |
| **GPU acceleration via RADV + Vulkan** | no | no | no (never ran; software only; amdgpu walled at PSP) |
| cosmic-comp (the real compositor) | no | no | no (does not compile on illumos) |
| Graphical install ISO booting to a compositor | no | no (gui3 shows the text installer) | no |
| Bare-metal login-to-desktop on the X1 | no | no | no (no `/dev/dri`; i915 links but is not loaded) |

## Where the Aug-18 "demo" actually ran (the brief's specific question)

- **Machine:** EC2 x86_64 (`m5.large` Nitro), AMI `ami-000a59cf344644604` (`solnix-cosmic-desktop-20260818-035909`). **Not** an AMD-GPU instance; **not** the X1; **not** real-GPU hardware. (`docs/post-stable-backlog.md` `PS-SOLNIX-AMI`.)
- **Render path:** Mesa **llvmpipe/softpipe** (software). The AMI baked `mesa-swrast-llvmpipe`; the COSMIC compositor is `smallvil` with EGL/GL dlopen'd to llvmpipe/softpipe, "**NO DRM**". (`PS-X86-COSMIC-STAGE6`.)
- **RADV / Vulkan:** absent from the demo. The RADV/Vulkan mentions in the Aug-18 records are about the **PowerVR RISC-V board** and future **compile-phase ports**, never a running COSMIC hardware demo.
- **Conclusion:** the Aug-18 result was a **software-rendered (llvmpipe) Wayland/COSMIC app session reached over VNC** — real and worth announcing, but not "hardware GPU acceleration via Mesa RADV + Vulkan". The site's wording for this event is the central overclaim.

## Artifact verification (every artifact these verdicts rely on EXISTS)

| artifact | status | note |
|---|---|---|
| `artifacts/solnix-smallvil-wlshm-paint.png` | EXISTS, git-tracked, real PNG 1280×800 RGBA | the deterministic software wl_shm paint |
| `artifacts/install-media/usb-image-20261003-gui3/boot-logs/qemu-framebuffer-text-installer-fallback.png` | EXISTS, git-tracked, real PNG 1280×800 RGB | gui3 live boot = text installer |
| `scripts/solnix-cosmic-session-node.sh` | EXISTS, git-tracked | the VNC session launcher |
| `src/drm-port/test/fbmmap.c` | EXISTS, real C | rung-0 userland `/dev/fb` mmap, 10/10 PASS |
| `src/drm-port/{radv,anv,amdgpu,i915,obsd-compat}` + `STATUS.md` | all EXIST | compile-phase ports; i915 links, not loaded |
| the Aug-18 news article's demo artifact (screenshot/boot log) | **DOES NOT EXIST** | the published "hardware GPU acceleration" claim is **unverified** — no artifact cited or found |

## The gaps, as gated tasks

Tracked in `.kiro/specs/solnix-desktop/tasks.md` (new) and summarised in `docs/roadmap.md`:

1. **D1 — bare-metal framebuffer compositor backend.** `/dev/fb` mmap works today (software, no modeset). Give smithay/smallvil a framebuffer backend writing damage to that surface → a bare-metal software desktop without DRM. Gate: smallvil paints on the local panel (not VNC) on the X1.
2. **D2 — i915 modeset on hardware.** i915 links but is **not loaded** (`docs/x1-gpu-route.md` §5.5/5.7; needs a reboot + a `visual_io` console handover). Load it → `/dev/dri/card0` → a smithay DRM backend. Gate: `/dev/dri/card0` present and a modeset on the X1 panel.
3. **D3 — Mesa iris GL on real i915 (R2).** After D2, Mesa iris (GL) and anv (Vulkan) on the i915 ioctl surface. Gate: `glxgears`/`eglgears` on iris; `vulkaninfo` lists the UHD 630.
4. **D4 — RADV only matters on an AMD GPU: name the target machine.** The X1 has none. amdgpu binds on EC2 g4ad (V520) but walls at the PSP mailbox. Pick the real RADV target (a local AMD board, per `docs/x1-gpu-route.md` §4 R4) and get past the PSP SMN-indirect wall. Gate: `vulkaninfo` lists an AMD GPU with RADV on a named machine.
5. **D5 — a graphical install ISO that boots to a compositor.** gui3 boots to the text installer because the live ISO carries no compositor. Stage smallvil + Xorg (or the D1 framebuffer path) on the live media. Gate: the live ISO renders a COSMIC app/compositor, not the text fallback.
6. **D6 — the COSMIC shell composites (not just one app).** cosmic-panel needs a D-Bus session bus + companion daemons + fractional-scale/security-context protocols (built) **and** a Mesa EGL-wayland platform (the current wall; system Mesa 21.3.9 lacks it). Gate: cosmic-panel + cosmic-term + cosmic-files composite together, steady over time.
7. **D7 — daily-driver desktop: input, seat, login.** libinput over illumos devfs (seatd ported), cosmic-greeter (Solaris-PAM enum port), multi-app session reliability. Gate: log in via cosmic-greeter and run a multi-app session end-to-end.
8. **D8 — cosmic-comp (the real compositor), optional.** Needs a `rustix` `solarish` ioctl arm (compile) + gbm/libseat/libinput/udev shims + the DRM/KMS kernel path (run). Gate: cosmic-comp builds and runs on illumos. (`docs/cosmic-comp-illumos-finding.md`.)

## Recommendation to the infra team

See `/tmp/solnix-io-graphics-claims-report.md` for exact softened wording. In short: replace
"GPU acceleration via Mesa RADV + Vulkan" and "hardware GPU acceleration through Mesa's RADV
Vulkan driver" with language that says **software rendering (Mesa llvmpipe/softpipe) over VNC
today, hardware GPU acceleration in progress**, and change "the COSMIC desktop now runs" to
"COSMIC applications run under a software compositor". We are a client of solnix.io; we do not
edit their site — this is the exact wording handed over.
