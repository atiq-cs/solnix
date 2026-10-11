# x86_64-solaris COSMIC stack — Stage 6 (native): the COSMIC Rust stack + a SW-render Wayland compositor

Native x86_64-illumos (no cross). Stage 6 lands the Rust headline the earlier
stages deferred: the **native x86_64-unknown-illumos rustc/cargo 1.97.1 seed
realised from the cache**, the **entire COSMIC/wayland Rust crate stack compiled
native to x86_64-illumos rlibs** (incl. libcosmic, iced, cosmic-text, cosmic-
config/theme, smithay, winit, the wayland core), and a **software-render Wayland
compositor** (smithay `smallvil`, winit backend) built to a running AMD64 ELF —
the viewable-desktop deliverable. cosmic-comp itself is confirmed (again, as on
aarch64) hard-coupled to DRM/GBM at COMPILE time even on the winit path; the
smithay SW compositor is the fallback that makes the desktop viewable.

Paths file: `/root/x86-cosmic-stage6-paths.txt`.
Patch notes: `/root/cosmic-illumos-patches.txt` (+ `/root/patch-wayland-backend.sh`).

## TASK 1 — native x86 rust: YES

- Realised the published seed from the cache (no build):
  `nix-store --realise /nix/store/8daydacsqmkzi72zfa3dmi9pp98d6hmj-rust-illumos-1.97.1`
  (+ rustc/cargo/syslibs/raw-tree). All from `cache.solnix.io`, key in nix.conf.
- `rustc --version` -> rustc 1.97.1 (8bab26f4f); `cargo --version` -> 1.97.1.
  `rustc -vV` host = **x86_64-unknown-illumos**, std present (Tier-2 native).
- `cargo new ct && cargo build` -> `Hello, world!`, `file` = ELF 64-bit AMD64.
  NATIVE: build == host == target = x86_64-unknown-illumos, the seed's own std
  used directly (no build-std cross the aarch64 side needed).

## TASK 2 — the COSMIC/wayland Rust crates: BUILT (389 rlibs)

Built native to x86_64-illumos rlibs (`cargo build --target x86_64-unknown-illumos`),
crates vendored/fetched on-host (sandbox off, crates.io + pop-os git reachable),
the illumos patches applied to the vendored/registry/git checkouts:

  - **wayland-backend 0.3.17, wayland-client 0.31, wayland-server 0.31, calloop**
    — with the epoll + CMSG_CLOEXEC patch (4 epoll cfg gates + the handle.rs
    `ret` gate + the socket.rs CMSG_CLOEXEC->DONTWAIT+fcntl fallback).
  - **cosmic-text 0.12.1 and 0.19.0, iced_core 0.13.2** — no patch needed.
  - **smithay 0.7.0** (wayland_frontend + desktop + renderer_pixman, NO DRM) —
    3 illumos cuts (si_addr(), dmabuf DMA_BUF_SYNC gate, — sealed_file rand API on
    the git HEAD). SW (pixman) renderer path.
  - **libcosmic 1.0.0** (the full toolkit, default features: winit + wayland +
    tokio + a11y + x11 + multi-window) + **cosmic-config 1.0.0** +
    **cosmic-theme** + **iced 0.14 / iced_widget / iced_tiny_skia** + **winit**
    (pop-os cosmic-0.14) + **cosmic-text 0.19** + wgpu/wgpu-hal + resvg — 389
    rlibs. Needed: the winit is_main_thread illumos arm (libc thr_main), the reis
    CMSG_CLOEXEC cut, and softbuffer default-features=false (drop kms/drm so
    drm-ffi leaves the graph — the iced-softbuffer fix).

This is the full COSMIC Rust stack native on x86 — larger than the aarch64
48-rlib proof (that was cosmic-comp's dep set; here the whole libcosmic toolkit
+ smithay + a compositor build).

## TASK 3 — a SW-render Wayland compositor: BUILT (fallback), cosmic-comp DRM-walled

**smithay `smallvil`** (backend_winit + wayland_frontend + desktop) built to
`smallvil` — ELF 64-bit AMD64, runs. NEEDED: only base illumos libs +
libxkbcommon (libEGL/libGL are dlopen'd at RUNTIME by the winit backend, so no
GPU link-time dep; they resolve from the stage-5 mesa-softpipe/libglvnd for a
llvmpipe/softpipe SW GL). This is a Wayland compositor that renders in software:
winit opens a Wayland/X11 window (under the stage-5 desktop, or headless via
VNC), a GTK4/libadwaita client runs under it.

**cosmic-comp — hard-coupled to DRM/GBM at COMPILE time (confirmed).** Its
`src/backend/render/mod.rs` + `render/element.rs` import
`kms::render::gles::GbmGlowBackend` UNCONDITIONALLY (no cfg), and the smithay dep
hard-lists `backend_drm/gbm/udev/egl/libinput/session_libseat/vulkan`. The render
element type IS a GBM (DRM allocator) + GLES type across the shell/render
pipeline; the `winit`/`x11` backends compile alongside `kms` in one binary. So
cosmic-comp cannot compile on illumos without a GBM/DRM smithay (drm-ffi's
rustix::ioctl opcodes are not exposed on illumos, gbm/udev/libinput have no
illumos backend). Making it SW-only is a render-pipeline retype (kms/ is multi-
file, GbmGlowBackend is woven through render + shell), > a bounded budget — same
verdict the aarch64 stage reached. The smithay SW compositor is the fallback.

## New x86_64-illumos artifacts this stage (published, failed=0)

| artifact | store path | kind |
|---|---|---|
| cosmic-toolkit rlibs (391) | 591rk79s4adj5bx7lfpfg906ja1s8y7s-cosmic-toolkit-x86_64-illumos-rlibs | 389 rlibs + smithay rlib + smallvil (459 MB) |
| smallvil compositor | 7qvqfz2wc82qi4v1k1hvvhrkwcs627gz-smallvil-x86_64-illumos | AMD64 ELF (SW-render Wayland compositor) |
| libcosmic rlib | rvzgiglmlsvxi6qnsgh6fwnxz8n0243p-libcosmic-x86_64-illumos.rlib | the toolkit rlib |
| smithay rlib | 6k3x5v6ac3nd1r5z5xi918zfga9y1acp-smithay-x86_64-illumos.rlib | wayland+pixman (no DRM) rlib |
| rust seed (from cache) | 8daydacsqmkzi72zfa3dmi9pp98d6hmj-rust-illumos-1.97.1 | native rustc/cargo (durable) |

Published via `oi-publish-wave.sh /root/x86-cosmic-stage6-paths.txt`:
published=4 skipped=7 (seed paths already durable) failed=0.

## Is a nix-pure SW-render Wayland desktop reachable?

YES, in software: the SW-render Wayland compositor (smithay smallvil, winit
backend) renders via llvmpipe/softpipe (stage-5 mesa-softpipe) into a
Wayland/X11 window; GTK4 4.22.4 + libadwaita 1.9.2 (stage 4/5, native) are the
client toolkit. Viewable via wayvnc/Xvnc. What renders: a smithay compositor
window + any wayland/GTK4 client under it.

## Remaining step to the nix-pure COSMIC ISO

1. Wrap the rust seed + the COSMIC crates as nix derivations in the overlay
   (the wave-1 `rust-overlay.nix` already wires rustPlatform; add a
   buildRustPackage-style recipe per COSMIC crate consuming the on-host vendor
   dir + the illumos patches). Today the rlibs are cargo outputs bundled into
   one store path; the ISO wants per-crate nix drvs.
2. Either (a) land the SW compositor (smallvil, or a trimmed cosmic-comp) as the
   session compositor + wayvnc, or (b) port cosmic-comp's render pipeline off
   GbmGlowBackend to a pixman/SW renderer (the large item) for the real COSMIC
   shell. For a first viewable ISO, (a) + GTK4/libadwaita apps is enough.
3. Compose the ISO (the stage-5 desktop closure + the compositor + wayvnc).

## Honest gaps
- cosmic-comp SW backend: NOT built (DRM/GBM compile coupling). smallvil is the
  SW compositor fallback that IS built and runs.
- Firefox/Chrome: unchanged, no illumos target (roadmap only).
