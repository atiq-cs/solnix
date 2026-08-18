# COSMIC app-suite illumos build notes (x86_64-unknown-illumos, native)

These patches + notes cover the per-app illumos breaks hit while building the
COSMIC desktop app suite (cosmic-session/launcher/term/files/applets) against
the already-built libcosmic 1.0.0 toolkit. Toolkit-level patches
(wayland-backend epoll/CMSG_CLOEXEC, winit is_main_thread, smithay si_addr,
reis, iced-softbuffer-nokms) are documented in ../../../docs/cosmic-rust-stack.md
and are baked into the shared cargo home.

## Patches in this dir (app wave)

- `libcosmic-widget-text_editor-class-and-fn-export.patch`
  Additive libcosmic API the newer cosmic-files/cosmic-term HEAD expect but the
  1.0.0 toolkit rev (1f8d878) lacks: a `widget::text_editor` fn re-export at
  widget scope, and a `TextEditor::class()` builder that delegates to the
  underlying iced 0.14 widget's `.class()`. Apply to the libcosmic checkout.

- `cosmic-applets-illumos-memfd-shm-fallback.patch`
  `rustix::fs::memfd_create` / `MemfdFlags` are Linux/FreeBSD-only in rustix
  1.1.4. cosmic-app-list and cosmic-applet-minimize use them for screencopy
  thumbnail capture. This adds an illumos/solaris arm that makes an anonymous fd
  via POSIX shm (`rustix::shm::open` CREATE|EXCL|RDWR + immediate `shm::unlink`).

## Non-patch build knobs

- **cosmic-session**: `cargo build --no-default-features` — the default `logind`
  feature drags in `zbus_systemd` + `tracing-journald` (systemd/journald,
  Linux-only). Without it, only zbus/dbus + tokio + rustix are needed.

- **cosmic-files**: `--no-default-features --features
  wayland,desktop,dbus-config,notify` — drops `io-uring` (Linux io_uring via
  compio), `gvfs` (Linux). trash/walkdir/mime_guess/xdg-mime build native.

- **wayland-backend version skew**: apps pin 0.3.15 / 0.3.16 / 0.3.17; only
  0.3.17 shipped patched. The 3 patched files differ across versions ONLY by the
  illumos cfg additions, so transplant the 0.3.17 copies of
  `src/rs/server_impl/common_poll.rs`, `.../handle.rs`, `src/rs/socket.rs` onto
  the 0.3.15/0.3.16 checkouts in the cargo home.

- **winit is_main_thread** (../../../docs/cosmic-rust-stack.md): apply the
  illumos `thr_main()` arm to EVERY pop-os winit checkout rev an app pins
  (cosmic-launcher pins rev f737f1f, distinct from the 71ce08c rev the toolkit
  used).

## Deferred apps (blockers)

- cosmic-panel (cosmic-panel-bin): smithay `backend_drm`/`backend_egl`/
  `renderer_gl` — the live-DRM/GPU wall (drm-ffi rustix ioctl opcodes, Mesa EGL).
- cosmic-applet-a11y: two libcosmic checkouts in the graph (cosmic-settings git
  dep not redirected by the top-level [patch]) -> iced_futures version dup.
- cosmic-applet-bluetooth: `bluer` hard `compile_error!` (Linux-only BlueZ).
- cosmic-applet-battery/tiling/input-sources: `libudev-sys` (Linux udev).
