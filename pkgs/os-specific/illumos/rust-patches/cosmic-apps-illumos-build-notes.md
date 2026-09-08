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

- `smithay-illumos-si_addr-dmabuf-sealed.patch` (new, wave B2)
  Three illumos cuts to smithay (needed for the smallvil SW compositor):
  `src/wayland/shm/pool.rs` -- illumos `siginfo_t::si_addr` is an accessor
  **method** not a struct field; add an illumos arm calling `(*info).si_addr()`.
  `src/backend/allocator/dmabuf.rs` -- `rustix::ioctl::opcode` is gated off
  illumos; gate the `DMA_BUF_SYNC` const + make `sync_plane` a no-op on
  illumos/solaris (no DMA-BUF kernel interface; a SW renderer does no dmabuf
  zero-copy sync). `src/utils/sealed_file.rs` -- rand 0.10 moved `.sample()` to
  the `RngExt` trait; add `RngExt` to the `use rand::{...}` on the shm_open path.

- `reis-0.7.1-illumos.patch` (new, wave B2)
  libei's `src/util.rs` uses `net::RecvFlags::CMSG_CLOEXEC` unconditionally --
  the same illumos gap as wayland-backend's socket (rustix has no CMSG_CLOEXEC
  on solarish). Select `RecvFlags::empty()` via cfg on illumos/solaris. Pulled
  by the smithay/smallvil compositor stack (libei input).

- `winit-0.31.0-beta.2-illumos-is_main_thread.patch` (new, wave B2)
  The crates.io winit 0.31.0-beta.2 (pulled by smithay's `backend_winit`, not
  the pop-os fork) also lacks an illumos `is_main_thread` arm. Same `thr_main()`
  fix as the pop-os winit, edition-2024 `unsafe extern "C"`.

- `cosmic-session-illumos-autostart-no-systemd.patch` (new, wave B2)
  cosmic-session 1.0.0 HEAD calls `is_systemd_used()` under
  `#[cfg(feature="autostart")]` but the fn is only imported under
  `#[cfg(feature="systemd")]` -> E0425 when built `--no-default-features`
  (systemd off). Fix: gate the guard -- when systemd is off, systemd is never
  used so autostart always runs (`run_autostart = true`).

- `udev_symbols.txt` / `libinput_symbols.txt` (new, wave B2)
  The extracted symbol lists (`libudev-sys` 82 fns, `input-sys` 301
  `libinput_*` fns) that `make-udev-input-stubs.sh` reads to generate the
  link-only udev/libinput stubs. Regen with:
  `grep -rhoE 'pub fn [a-z_]+' libudev-sys-0.1.4/src/*.rs` and
  `grep -rhoE 'pub fn (libinput_[a-z0-9_]+)' input-sys-1.19.0/src/`.

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
  used). Wave B2 also needed the crates.io `winit-0.31.0-beta.2` (via smithay
  `backend_winit`), same arm, edition-2024 `unsafe extern`.

- **gettext-system**: `gettext-sys` 0.26 builds bundled gettext from source via
  autotools (fails on illumos). Point it at system libintl instead:
  `GETTEXT_DIR=/usr GETTEXT_LIB_DIR=/usr/lib GETTEXT_INCLUDE_DIR=/usr/include
  GETTEXT_BIN_DIR=/usr/gnu/bin` (illumos has `/usr/lib/libintl.so` +
  `/usr/include/libintl.h`). Needed by any app pulling `gettext-rs`
  (cosmic-session, cosmic-settings).

- **softbuffer kms default -> drm-ffi wall**: apps that pin a *different*
  libcosmic git rev than the redirect target (e.g. cosmic-applets pin 511384f)
  pull softbuffer `cosmic-4.0` (c2b2c19) with **default features incl `kms`** ->
  `drm`/`drm-ffi` (the DRM wall). Two options: (a) set the iced workspace
  softbuffer dep `default-features=false` (the documented per-checkout fix), or
  (b) drop `kms` from softbuffer's OWN `default = [...]` in the c2b2c19 checkout
  (one edit, covers every consumer). Wave B2 used (b) + redirected the applets'
  libcosmic to the working `/root/libcosmic` (1f8d878) via a real `[patch]` so
  the applet API matches the toolkit that was actually built.

- **/nix not /root for build output**: on the wave-B2 builder `/` (spool/ROOT)
  is only ~7G; the cargo home + libcosmic + app targets must live on the
  ~90G `/nix` pool. Set `CARGO_HOME=/nix/cosmic/...` + `TMPDIR=/nix/cosmic/tmp`
  and keep the app checkouts under `/nix` (symlink `/root/libcosmic` ->
  `/nix/cosmic/libcosmic` so the `[patch]` path still resolves).

## Deferred apps (blockers)

- cosmic-panel (cosmic-panel-bin): smithay `backend_drm`/`backend_egl`/
  `renderer_gl` — the live-DRM/GPU wall (drm-ffi rustix ioctl opcodes, Mesa EGL).
- cosmic-applet-a11y: two libcosmic checkouts in the graph (cosmic-settings git
  dep not redirected by the top-level [patch]) -> iced_futures version dup.
- cosmic-applet-bluetooth: `bluer` hard `compile_error!` (Linux-only BlueZ).
- cosmic-applet-battery/tiling/input-sources: `libudev-sys` (Linux udev).

## smallvil SW compositor (wave B2)

The smithay `smallvil` example compositor (smithay HEAD, features
`backend_winit,wayland_frontend,desktop`) compiles + links to x86_64-illumos
ELF and RUNS -- it initialises the winit `input_seat` + xkbcommon keyboard
handler and creates the Wayland socket. It stops at loading XKB rule data
(`/usr/share/X11/xkb` absent) -- a runtime data gate, not a link failure.
Fixes required: the three smithay illumos cuts + reis + winit-0.31.0-beta.2
is_main_thread + softbuffer kms-off + the smallvil timer-dispatch patch.
This is the SW Wayland substrate (cosmic-comp remains DRM-walled).

## Client-dispatch fix propagation across the app suite (wave B3)

Goal: propagate the proven calloop-wayland-source illumos Timer dispatch fix
(`calloop-wayland-source-illumos-timer-dispatch.patch`) across the COSMIC app
suite so a full desktop paints, not just cosmic-term.

### Shared cargo home == patch once, clean-rebuild per app

All priority apps (cosmic-panel/files/settings/launcher/bg/notifications and
cosmic-term) pin **calloop-wayland-source 0.4.1** and share
`CARGO_HOME=/nix/cosmic/cosmic-cargo-home`. The Timer patch is applied ONCE to
the single registry-src copy
(`registry/src/index.crates.io-*/calloop-wayland-source-0.4.1/src/lib.rs`);
every app then just needs its stale compiled rlib evicted and a rebuild.

**Critical gotcha (registry-src uses `.cargo-ok`, not `.cargo-checksum`):**
editing the shared src does NOT invalidate an app's already-compiled rlib +
fingerprint. Per app you MUST
`cargo clean --release --target x86_64-unknown-illumos -p calloop-wayland-source`
in that app's dir before rebuild, else the old (unpatched) rlib is relinked and
the fix silently does nothing. Same rule for the **softbuffer** POSIX-shm patch
(see below) and any other shared-checkout patch: `cargo clean -p <crate>` first.

### Rebuilt + PAINT (verified)

- **cosmic-term** (pre-existing, proven), **cosmic-files**, **cosmic-launcher**,
  **cosmic-notifications** all rebuild clean and link the patched
  calloop-wayland-source. cosmic-term + cosmic-files paint steadily together
  (see multi-app session below).

### cosmic-files softbuffer stale-rlib bite

cosmic-files' first rebuild kept a **pre-`softbuffer-illumos-posix-shm.patch`**
softbuffer rlib (only calloop was cleaned), so it panicked at
`softbuffer .../wayland/buffer.rs:52` -- `Failed to create POSIX shm ...
Os { code: 22 }` -- the exact leading-slash bug that patch fixes. Fix:
`cargo clean -p softbuffer` in cosmic-files + rebuild. After that files paints.
(cosmic-term already had a post-patch softbuffer rlib, which is why term worked
and files did not despite identical source.)

### Per-app blockers beyond dispatch (skipped)

- **cosmic-panel**: the dispatch fix applies + the panel gets past dispatch, but
  its `xdg_shell_wrapper` renders each layer-shell surface **client-side via
  `GlesRenderer`/EGL** (`.../xdg_shell_wrapper/space/egl_surface.rs`). On the
  SW-only smallvil stack a Wayland client has no EGL platform ->
  `Unable to find suitable EGL platform` and the panel exits. This is the
  live-EGL wall, same class as the deferred cosmic-comp; not a dispatch issue.
- **cosmic-settings**, **cosmic-bg**: `dav1d-sys 0.8.3` requires system
  `libdav1d >= 1.3.0` (AV1 decode) via pkg-config, absent on illumos ->
  build fails before link. Native-lib blocker, unrelated to dispatch.

### Multi-app session (terminal + file manager)

`/root/start-cosmic-session.sh` brings up Xorg:99 (dummy DRI2) -> smallvil
(winit-X11 + softpipe GLES2) -> cosmic-term + cosmic-files -> x11vnc
(127.0.0.1:5900). Hard-won runtime requirements:

- smallvil MUST run with `WAYLAND_DISPLAY` **unset** so its winit backend uses
  X11 (PLATFORM_X11_KHR) and creates a real mapped X window on :99. With
  WAYLAND_DISPLAY set it renders headless/surfaceless and the x11vnc root
  capture stays black.
- `svcadm restart application/opengl/ogl-select` before smallvil (repopulates
  the amd64 GLX/DRISWRAST link fresh AMIs miss).
- clients: `ICED_BACKEND=tiny-skia`, `GALLIUM_DRIVER=softpipe`,
  `LIBGL_ALWAYS_SOFTWARE=1`, `WAYLAND_DISPLAY=wayland-1`, `DISPLAY` unset.
- **POSIX shm exhaustion**: crashed softbuffer clients leak anonymous POSIX shm
  segments (`ipcs -m`, KEY 0x0); `project.max-shm-ids` defaults to 128 and once
  full, even correct `shm_open` returns EINVAL. The launcher reaps orphans
  (`ipcrm` the nattch=0 KEY-0x0 ids) + raises the ceiling
  (`prctl -n project.max-shm-ids -v 4096`).
- **visible multi-window**: smallvil maps every toplevel at (0,0); apply
  `smallvil-illumos-cascade-toplevels.patch` + rebuild -p smallvil so the
  second window is offset and both are visible. (This stock smallvil rebuild
  lacks the layer-shell of the waveB2 binary -- fine for xdg-shell app windows.)

Verified STEADY over VNC (raw-RFB capture, pure-stdlib, localhost only): two
captures 30s+ apart with identical md5 showing cosmic-term + cosmic-files (file
manager with a live home-dir listing) cascaded and painted.

## cosmic-panel BAR rendering (the full shell)
- The panel BAR now renders (steady VNC: panel bar with live cosmic-applet-time
  clock + app windows below). See `docs/cosmic-panel-bar-renders.md` and
  `artifacts/cosmic-full-shell.png`.
- smallvil layer-shell handling is the combined
  `smallvil-illumos-session-shell-protocols.patch` (now also subsumes the former
  timer-dispatch + cascade-toplevels patches): TOP-layer surfaces render above
  toplevels, `arrange()`+configure honor the exclusive zone, the
  wp_security_context listener is ACCEPTED (privileged applet socket), and new
  toplevels map into the non-exclusive zone (below the bar).
- cosmic-panel needs `cosmic-panel-illumos-embedded-server-timer-dispatch.patch`
  (drive the embedded applet server off a 4ms Timer, not a level Generic FD, on
  illumos).
- **MUST rebuild any winit-wayland applet (e.g. cosmic-applet-time) against the
  PATCHED wayland-client** (`wayland-client-<ver>-illumos-blocking-read-timeout`
  for 0.31.11/0.31.14/0.31.15). A stale applet built before the patch wedges in
  `poll(INFINITE)` at winit `registry_queue_init` -> never renders -> panel gets
  no thickness -> stays 8px (below its 20px render gate) -> never paints its bar.
  `cargo clean -p wayland-client && cargo build -p cosmic-applet-time`.
