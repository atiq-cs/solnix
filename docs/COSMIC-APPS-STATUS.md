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


---

# COSMIC desktop apps — wave 2 (settings / config-daemon / notifications / bg / workspaces)

Same substrate as wave 1: native `x86_64-unknown-illumos`, the built
`/root/libcosmic` toolkit, `/root/cosmic-cargo-home` (shared registry with the
baked-in illumos patches — wayland-backend/winit/rustix), rust seed 1.97.1,
OpenIndiana gcc 14. Each libcosmic-using app gets the wave-1 `[patch]` block
appended (`libcosmic`/`cosmic-config`/`cosmic-theme` -> `/root/libcosmic`).

Two additions to the recipe this wave:
1. **`/usr/gnu/bin` on PATH** — `gettext-sys` builds bundled gettext from source
   with GNU `ld`; wave-1 apps had it, cosmic-settings needs it too.
2. **illumos udev/libinput link stubs** (`/root/illumos-shims/udev`, regen script
   in `rust-patches/make-udev-input-stubs.sh`) — see the fixes below.

## Apps COMPILED to x86_64-illumos ELF (wave 2)

| app | binary | runs |
|---|---|---|
| **cosmic-notifications** | cosmic-notifications/.../release/cosmic-notifications | `--version`/start OK, panics at winit (no display) = runtime gate |
| **cosmic-bg** | cosmic-bg/.../release/cosmic-bg | starts, "Could not find wayland compositor" = runtime gate |
| **cosmic-settings** | cosmic-settings/.../release/cosmic-settings | `--help` lists pages (with `LD_LIBRARY_PATH=/root/illumos-shims/udev`); GUI runtime-gated |
| **cosmic-settings-daemon** (config/theme parts) | rlibs: libcosmic_settings_config / libcosmic_settings_daemon_config / libgeonames | library crates — no binary (binary needs pipewire+udev, below) |

Staged bundle: `/root/cosmic-apps/wave2-bin/` (+ `wave2-bin/lib/` = the udev/input
stubs). Paths file: `/root/cosmic-apps-wave2-paths.txt`.

### cosmic-settings — pages that compile (11 of ~16)

Built `-p cosmic-settings --no-default-features` with:
`wayland,single-instance,openrc,page-about,page-date,page-power,page-region,
page-users,page-networking,page-default-apps,page-window-management,
page-workspaces,page-legacy-applications,page-display`.

Compiling pages: **about, appearance (via the app core), date-time, power,
region, users, networking, default-apps, window-management, workspaces,
legacy-applications, display**. `nmrs` (NetworkManager), `secret-service`,
`accounts-zbus`, `locales-rs`, `cosmic-mime-apps`, `cosmic-randr-shell`,
`upower_dbus`, `timedate-zbus`, `hostname1-zbus`, `sysinfo` all build native.

Pages DEFERRED:
- **page-sound** — `cosmic-settings-audio-client` -> `libspa-sys`/`pipewire-sys`
  (PipeWire audio C lib, pkg-config + bindgen against real SPA headers). No
  illumos PipeWire. A symbol-stub is not enough (bindgen needs the headers).
- **page-input**, **page-accessibility** — the wave-1 a11y dup: two `iced_core`/
  `iced_futures` in the graph (a second libcosmic checkout via the
  `cosmic-settings-config`/subscription git deps NOT redirected by the top-level
  `[patch]`). `physical_to_scancode(Physical)` sees two different `Physical`
  types -> E0308. A transitive-graph fix (redirect the nested libcosmic), not an
  illumos gap.
- **page-bluetooth** — `bluez-zbus` + BlueZ; no illumos BlueZ (same wall as the
  wave-1 bluetooth applet).
- **avif** feature — `dav1d` C lib via pkg-config (dropped; png/jpeg/webp keep).
- **wgpu** feature — GPU/Mesa (dropped, as wave-1 did for cosmic-files).

## cosmic-settings-daemon — the logind-equivalent verdict

**Key finding: this daemon does NOT use logind/systemd/seatd/session at all.**
`grep -rni 'logind|seatd|libseat|Session|Suspend|systemd' src/` is empty. It is
the *config/appearance/theme/date/battery* daemon, not a session/power manager.
So **seatd does not help this daemon** — there is nothing here that wants a
logind seat/session API.

What builds vs. what walls the binary:
- **Config/theme parts BUILD clean** as rlibs: `cosmic-settings-config`,
  `cosmic-settings-daemon-config` (theme/greeter), `geonames`. These are the
  input-config, shortcuts, theme, and geoname (timezone/region) pieces — the
  parts an illumos COSMIC session actually needs for appearance/config.
- **The daemon *binary* has two Linux-hardware C-lib walls (NOT logind):**
  1. **pipewire** — `cosmic-settings-audio-server` -> `libspa-sys`/`pipewire-sys`
     (pkg-config `libpipewire-0.3` + bindgen against SPA headers). Audio server.
  2. **udev** — `udev` crate for backlight enumeration in `main.rs`
     (`udev::Enumerator`/`MonitorBuilder`). Linux hardware.
  `upower_dbus` (battery) is D-Bus and portable — only needs a upower service.

Verdict: the daemon's **config/theme/appearance layer is illumos-ready today**
(the rlibs compile). The full daemon binary needs an illumos audio backend
(PipeWire or a pipewire-shim) + a udev-equivalent for backlight. Neither is a
logind gap — logind is simply not used here. If a future COSMIC session on
illumos wants seat/session/power management, that lives in cosmic-comp /
cosmic-session (wave 1), where seatd is the relevant illumos piece.

## Per-app illumos fixes (wave 2)

1. **cosmic-notifications**: `--no-default-features` (drop `systemd` ->
   `tracing-journald`, Linux journald). Everything else (zbus/dbus p2p, tokio,
   cosmic-panel-config, enumflags2) builds native. No source edits.

2. **cosmic-bg**: `--no-default-features` (drop `avif` -> `dav1d-sys` pkg-config
   C lib). Keeps png/jpeg/webp/jxl. `smithay-client-toolkit` (Wayland *client*,
   not the compositor DRM stack) builds native. No source edits.

3. **gettext-sys 0.26**: prepend `/usr/gnu/bin` to PATH so the bundled
   gettext-0.26 `configure`/`make` uses GNU `ld` (same as wave 1; needed because
   cosmic-settings + libcosmic pull `freedesktop-desktop-entry` ->
   `gettext-rs`/`gettext-sys`). No source edits.

4. **cosmic-settings**: `--no-default-features` + explicit page features (above)
   + `openrc` (the app has a `compile_error!("Enable 'systemd' or 'openrc' ...")`
   guard for bluetooth service management; `openrc` is the neutral non-systemd
   path). No source edits.

5. **illumos libudev / libinput link stubs** (NEW — `rust-patches/`):
   `cosmic-comp-config` has an unconditional `input = "0.10"` dep (libinput
   binding) which pulls `input-sys` (`-linput`) + `udev` -> `libudev-sys`
   (`-ludev`), and cosmic-settings `page-display`/`page-input` use `udev`
   directly. udev + libinput are Linux hardware C libs with no illumos port, but
   the config crates only need them to LINK (the enumeration paths are
   runtime-gated on the compositor). Fix: a `libudev.so.1` (82 syms) and
   `libinput.so.10` (298 `libinput_*` syms) built from the crate-declared symbol
   lists, each an `abort()`-ing no-op, plus matching `.pc` files.
   - build: `PKG_CONFIG_PATH=/root/illumos-shims/udev RUSTFLAGS="-L /root/illumos-shims/udev"`.
   - runtime: `LD_LIBRARY_PATH=/root/illumos-shims/udev` (a real udev/libinput
     call aborts loudly — never reached for `--help` or the non-hardware pages).
   This unblocked page-display, page-window-management, page-workspaces,
   page-legacy-applications in cosmic-settings, and would unblock the daemon's
   backlight-udev part (pipewire remains the daemon binary wall).
   Regen: `sh rust-patches/make-udev-input-stubs.sh <dir>`.

## Apps DEFERRED (wave 2)

- **cosmic-workspaces-epoch**: HARD DRM/GBM wall (same boundary as cosmic-panel /
  cosmic-comp). Unconditional deps `gbm = "0.18"` (-> `gbm-sys`, DRM buffer
  management) + `drm-sys` (via cosmic-protocols/screencopy) + `cosmic-comp-config`
  (-> udev). The udev part is covered by the stub above, but `gbm-sys`/`drm-sys`
  are the live GPU/DRM buffer layer (Mesa GBM + kernel DRM ioctls), the same
  compositor-adjacent wall documented for cosmic-panel in wave 1. This is the
  workspace *overview* — it composites live surface thumbnails through GBM/DRM.
  Deferred with the compositor/DRM wave, not ground on.

## Runtime gate (unchanged from wave 1)

All GUI wave-2 apps need a running Wayland compositor + display to paint. They
link + start + hit the winit "no WAYLAND_DISPLAY" gate (cosmic-notifications) or
"Could not find wayland compositor" (cosmic-bg), which is the expected runtime
gate, not a link failure. cosmic-settings additionally needs
`LD_LIBRARY_PATH=/root/illumos-shims/udev` at runtime for the udev/input stubs.
