# Bare-metal GUI on solnix: a bounded porting gap, not a hardware wall (measured 2026-09-19)

## The question

The maintainer's goal includes a NixOS-graphical-style installer image that boots into a GUI desktop on real
hardware. Is that physically possible on solnix's target hardware today, and if not, what exactly stands in the way?

## Verdict: (b) — a bounded TWO-PART PORTING gap. The pixels are physically addressable; nothing drives them.

Measured at the device level on an illumos node (EC2 `i-0b449949ab8c52b62`, display@3 = Amazon vendor 0x1d0f,
class 0x030000 VGA), representative of the vgatext-only class the X1 also falls in:

* **A prefetchable LINEAR FRAMEBUFFER BAR exists**: in `display@3`'s assigned-addresses, base `0xc0000000`, size
  `0x00400000` (4 MB) — enough for 800×600×32 — alongside the legacy VGA I/O (`0x3b0`/`0x3c0`/`0xa0000`).
* The kernel props `screen-width=800`/`screen-height=600` come from the **loader's EFI-GOP query**;
  `screen-#cols=98`/`#rows=36`/`screen-font=8x16` show the kernel is driving that aperture in **vgatext TEXT mode**.
* Bound driver = **`vgatext` ONLY**. This illumos kernel tree ships **NO linear-framebuffer console driver**
  (no `gfxp_fb`/`efifb`-equivalent), **NO `/dev/dri`**, **NO DRM/KMS**.

So: the pixels ARE physically addressable (the 4 MB linear BAR is real), but (1) nothing in illumos exposes that
aperture to userland as a pixel surface, and (2) the compositor (smallvil = smithay winit→X11, rendering to
Xorg:99/Xvfb→VNC) has no fbdev/DRM backend to target it even if it were exposed.

## What that means

Bare-metal boot-to-GUI is **not a missing-hardware impossibility (a)** — it is a **bounded porting task (b)** with
two named pieces:

1. **An illumos framebuffer path**: a driver (or a userland `mmap`) that maps the linear FB BAR at `0xc0000000` and
   exposes it as a writable pixel surface. This is the illumos side — a small framebuffer console/device driver, or
   a userland aperture map. (The larger, general answer is the illumos DRM/KMS port in `src/drm-port`, but a simple
   linear-FB device is a much smaller first step that this hardware's GOP aperture already supports.)
2. **A compositor backend that targets it**: smithay has an experimental fbdev/DRM-less path; wlroots historically
   had an fbdev backend. smallvil/COSMIC needs a backend writing to that surface instead of X11→VNC.

Neither is a research unknown; both are bounded engineering. Until they land, the honest state is **VNC-only**: the
COSMIC installer runs via Xorg:99→x11vnc, reached over an SSH tunnel — useful for remote/headless install, not a
local bare-metal desktop.

## Consequence for the installer images

* On vgatext-only hardware (the X1, this EC2 class), the **TUI installer is the correct LOCAL installer today.**
* The **GUI installer image is VNC-only today** — real and useful (remote install, and the future-facing desktop),
  but it does NOT paint on the local framebuffer until piece (1)+(2) land.
* The bare-metal-GUI goal is therefore gated on this two-part port, tracked here and in `src/drm-port`. It is the
  next frontier for the desktop goal, distinct from anything the installer plumbing can fix.

## Why this is good news

"Boot into a GUI desktop" looked like it might need full GPU/DRM support (months). The measurement shows the
minimum viable path is far smaller: the GOP-provided 4 MB linear aperture already exists on this hardware, so a
linear-FB device + an fbdev compositor backend gets a (software-rendered, llvmpipe) bare-metal COSMIC desktop
without the full DRM/KMS stack. Full GPU acceleration still wants DRM; a *usable* bare-metal desktop does not.
