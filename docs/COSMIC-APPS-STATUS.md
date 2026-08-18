# COSMIC desktop apps — x86_64-illumos native build (Wave 1)

Native `x86_64-unknown-illumos` (no cross). Toolkit reused: the already-built
`/root/libcosmic` (pop-os git, rev 1f8d878, 1.0.0) + `/root/cosmic-cargo-home`
(the shared registry/git cache with the illumos patches baked in). Rust seed:
`/nix/store/cvs3wrjnadd8prryvhy37pyzzc8dy1cd-rust-illumos-1.97.1` (rustc/cargo
1.97.1, native x86_64-illumos, realised from cache). Linker: OpenIndiana gcc
14.3.0 (no lld needed; the config.toml lld flag is not required on this host).

## Foundation verified

- **rust seed**: YES — `rustc 1.97.1`, host = x86_64-unknown-illumos, native
  std. Trivial `cargo build --target x86_64-unknown-illumos` -> ELF AMD64.
- **libcosmic + iced**: YES — the whole `libcosmic` + `iced` + `winit` +
  `softbuffer` + `cosmic-text` + `cosmic-config`/`cosmic-theme` stack recompiles
  natively against `/root/libcosmic` (proven by every GUI app below).

## Build recipe (per app)

```sh
RUST=/nix/store/cvs3wrjnadd8prryvhy37pyzzc8dy1cd-rust-illumos-1.97.1
export PATH=$RUST/bin:$PATH
export CARGO_HOME=/root/cosmic-cargo-home
cd /root/cosmic-apps/<app>
cargo build --release --target x86_64-unknown-illumos [features]
```

Each app that depends on libcosmic gets this appended to its `Cargo.toml` so the
built toolkit + its illumos patches are reused instead of a fresh git clone:

```toml
[patch."https://github.com/pop-os/libcosmic"]
libcosmic     = { path = "/root/libcosmic" }
cosmic-config = { path = "/root/libcosmic/cosmic-config" }
cosmic-theme  = { path = "/root/libcosmic/cosmic-theme" }
```

## Apps COMPILED to x86_64-illumos ELF (14)

All `readelf -h` Machine = `Advanced Micro Devices X86-64`, Type = EXEC. Runtime
is gated on a running Wayland compositor + display (they link + `--help`/`--version`
run; GUI apps panic at the winit event-loop with "no WAYLAND_DISPLAY/DISPLAY",
which is the expected runtime gate, not a link failure).

| app | binary | runs |
|---|---|---|
| **cosmic-session** | cosmic-session/target/x86_64-unknown-illumos/release/cosmic-session | `--help` OK (I/O error = missing session files, runtime-gated) |
| **cosmic-launcher** | cosmic-launcher/.../release/cosmic-launcher | `--help` OK |
| **cosmic-term** | cosmic-term/.../release/cosmic-term | `--help` OK (prints "COSMIC Terminal") |
| **cosmic-files** | cosmic-files/.../release/cosmic-files | starts, panics at winit (no display) |
| cosmic-applet-time | cosmic-applets/.../release/cosmic-applet-time | GUI, runtime-gated |
| cosmic-applet-power | .../cosmic-applet-power | GUI, runtime-gated |
| cosmic-applet-audio | .../cosmic-applet-audio | GUI, runtime-gated |
| cosmic-applet-network | .../cosmic-applet-network | GUI, runtime-gated |
| cosmic-applet-notifications | .../cosmic-applet-notifications | GUI, runtime-gated |
| cosmic-applet-status-area | .../cosmic-applet-status-area | GUI, runtime-gated |
| cosmic-applet-workspaces | .../cosmic-applet-workspaces | GUI, runtime-gated |
| cosmic-applet-minimize | .../cosmic-applet-minimize | GUI, runtime-gated |
| cosmic-app-list | .../cosmic-app-list | GUI, runtime-gated |
| cosmic-panel-button | .../cosmic-panel-button | GUI, runtime-gated |

Staged bundle (all 14): `/nix/store/5m4c9x9wk9a42wbgsn33hi2mn5n620lq-wave-bin`
Paths file: `/root/cosmic-apps-wave1-paths.txt`

## Per-app illumos fixes applied

1. **cosmic-session**: build `--no-default-features` (the default `logind`
   feature pulls `zbus_systemd` + `tracing-journald` = systemd/journald,
   Linux-only; illumos has no systemd/logind/journald). Everything else
   (zbus/dbus, tokio, rustix) builds native. No source edits.

2. **wayland-backend (all versions)**: apps pin different minor versions
   (0.3.15 / 0.3.16 / 0.3.17); only 0.3.17 was previously patched. The 3
   affected files (`server_impl/common_poll.rs`, `server_impl/handle.rs`,
   `socket.rs`) differ between versions ONLY by the illumos `cfg` additions, so
   the patched 0.3.17 copies were transplanted onto 0.3.15/0.3.16 in the shared
   cargo home. (epoll cfg gates + the `epoll::add` register-client gate +
   the `CMSG_CLOEXEC` -> `DONTWAIT` + manual `FD_CLOEXEC` fallback.)

3. **winit (pop-os cosmic-0.14, checkout f737f1f)**: `is_main_thread()` had no
   illumos arm (E0425). Added `#[cfg(any(illumos, solaris))] fn is_main_thread`
   via libc `thr_main()`. (The earlier-patched checkout 71ce08c already had it;
   cosmic-launcher pins the f737f1f rev, so the same arm was added there.)

4. **libcosmic `widget::text_editor`** (in `/root/libcosmic`, shared): the
   pinned toolkit rev predates two API additions that cosmic-files/cosmic-term
   HEAD use. Added, mirroring the underlying iced 0.14 widget:
   - re-export `pub use text_editor::text_editor;` at `widget` scope (the fn was
     only reachable as `text_editor::text_editor`).
   - a `TextEditor::class(class: impl Into<Catalog::Class>)` builder method
     (delegates to `self.inner.class(...)`), which the newer apps call instead
     of `.style(...)`.
   Both additive; do not change existing behaviour.

5. **cosmic-app-list + cosmic-applet-minimize** (`src/wayland_handler.rs`):
   `rustix::fs::memfd_create` / `MemfdFlags` are gated to
   `linux_kernel`/`freebsd` in rustix 1.1.4 — absent on illumos. Added an
   `#[cfg(any(illumos, solaris))]` fallback that creates an anonymous fd via
   POSIX shm (`rustix::shm::open` CREATE|EXCL|RDWR with a per-pid/nanosecond
   unique name, then `rustix::shm::unlink` so it vanishes on close). Used for
   screencopy thumbnail capture — only exercised with a compositor anyway.

6. **cosmic-files**: built `--no-default-features --features
   wayland,desktop,dbus-config,notify` (drop `io-uring` [Linux io_uring via
   compio], `gvfs` [Linux], `wgpu`/`bzip2`/`lzma-rust2` not needed for the link
   proof). Relies on fix (4). `trash`/`walkdir`/`mime_guess`/`xdg-mime`/
   `notify-debouncer-full` all build native on illumos.

## Apps DEFERRED (precise blockers)

- **cosmic-panel** (cosmic-panel-bin): HARD DRM/GPU wall. Its `smithay` dep is
  `default-features=false, features=[use_system_lib, desktop, backend_egl,
  backend_drm, renderer_gl]` (rev f0992e7) — `backend_drm` pulls drm-ffi whose
  `rustix::ioctl::{None,Read,Write,ReadWrite}Opcode` are gated linux/bsd, absent
  on illumos; `backend_egl`/`renderer_gl` need a Mesa EGL/GLES `-sys` GPU
  driver. This is the same live-DRM/GBM boundary as cosmic-comp (documented in
  docs/cosmic-rust-stack.md), not a Rust/illumos crate gap. The panel renders
  its layer-shell surface through the compositor's GL backend at compile time.
  (`cosmic-panel-button`, a separate small member, DID build — it's a plain
  libcosmic applet, no smithay.)

- **cosmic-applet-a11y**: `iced_futures` version dup — E0308 `Subscription<M>`
  mismatch. It depends on `cosmic-settings` subscription crates via git, which
  pull `libcosmic` (and thus `iced_futures`) from a git checkout (rev 511384f)
  NOT redirected by the top-level `[patch]` (the patch only covers the
  `libcosmic`/`cosmic-config`/`cosmic-theme` names, not the nested
  `iced_futures` path dep inside a second libcosmic checkout). Two `iced_futures`
  in the graph -> the subscription types don't unify. Fix = also patch the
  `cosmic-settings` git dep to a matching rev / redirect its libcosmic; a
  transitive graph fix, not illumos. Deferred.

- **cosmic-applet-bluetooth**: `bluer` (BlueZ) has a hard
  `compile_error!("BlueR only supports the Linux operating system")`. No illumos
  BlueZ. Would need an illumos bluetooth backend or a stub applet. Deferred.

- **cosmic-applet-battery, cosmic-applet-tiling, cosmic-applet-input-sources,
  cosmic-applets (meta)**: pull `libudev-sys` (udev C lib, Linux hardware
  enumeration). No illumos udev. Deferred (hardware layer, not a Rust gap).

## Runtime-gated on the compositor

ALL GUI apps (launcher/term/files/every applet) need a running Wayland
compositor + display to actually paint. cosmic-comp (the real compositor) is
DRM-walled (documented); the built `smallvil` SW compositor is the current
Wayland substrate. cosmic-session (the glue) launches the compositor + panel +
apps; it links and its CLI runs, but a full session run needs the compositor +
the session config files present. The COMPILE + link + `--help` is the Wave-1
deliverable; painting is the next (compositor/DRM) wave.

## Publish

`/tmp/.pubcreds` is not present this session, so `oi-publish-wave.sh` could not
push. The 14-binary bundle is staged at
`/nix/store/5m4c9x9wk9a42wbgsn33hi2mn5n620lq-wave-bin` and recorded in
`/root/cosmic-apps-wave1-paths.txt` for the orchestrator to publish. published=0.
