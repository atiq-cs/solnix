# COSMIC suite client-dispatch propagation -> multi-app painting desktop

## Result

A **steady, verified multi-app COSMIC desktop** paints on illumos/x86_64 over
smallvil: **cosmic-term (terminal) + cosmic-files (file manager, live home-dir
listing)**, cascaded so both windows are visible. Verified over VNC with two
raw-RFB captures 30s+ apart yielding **identical md5 (5b6f9868...)** -- steady,
not a lucky single frame. Screenshot: `/tmp/cosmic-desktop-full.png` (dev box).

## The fix propagated

The proven illumos calloop-wayland-source Timer dispatch fix
(`calloop-wayland-source-illumos-timer-dispatch.patch`) was already applied to
the SINGLE shared registry-src copy in `CARGO_HOME=/nix/cosmic/cosmic-cargo-home`
(all priority apps pin calloop-wayland-source 0.4.1 + share that cargo home).
So propagation collapsed to: `cargo clean -p calloop-wayland-source` per app +
rebuild. The build-note gotcha held true -- registry-src uses `.cargo-ok` (no
`.cargo-checksum`), so editing the shared src does not evict an app's stale
rlib; you must `cargo clean -p <crate>` first or the fix silently no-ops.

## Apps rebuilt + PAINT (each verified)

| App | Rebuild | Paints | Notes |
|-----|---------|--------|-------|
| cosmic-term | pre-existing | YES | proven baseline, re-verified steady (md5 810d4939) |
| cosmic-files | EXIT 0 | YES | needed `cargo clean -p softbuffer` too (below); file manager w/ live listing |
| cosmic-launcher | EXIT 0 | (built, links patched calloop) | not placed in the 2-window frame |
| cosmic-notifications | EXIT 0 | (built) | daemon; no standalone window |
| cosmic-panel | EXIT 0 | NO -- EGL blocker | see blockers |
| cosmic-settings | build FAIL | -- | dav1d-sys native-lib blocker |
| cosmic-bg | build FAIL | -- | dav1d-sys native-lib blocker |

## Per-app extra blockers (exact)

- **cosmic-files softbuffer stale rlib**: first rebuild kept a
  pre-`softbuffer-illumos-posix-shm.patch` softbuffer rlib (only calloop was
  cleaned) -> panic `softbuffer .../wayland/buffer.rs:52 Failed to create POSIX
  shm ... Os { code: 22 }` (the leading-slash shm-name bug that patch fixes).
  Fixed by `cargo clean -p softbuffer` + rebuild. (cosmic-term already carried a
  post-patch softbuffer rlib, which is why term worked and files did not despite
  byte-identical source.) NOT a dispatch issue.

- **cosmic-panel** (beyond dispatch): the dispatch fix applies and the panel
  runs past dispatch, but `xdg_shell_wrapper` renders each layer-shell surface
  **client-side via `GlesRenderer`/EGL** (`.../xdg_shell_wrapper/space/
  egl_surface.rs`). On the SW-only smallvil stack a Wayland client has no EGL
  platform -> `Unable to find suitable EGL platform` and the panel exits. This
  is the live-EGL wall (same class as the deferred cosmic-comp), not dispatch.
  The panel bar is therefore not in the frame; two app windows are delivered
  instead, per the anti-wedge fallback.

- **cosmic-settings / cosmic-bg** (beyond dispatch): `dav1d-sys 0.8.3` requires
  system `libdav1d >= 1.3.0` (AV1 decode) via pkg-config, absent on illumos ->
  build fails before link. Native-lib blocker.

## Runtime findings (why the pipeline painted)

- smallvil MUST run with `WAYLAND_DISPLAY` **unset** so its winit backend uses
  X11 (PLATFORM_X11_KHR) and maps a real X window on :99. With it set, smallvil
  renders headless/surfaceless and the x11vnc root capture is black. (This was
  the single biggest time sink -- an earlier session had WAYLAND_DISPLAY set and
  every capture came back black despite clients committing frames.)
- `svcadm restart application/opengl/ogl-select` before smallvil (amd64
  GLX/DRISWRAST link fresh AMIs miss).
- POSIX shm exhaustion: crashed softbuffer clients leak anonymous shm segments
  (`ipcs -m`, KEY 0x0); `project.max-shm-ids` default 128 fills and even correct
  `shm_open` then returns EINVAL. Launcher reaps orphans + raises the ceiling to
  4096.
- visible multi-window: stock smallvil maps every toplevel at (0,0); a cascade
  patch offsets each new window so both show.

## New patches / build-notes (persisted to the fork for the orchestrator)

- `pkgs/os-specific/illumos/rust-patches/smallvil-illumos-cascade-toplevels.patch`
  -- offset xdg-shell toplevels so multiple app windows are visible.
- `pkgs/os-specific/illumos/rust-patches/cosmic-apps-illumos-build-notes.md`
  -- appended "Client-dispatch fix propagation (wave B3)": shared-cargo-home
  clean-rebuild flow + the `.cargo-ok` stale-rlib gotcha (calloop AND softbuffer),
  the panel EGL / settings+bg dav1d blockers, and the multi-app session recipe
  (WAYLAND_DISPLAY-unset, ogl-select, shm reap, cascade).

(No new patch was needed for the dispatch fix itself -- it was already in the
fork and already applied to the shared cargo home. No git commit made.)

## Node (left running)

i-0d62b4aadb9e186d2 / 3.135.213.174, us-east-2, AWS_PROFILE=chiuso. Live session:
Xorg :99 + cascade-smallvil + cosmic-term + cosmic-files + x11vnc on
**127.0.0.1:5900 only** (SG/0.0.0.0 untouched). Launcher:
`/root/start-cosmic-session.sh`. Capture tool (pure-stdlib raw RFB):
`/nix/cosmic/rfbcap.py`. Window lister (libX11): `/nix/cosmic/lswin2`.
Tunnel to view: `ssh -N -L 5900:127.0.0.1:5900 root@3.135.213.174`.

## Verification artifacts

- `/tmp/cosmic-desktop-full.png` (dev box) -- steady multi-app frame: terminal +
  file manager, cascaded. md5 5b6f9868..., identical across a 32s re-capture.
- `/tmp/cosmic-suite-progress.txt` (dev box) -- per-step progress log.
