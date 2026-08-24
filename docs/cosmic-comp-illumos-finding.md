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
