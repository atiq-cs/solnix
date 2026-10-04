# cosmic-comp on illumos: the compositor-substrate decision

## Question
pop!_OS COSMIC uses `cosmic-comp` (smithay-based) as its Wayland compositor.
Can we run the real cosmic-comp on illumos for a functionally-identical desktop?

## Finding (measured on x86_64-illumos)
The DRM **dependency graph** is fully cracked: with smithay's winit+glow+pixman
feature floor, `drm-ffi` / `gbm` / `ash` / `libseat` / `libudev` / `input` /
`libdisplay-info` all drop out or are stubbed (proven — the crate graph builds
DRM-free). BUT the cosmic-comp **source** is structurally KMS/DRM/x11/libinput-
woven: `cargo check` shows 44 errors across 14 core files —
`state.rs` (`BackendData::Kms`, `render::GlMulti` multi-GPU), `backend/x11.rs`,
`libei.rs`, the input/output-config, the DRM handler files. Excising KMS means
re-architecting the compositor's renderer + input + output core — a compositor
rewrite, not a port. Not convergent in a bounded effort.

## The EXACT root mechanism (measured 2026-10-04, pop-os/cosmic-comp @ 3d55cba)

The "44 errors" above are the *downstream* symptom in cosmic-comp's own source.
Traced to the bottom, the whole DRM/GBM wall rests on ONE Rust compile failure in
a transitive FFI crate — named here so a future port knows precisely what to fix
and so nobody re-derives it from scratch.

### cosmic-comp's declared coupling (Cargo.toml, verbatim)
Its `[dependencies.smithay]` turns ON the Linux-hardware backends by feature:
`backend_drm`, `backend_gbm`, `backend_egl`, `backend_libinput`,
`backend_session_libseat`, `backend_udev`, `backend_vulkan` (smithay rev
`e3d461a`). The source then uses those backends 212× across `src/` — the top
symbols by count: `DrmNode` (145), `DrmDeviceFd` (36), `GbmAllocator` (20),
`EGLContext`/`EGLDevice` (26), `GpuManager`/`MultiRenderer` (29),
`LibSeatSession` (8), `UdevBackend`/`UdevEvent` (10), `connector::`/`crtc::` (49).
`src/state.rs` hard-codes a `BackendData::Kms(KmsState)` enum variant, so even
the non-KMS code paths monomorphize against the KMS types.

### The ground-truth FFI chain (each crate inspected in the cargo registry)
`backend_drm`/`backend_gbm` pull this chain, and the break is at the bottom:

1. **`drm-ffi` 0.9.1** — `src/ioctl.rs:4` opens with
   `use rustix::ioctl::{ioctl, opcode, Getter, NoArg, Opcode, Setter, Updater};`
   and builds every DRM request number with `opcode::read_write!(…, DRM_IOCTL_BASE, …)`
   (e.g. `ioctl_readwrite!(get_cap, DRM_IOCTL_BASE, 0x0c, drm_get_cap)`).
2. **`rustix` 1.1.4** — `src/ioctl/mod.rs:201` declares the opcode builder
   `#[cfg(any(linux_kernel, bsd, target_os = "redox"))] pub mod opcode { … }`,
   and the ioctl *backend* itself (`mod linux` / `mod bsd` → `use … as platform`)
   at `src/ioctl/mod.rs:28-37` is likewise `cfg(any(linux_kernel, redox))` /
   `cfg(bsd)`.
3. **`rustix` cfg aliases** — `build.rs:157-170` define them from `target_os`:
   `os=="solaris"||os=="illumos"` ⇒ **`solarish`**; `bsd` ⇒ apple/freebsd/netbsd
   only; `linux_kernel` ⇒ android/linux only. **`solarish` is in NONE of
   `linux_kernel`, `bsd`, `redox`.**

**Therefore on x86_64-illumos the `rustix::ioctl::opcode` module and the ioctl
platform backend simply do not exist**, so `drm-ffi/src/ioctl.rs:4` is an
unresolved import (E0432) and `drm-ffi` cannot compile. Nothing above it
(`drm` → `smithay::backend::drm` → `backend_gbm`/`backend_egl` → cosmic-comp's
`KmsState`) can build. This is the single root symbol: **`rustix::ioctl::opcode`,
absent for `solarish`.**

Note `drm-sys` 0.8.1 is NOT the wall: it ships a prebuilt `src/bindings.rs`
(default features, no `use_bindgen`) that is a pure-Rust translation of the Linux
DRM UAPI structs, and its `platform` module already has a non-Linux arm
(`src/lib.rs:14-20`, `libc::O_RDWR`/`c_ulong`). The *struct* layer ports for free;
only the *ioctl dispatch* layer (`drm-ffi` via `rustix`) is Linux/BSD-gated.

### The sibling FFI walls (header/library, distinct from the rustix one)
These are `*-sys` crates that bindgen a C header and link a Linux-only library at
build time — each needs the header + library to exist on illumos, which it does
not:
* **`gbm-sys` 0.4.0** — bindgens `<gbm.h>` (`allowlist gbm_*/GBM_*`); needs Mesa's
  libgbm, which only exists atop `/dev/dri`.
* **`libseat-sys` 0.2.0** — `pkg_config::probe_library("libseat").unwrap()`; no
  seatd/libseat on illumos (the `seatd` shim is tracked separately).
* **`input-sys` 1.19.0** — bindgens `libinput.N.N.N.h` + links libinput; no illumos
  libinput (needs an evdev/udev shim).
* **`libudev-sys` 0.1.4** — `links = "libudev"`; no illumos libudev.

### What "port cosmic-comp" therefore means, concretely
The minimum to get `backend_drm` to *compile* (not run) is an illumos `solarish`
arm for `rustix::ioctl::opcode` + the ioctl `platform` backend (a small, bounded
rustix patch: the opcode math is `_IOC`-style and portable; illumos `ioctl(2)`
takes the same `(fd, request, arg)` shape). To *run* it still needs the four
sibling libraries (gbm/libseat/libinput/udev) AND the illumos DRM/KMS kernel path
(`src/drm-port`) exposing `/dev/dri` + a GBM. So the compile wall is one rustix
arm; the run wall is the entire G1/G2 DRM/KMS/Mesa stack. **smallvil (SW,
no DRM) remains the substrate** precisely because it never touches this chain —
it is winit→X11, which pulls none of `drm-ffi`/`gbm-sys`/`libseat-sys`.

> Reproduce: `git clone --depth1 https://github.com/pop-os/cosmic-comp` (3d55cba);
> `cargo fetch` the `drm-ffi 0.9.1`/`rustix 1.1.4` sources; the cfg gates above are
> at the cited line numbers. No illumos node needed — the gate is a compile-time
> `cfg` decision, readable in the crate sources on any host.

## Decision: smallvil is the illumos COSMIC compositor substrate
For a *functionally-identical* (not source-identical) pop!_OS COSMIC desktop on
illumos, the compositor is **smallvil** (a smithay SW compositor, already built,
renders + speaks wlr-layer-shell). It gives the COSMIC session what it needs:
- COSMIC apps connect + render (proven: cosmic-term paints, cosmic-panel is a
  layer-shell client, prior waves).
- The full COSMIC toolkit (libcosmic/GTK4/libadwaita) + app suite run on top.
This is the same functional experience — same toolkit, same apps, same panel +
session — with a SW-rendered smithay compositor instead of cosmic-comp's native
DRM/KMS path. When solnix's C1 DRM framework exposes a `/dev/dri` that smithay's
drm-ffi can drive (a GBM + rustix-ioctl shim, tracked separately), the native
cosmic-comp path can be revisited; until then smallvil is the substrate.

## The other Linux-hardware boundaries (deferred, exact blockers)
- **cosmic-greeter**: Solaris-PAM vs Linux-PAM ABI (pam-client-0.5.0 hardcodes
  Linux-PAM's ReturnCode enum). Needs a pam-client Solaris-PAM enum port; the
  GUI/session/greetd_ipc/upower halves all build. (The login manager is the one
  pop!_OS-parity gap worth closing next — a bounded enum port.)
- **cosmic-workspaces-epoch / xdg-desktop-portal-cosmic / cosmic-applet-battery**:
  live GPU/DRM buffer layer (gbm/drm-ffi) or PipeWire (no illumos PipeWire).
- **cosmic-applet-bluetooth**: `bluer` is Linux-only (no illumos BlueZ).
