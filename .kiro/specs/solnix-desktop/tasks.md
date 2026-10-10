# solnix desktop & graphics — gated bring-up tasks

Source of truth for the graphics/desktop gaps found by `docs/graphics-claims-audit.md`
(2026-10-10): the site claims a hardware-accelerated RADV/Vulkan COSMIC desktop; reality is a
single COSMIC app painting under a software compositor (Mesa softpipe/llvmpipe) over VNC. These
tasks turn each gap into a gated item. No phase starts before the previous gate is green.

Evidence base (verify before trusting): `docs/desktop-connectable-status.md`,
`docs/cosmic-comp-illumos-finding.md`, `docs/bare-metal-gui-framebuffer-gap.md`,
`docs/x1-gpu-route.md`, `src/drm-port/STATUS.md`, and the Aug-18 build records in
`docs/post-stable-backlog.md`.

Current reality (REAL / STUB / not-loaded tags):
- Software compositor **smallvil** (smithay winit→X11, Mesa softpipe/llvmpipe) — **REAL**, runs, single COSMIC app paints over VNC.
- cosmic-comp (the real compositor) — **does not compile** on illumos (`rustix::ioctl::opcode` absent for `solarish`).
- i915 kernel module — **links, NOT loaded** (reboot + console handover needed).
- RADV / anv / iris — **compile-phase ports**, never run; no `/dev/dri`.
- amdgpu — **binds on EC2 g4ad (V520), walls at the PSP mailbox**; the X1 has no AMD GPU.
- Bare metal — **vgatext only, no `/dev/dri`, no DRM/KMS**; userland `/dev/fb` mmap works (software, no modeset).

---

## D1 — Bare-metal framebuffer compositor backend (software desktop, no DRM)

`src/drm-port/test/fbmmap.c` proves a process can mmap the GOP linear framebuffer and paint
(10/10 PASS, negative control fails). Give smithay/smallvil a framebuffer backend that renders
into a RAM buffer and copies only damaged regions to that mapping (never read back — 67 MB/s
read, ~0.5 s per 4K frame).
- **Gate:** smallvil paints a COSMIC app on the **local panel** of the X1 (not VNC), software-rendered, accepting tearing (fixed mode, no vblank).
- Depends on: nothing new (the mmap path exists). This is the smallest bare-metal-GUI step.

## D2 — i915 modeset on real hardware → `/dev/dri/card0`

The i915 module links against the running kernel (`docs/x1-gpu-route.md` §5.5/5.7) but is **not
loaded**. Loading it needs a reboot and a `visual_io` polled-I/O console (illumos has no console
handover; vgatext cannot detach from the console node). Then wire a smithay **DRM** backend.
- **Gate:** `/dev/dri/card0` present on the X1; a modeset lights the panel; a smithay DRM backend composites on it.
- Depends on: the dump device + the console-handover plan in `src/drm-port/i915/ATTACH-PLAN.md`.

## D3 — Mesa iris (GL) + anv (Vulkan) on real i915 (route R2)

With `/dev/dri` from D2, build Mesa **iris** (GL 4.6) and **anv** (Vulkan) on the i915 ioctl
surface (`src/drm-port/anv` is a compile-phase port today).
- **Gate:** `glxgears`/`eglgears` run on iris; `vulkaninfo` lists "Intel(R) UHD Graphics 630 (CFL GT2)"; `vkcube` runs.
- Depends on: D2.

## D4 — RADV on a named AMD machine (the only place RADV matters)

RADV is AMD-only. The X1 has no AMD GPU. amdgpu binds on EC2 g4ad (V520, Navi 12) but **walls at
the PSP mailbox** because MP0 SMN registers are not reachable through a direct BAR
(`src/drm-port/STATUS.md` C3-amdgpu-d). Name the real target (a local AMD board avoids the EC2
virtualisation question), implement the SMN indirect register window, run the ring tests, then
RADV on top.
- **Gate:** `vulkaninfo` lists the AMD GPU with the RADV ICD, and `vkcube` runs, on a **named** machine (not "a GPU in general").
- Depends on: the PSP SMN-indirect path (the current wall).

## D5 — A graphical install ISO that boots to a compositor

`usb-image-20261003-gui3` boots to the **text** installer because the live ramdisk stages no
smallvil and no Xorg (`docs/desktop-connectable-status.md`; screenshot
`artifacts/install-media/usb-image-20261003-gui3/boot-logs/qemu-framebuffer-text-installer-fallback.png`).
Stage the compositor on the live media (smallvil + Xorg, or the D1 framebuffer path once it lands).
- **Gate:** the live ISO renders a COSMIC app / compositor on first boot, not the text fallback. Negative control: the current gui3 image still falls back (proves the guard works).
- Depends on: D1 or the VNC path on the live media.

## D6 — The COSMIC shell composites (panel + apps together)

cosmic-panel's session-service + wayland-protocol layer is built (D-Bus session bus,
zwlr_layer_shell_v1, fractional-scale, security-context, viewporter — see
`docs/desktop-connectable-status.md`). The remaining wall is a **Mesa EGL-wayland platform**:
system Mesa 21.3.9 has `platform_x11`/`gbm`/`surfaceless` but **not wayland**, so the panel's GL
nested compositor exits with "Unable to find suitable EGL platform". Either build illumos Mesa
with the wayland EGL platform, or rework the panel wrapper to a surfaceless/pbuffer GL + wl_shm
software upload.
- **Gate:** cosmic-panel + cosmic-term + cosmic-files composite together, byte-stable over ≥60 s (judge by rate over ≥8 captures; report any clustering).
- Depends on: the Mesa EGL-wayland packaging task.

## D7 — Daily-driver desktop: input, seat, login

- **Input:** libinput over illumos devfs (an evdev/udev shim; `input-sys` bindgens libinput, which illumos lacks). Keyboard today arrives via X11; a real session needs libinput.
- **Seat:** seatd/libseat on illumos (a shim is tracked; `libseat-sys` has no illumos library).
- **Login:** cosmic-greeter needs a **Solaris-PAM** enum port (`pam-client-0.5.0` hardcodes Linux-PAM's ReturnCode; `docs/cosmic-comp-illumos-finding.md`).
- **Gate:** log in via cosmic-greeter and run a multi-app COSMIC session with working keyboard/pointer input, end-to-end, on a named machine.
- Depends on: D6.

## D8 — cosmic-comp (the real compositor), optional/parity

For source-identical pop!_OS parity (not required for a usable desktop). Compile wall: a
`rustix` `solarish` ioctl arm (`rustix::ioctl::opcode` + the ioctl platform backend — a bounded
patch, the opcode math is portable `_IOC`-style). Run wall: gbm/libseat/libinput/udev shims +
the DRM/KMS kernel path exposing `/dev/dri` + a GBM.
- **Gate:** cosmic-comp builds, then runs, on illumos driving a real `/dev/dri`.
- Depends on: D2 (DRM/KMS) + D7 (seat/input) + the rustix patch.

---

## Method / honesty rule

Tag every result REAL / STUB / not-loaded. A compile-phase port is **not** a runtime capability.
Software rendering (llvmpipe/softpipe) is **not** GPU acceleration. VNC is **not** login-to-desktop.
State the machine every GPU result ran on (the Aug-18 overclaim came from eliding "on which GPU").
Keep `docs/graphics-claims-audit.md` and the published roadmap in sync (`scripts/roadmap-sync-check.sh`).
