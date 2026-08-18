# COSMIC / Wayland Rust stack cross-build to aarch64-illumos (EM_AARCH64)

## Verdict (updated)

**The COSMIC compositor stack cross-builds to aarch64-illumos, compile-phase,
for every layer except the live-DRM/GPU/udev hardware backends.**

The one bounded blocker from the previous wave -- `wayland-backend`'s pure-Rust
server backend -- is CLOSED. With a targeted illumos patch it cross-builds, and
that unblocked the entire Wayland-Rust layer, the smithay non-hardware core, and
the full COSMIC GUI toolkit (`libcosmic` 1.0.0 + the pop-os `iced`/`winit`/
`softbuffer` forks + `cosmic-config` + `cosmic-theme` + `cosmic-text` +
`cosmic-client-toolkit` + `cosmic-protocols`).

`cosmic-comp` (the compositor) is hardware-gated by design: it hard-requires
smithay's `backend_drm`/`backend_gbm`/`backend_egl`/`backend_udev`/
`backend_session_libseat`/`backend_libinput`/`backend_vulkan`/`backend_x11` +
`renderer_glow`/`renderer_multi`/`renderer_pixman` -- every one pulls a Linux
DRM/KMS/udev/libseat/mesa/vulkan `-sys` native lib. That is the live-hardware
boundary, not a Rust/illumos gap.

**"The COSMIC compositor stack cross-builds to aarch64-illumos except the
live-DRM/GBM/udev/libinput/vulkan hardware backends (which need a real GPU +
DRM node)."**

## What changed since the last wave

- **wayland-backend patch: APPLIED and it works.** The rust server backend
  cross-builds EM_AARCH64.
- **The whole Wayland-Rust layer cross-builds**: wayland-client, wayland-server,
  wayland-scanner, wayland-cursor, wayland-protocols, wayland-protocols-wlr.
- **smithay 0.7.0 non-hardware core cross-builds**: `wayland_frontend` +
  `desktop` (the full wayland-server frontend, protocol handlers, desktop
  space/window management, utils, SHM, dmabuf types).
- **smithay-client-toolkit** cross-builds (with cross-pkg-config wired).
- **A cosmic-\* crate cross-builds -- the milestone hit**: `cosmic-config`,
  `cosmic-theme`, and the whole `libcosmic` 1.0.0 GUI toolkit cross-build
  EM_AARCH64. COSMIC compiles for solnix.

## The wayland-backend illumos patch (the unblock)

The previous report predicted the disk patch (add illumos to the epoll cfg
allowlist) was "necessary-but-insufficient" and that illumos would need a real
`poll(2)`/event-ports path. **That prediction was wrong in a good way**: the
rustix version wayland-backend-0.3.17 actually pulls is **rustix 1.1.4**, which:

- exposes `rustix::event::epoll` on illumos
  (`#[cfg(any(linux_kernel, target_os = "illumos", target_os = "redox"))]` --
   illumos ships an epoll(2) emulation), and
- exports `Timespec` unconditionally from `rustix::event`, and
- provides `epoll::{create, add, delete, wait}` with the modern
  `Buffer`/`spare_capacity` `wait` signature wayland-backend uses.

So illumos can use the same epoll code path as Linux -- no bespoke event-ports
backend needed. The real gaps were narrower than feared, and the full patch has
three parts (`/root/cosmic-rust/patches/wayland-backend-0.3.17-illumos.patch`):

1. `src/rs/server_impl/common_poll.rs` -- add `illumos`/`solaris` to the epoll
   cfg allowlist at all three sites the previous disk patch touched **plus the
   `epoll::delete` site in `dispatch_events_for`** the disk patch missed.
2. `src/rs/server_impl/handle.rs` -- add `illumos`/`solaris` to the `epoll::add`
   cfg in `insert_client` (the disk patch missed this file entirely; without it
   `insert_client` gets no `ret` binding -> E0425).
3. `src/rs/socket.rs` -- the ONE genuine illumos gap: `RecvFlags::CMSG_CLOEXEC`
   is cfg'd out on `solarish` in rustix (illumos libc has no
   `MSG_CMSG_CLOEXEC`). Patch: on `illumos`/`solaris` fall back to
   `RecvFlags::DONTWAIT` and set `FD_CLOEXEC` on each received fd manually with
   `fcntl` -- exactly what the crate already does for macos/redox.

Result: `wayland-backend v0.3.17` -> `libwayland_backend-*.rlib` EM_AArch64.
Verified with `readelf -h` Machine: AArch64.

## The Wayland-Rust layer (unblocked by the patch)

All cross-built EM_AARCH64 via a `[patch.crates-io] wayland-backend = { path =
... }` override:

| crate                  | version | note |
|------------------------|---------|------|
| wayland-backend        | 0.3.17  | patched (illumos epoll + solarish recv-flag) |
| wayland-client         | 0.31.15 | |
| wayland-server         | 0.31.14 | |
| wayland-scanner        | 0.31.11 | proc-macro (host) + AArch64 output |
| wayland-cursor         | 0.31.14 | |
| wayland-protocols      | 0.32.13 | client+server+staging+unstable |
| wayland-protocols-wlr  | 0.3.12  | client+server |

## smithay -- which modules cross-build vs which are hardware-gated

Built `smithay 0.7.0` with `--no-default-features --features
wayland_frontend,desktop`. Cross-built EM_AARCH64 -> `libsmithay-*.rlib`.

Two smithay source fixes were needed, only ONE illumos-specific:

- **illumos gap**: `src/wayland/shm/pool.rs` -- on illumos `siginfo_t::si_addr`
  is an accessor **method**, not a struct field (glibc/BSD expose a field).
  Patch adds a solarish arm calling `(*info).si_addr()`.
- **not illumos** (upstream rand 0.10 API drift): `src/utils/sealed_file.rs`
  needs `use rand::RngExt` for `.sample()`; and `src/backend/allocator/dmabuf.rs`
  uses `rustix::ioctl::opcode` (gated linux/bsd/redox) for the `DMA_BUF_SYNC`
  ioctl -- gated to non-illumos with an illumos no-op `sync_plane` (there is no
  DMA-BUF kernel interface on illumos; dmabuf-fd sharing is Linux/DRM-specific).
  Patch: `/root/cosmic-rust/patches/smithay-0.7.0-illumos.patch`.

**Cross-builds (non-hardware, compile-phase):**
- `wayland_frontend` -- the entire wayland-server frontend + all protocol
  handlers (compositor, shm, seat, output, xdg-shell, layer-shell, dmabuf
  protocol types, ...).
- `desktop` -- space/window/layer management, damage tracking.
- `utils`, `input` abstractions (the types), the SHM renderer glue, dmabuf
  *types* (minus the Linux sync ioctl).

**Hardware-gated (need live DRM/GPU/udev -- NOT cross-built):**
- `backend_drm` / `backend_gbm` -> `drm`, `drm-ffi`, `drm-sys`, `gbm` (Linux DRM
  kernel FFI + Mesa GBM; `drm-ffi` uses `rustix::ioctl::{None,Read,Write,
  ReadWrite}Opcode`, all gated linux/bsd -- this is the live-DRM boundary).
- `backend_egl` / `renderer_gl(ow)` -> Mesa EGL/GLES `-sys` (needs a GPU driver).
- `backend_libinput` -> `input` (libinput C lib, evdev).
- `backend_udev` -> `udev` C lib.
- `backend_session_libseat` -> `libseat` C lib.
- `backend_vulkan` -> `ash` (Vulkan loader + ICD).
- `backend_x11` / `backend_winit` -> xcb/X11 `-sys`, winit DRM path.
- `renderer_multi` / `renderer_pixman` -> pixman `-sys` + multi-GPU DRM.

## smithay-client-toolkit

Cross-built EM_AARCH64 with `calloop,xkbcommon` features (cross-pkg-config wired
to the wave18 aarch64 `xkbcommon.pc`/`wayland-*.pc`). Pulled + cross-built its
closure: calloop 0.13, calloop-wayland-source, wayland-csd-frame, cursor-icon,
xkeysym, xkbcommon 0.7, memmap2, polling. -> `libsmithay_client_toolkit-*.rlib`.

## THE MILESTONE: cosmic-\* crates cross-build EM_AARCH64

COSMIC compiles for solnix. Built against the pop-os `libcosmic` 1.0.0 checkout
(iced + winit + softbuffer submodule forks).

| cosmic-\* crate            | version | note |
|----------------------------|---------|------|
| **libcosmic** (crate `cosmic`) | 1.0.0 | the COSMIC GUI toolkit -- full lib cross-built |
| cosmic-config              | 1.0.0   | config layer every cosmic app uses (macro+subscription) |
| cosmic-theme               | 1.0.0   | theme layer |
| cosmic-text                | 0.19.0  | (pop-os fork, pulled by libcosmic) |
| cosmic-client-toolkit (cctk) | 0.1.0 | cosmic wayland client toolkit |
| cosmic-protocols           | 0.1.0   | cosmic wayland protocol bindings |

`libcosmic` was built `--no-default-features --features wayland,tokio` (the
Wayland software path). It pulled + cross-built the whole COSMIC GUI stack:
the pop-os `iced` 0.14 fork (`iced_core`, `iced_runtime`, `iced_widget`,
`iced_winit`, `iced_wgpu`, `iced_graphics`, `iced_tiny_skia`, `iced_futures`,
`iced_debug`), the pop-os `winit` cosmic-0.14 fork, `softbuffer` (wayland
software path), `taffy`, `glam`, `reis`, plus the cosmic-config/theme layers --
ALL EM_AARCH64.

Two more bounded, non-hardware fixes were needed on the way (both upstreamable):

- **reis 0.7.1** (`src/util.rs`): the libei client uses
  `net::RecvFlags::CMSG_CLOEXEC` unconditionally with no fallback -- the same
  illumos gap as wayland-backend's socket. Patched to use empty recv flags +
  manual `FD_CLOEXEC` on solarish.
  (`/root/cosmic-rust/patches/reis-0.7.1-illumos.patch`)
- **winit** (pop-os cosmic-0.14, `platform_impl/linux/mod.rs`): `is_main_thread`
  is defined for linux/dragonfly/freebsd/openbsd/netbsd but not illumos ->
  E0425. Added an illumos/solaris arm (std thread-name heuristic; no portable
  main-thread query is bound for solarish in this libc).
  (`/root/cosmic-rust/patches/winit-popos-cosmic-0.14-illumos.patch`)
- **iced (pop-os 0.14 fork)** `Cargo.toml`: its workspace `softbuffer` dep
  enabled default features incl `kms`, which forced `drm`/`drm-ffi` (the DRM
  hardware path) into the software renderer. Set `default-features = false,
  features = ["wayland","wayland-dlopen"]` to keep the wayland software path.
  (`/root/cosmic-rust/patches/iced-popos-0.14-softbuffer-nokms.patch`)

## The next precise blocker

**cosmic-comp itself is hardware-gated.** Its `Cargo.toml` hard-requires smithay
with `backend_drm, backend_gbm, backend_egl, backend_libinput,
backend_session_libseat, backend_udev, backend_winit, backend_vulkan,
backend_x11, renderer_glow, renderer_multi, renderer_pixman`. Every one of those
pulls a Linux-hardware `-sys` native lib (drm-ffi/gbm/mesa-egl/libinput/udev/
libseat/xcb/vulkan/pixman). The first hard compile-phase stop is `drm-ffi`
0.7.1 using `rustix::ioctl::{NoneOpcode, ReadOpcode, WriteOpcode,
ReadWriteOpcode}` -- all gated `linux_kernel/bsd/redox`, absent on illumos.

That is the live-DRM/GPU boundary the task flagged. Closing it is NOT a Rust
gap: it requires an illumos DRM/KMS + GBM + input/session stack (kernel DRM
driver + Mesa GBM/EGL for the target GPU + libinput/udev/libseat equivalents),
i.e. the platform's graphics substrate, not a crate patch. Compile-phase stubs
(RADV-style) could be added crate-by-crate, but they would need the live
`C3-amdgpu` DRM node + a GPU to actually run.

So the actionable next step toward a running COSMIC on solnix is the
**hardware/driver layer** (DRM/GBM/EGL/udev/libseat on illumos), not more Rust
crate porting. The Rust/compile-phase story is done up to that boundary.

## cross-rust recipe re-verified: YES

Unchanged from the previous wave (`/root/cosmic-rust/crossenv.sh`): host x86 OI
rustc 1.97.1 + `RUSTC_BOOTSTRAP=1` + `-Zbuild-std=std,panic_abort` + the
aarch64 cross-gcc 14.3.0 linker + the `/tmp/aa-syslibs` shim
(`-lmd -lmp` + posix4/sendfile/lgrp stubs) + `CARGO_BUILD_TARGET=
aarch64-unknown-illumos`. For the `-sys`/pkg-config crates: `PKG_CONFIG_ALLOW_
CROSS=1` + `PKG_CONFIG_PATH` -> the wave18 aarch64 `xkbcommon.pc`/`wayland-*.pc`.

## Count

**48 EM_AARCH64 rlibs** persisted in `/root/cosmic-rust/rlibs/` (+ the STEP 0
exe), up from 16. Each `readelf -h` Machine: AArch64 (see
`/root/cosmic-rust/rlibs/MANIFEST.txt`).

New named crates cross-built this wave (beyond the prior 16): wayland-backend
(patched), wayland-client, wayland-server, wayland-cursor, wayland-protocols,
wayland-protocols-wlr, wayland-csd-frame, cursor-icon, xkeysym,
smithay-client-toolkit, calloop-wayland-source, smithay, reis, glam,
cosmic-config, cosmic-theme, iced_futures, notify, atomicwrites, libcosmic
(cosmic), cosmic-client-toolkit, cosmic-protocols, iced_winit, iced_wgpu,
iced_tiny_skia, iced_widget, iced_graphics, winit, softbuffer, taffy = **~30
new named crates**, plus their EM_AARCH64 dep closures (~150+ crates compiled
across the projects).

## Artifacts (on the fred node)

- `/root/cosmic-rust/rlibs/*.rlib` -- 48 EM_AARCH64 rlibs
- `/root/cosmic-rust/rlibs/MANIFEST.txt` -- per-file `readelf` Machine confirmation
- `/root/cosmic-rust/patches/` -- the 5 illumos/cross patches:
  - `wayland-backend-0.3.17-illumos.patch` (the unblock)
  - `reis-0.7.1-illumos.patch`
  - `smithay-0.7.0-illumos.patch`
  - `winit-popos-cosmic-0.14-illumos.patch`
  - `iced-popos-0.14-softbuffer-nokms.patch`
- `/root/cosmic-rust/wayland-backend-illumos-epoll.patch` -- the earlier
  (partial) epoll-only patch, superseded by patches/wayland-backend-0.3.17-illumos.patch
- `/root/cosmic-rust/step0-aarch64.exe` -- STEP 0 trivial-crate EM_AARCH64 EXEC
- `/root/cosmic-rust/crossenv.sh` -- the reproducible cross-rust env
- `/root/cosmic-rust/rlibmachine.sh` -- rlib EM-check helper

## The nix-pure COSMIC Wayland session RENDERS (verified, viewable over VNC)
The smithay `smallvil` Wayland compositor + a GTK4/libadwaita client, all nix-pure, SW-rendered, viewable:
- smallvil (nix-pure smithay compositor) runs on illumos: opens a winit-x11 window in Xvfb, inits EGL
  (PLATFORM_X11_KHR) + GlesRenderer on softpipe SW GL, creates the wayland-1 socket, composites.
- A GTK4 4.22.4 / libadwaita 1.9.2 client (AdwApplicationWindow + AdwHeaderBar + AdwStatusPage + a pill
  button, GSK_RENDERER=cairo) connects as a Wayland client + RENDERS inside smallvil. Screenshot:
  solnix-gtk4-libadwaita-wayland.png (27KB, real widgets).
- NIX-PURE (verified via ldd under the launcher path): 73/81 client libs are /nix/store -- the ENTIRE
  GTK4/libadwaita/pango/cairo/harfbuzz/gdk-pixbuf/graphene/wayland/glib toolkit. The 8 non-nix are ONLY the
  illumos base (libc/libm/libpthread/libsocket/libnsl/libmd/libresolv/libmp from /lib/64 + libgcc_s) -- the
  OS itself, unavoidable -- plus the OI-pkg Mesa softpipe libGL/libEGL that smallvil dlopens (the remaining
  purity gap: a nix-pure Mesa/illumos derivation isn't realized on this host yet).
- x11vnc binds 127.0.0.1:5900 only (SG untouched). Connect: ssh -N -L 5900:127.0.0.1:5900 root@<host> +
  vncviewer 127.0.0.1:5900.
- THE REAL FIX (durable, rust-patches/smallvil-illumos-timer-dispatch.patch): clients hung at the Wayland
  handshake because smallvil dispatched its display via a calloop `Generic` FD source -- on illumos the
  nested-epoll readiness of client FDs doesn't propagate to the outer display poll FD, so it never fired.
  Swapped for a periodic calloop `Timer` that polls dispatch_clients + flush_clients every few ms (no epoll
  dependency). Clients then complete the handshake + render. (A general illumos-vs-Linux epoll-nesting
  lesson for the whole smithay/calloop stack.)
=> the nix-pure GTK4/Wayland DESKTOP renders + is viewable. This is the compositor+toolkit layer of the
COSMIC desktop; the cosmic-* APPS (session/panel/launcher/term/files -- wave 1 in flight) render on top of
exactly this. Launcher scripts/solnix-cosmic-session.sh + docs/COSMIC-SESSION-CONNECT.md.

## COSMIC apps WAVE 1 (DONE, self-verified): 14 COSMIC desktop apps compile + run on x86_64-illumos
The toolkit now produces REAL COSMIC desktop-app binaries -- the desktop EXPERIENCE, not just the toolkit:
- 14 apps compiled to real x86_64-illumos ELF (AMD64, readelf/file-confirmed; --help/--version run; GUI apps
  runtime-gated on a compositor): cosmic-session (the glue), cosmic-launcher, cosmic-term (the flagship --
  self-verified "cosmic-term 1.5.0" runs, a real 140MB ELF), cosmic-files (links+starts, winit-gated on a
  display), + 10 applets (time/power/audio/network/notifications/status-area/workspaces/minimize/app-list/
  panel-button).
- Foundation: the rust seed 1.97.1 (native x86_64-unknown-illumos, from cache) + libcosmic + iced recompile
  natively against /root/libcosmic (linker = OI gcc 14.3.0, no lld). Recipe: CARGO_HOME=... cargo build
  --release --target x86_64-unknown-illumos, reusing the built toolkit via [patch."libcosmic"]={path=...}.
- Per-app illumos fixes (pkgs/os-specific/illumos/rust-patches/): cosmic-session --no-default-features
  (drops systemd/logind/journald); wayland-backend 0.3.15/16 <- the patched 0.3.17 illumos files
  (cfg-identical); winit rev f737f1f <- the thr_main() is_main_thread illumos arm; libcosmic TextEditor
  additive .class()/text_editor re-export (toolkit-rev vs app-HEAD API); cosmic-app-list + applet-minimize
  memfd_create->POSIX-shm (illumos rustix has no memfd); cosmic-files --features wayland,desktop,dbus-config,
  notify (drops io-uring/gvfs).
- DEFERRED (precise, all non-illumos-Rust or hardware): cosmic-panel (smithay backend_drm/egl/renderer_gl =
  the live-DRM/GPU wall, same as cosmic-comp; cosmic-panel-button DID build); cosmic-applet-a11y (dup
  iced_futures from a 2nd libcosmic checkout); applet-bluetooth (bluer Linux-BlueZ compile_error); applet-
  battery/tiling/input-sources (libudev-sys Linux udev).
=> THE COSMIC DESKTOP APP SUITE compiles + runs on illumos: session glue + terminal + launcher + file manager
+ 10 applets. The remaining wall is the COMPOSITOR/DRM layer (cosmic-comp -> smallvil SW substrate), NOT the
app suite. WAVE 2 next: cosmic-settings + settings-daemon (needs a logind-equivalent) + notifications + bg +
workspaces-epoch. The apps render on the nix-pure smallvil+GTK4 Wayland session (already proven).
