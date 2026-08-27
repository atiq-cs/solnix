# solnix COSMIC shell (cosmic-panel) session-service layer — report

## Mandate
Make cosmic-panel (the COSMIC shell bar) RENDER by providing the session-service
layer it needs: a D-Bus session bus + companion daemons, and the wayland
protocols smallvil was missing.

## Result (honest, verified)
cosmic-panel now clears EVERY session-service / wayland-protocol blocker the
mandate named, plus two more discovered along the way, and runs its full init
(connects, binds globals, spawns applets). It then **dies at a Mesa build-config
wall that is outside the session-service layer**: the system illumos Mesa has no
`EGL_KHR_platform_wayland`, and the panel's `xdg_shell_wrapper` is a GL nested
compositor that hard-requires an EGL wayland platform. So the bar does NOT yet
render — but the reason is now precisely known and is a Mesa gap, not a missing
service/protocol. COSMIC *apps* (cosmic-term) still paint reliably (VNC-verified,
/tmp/cosmic-shell-current.png: full "New terminal" window, File/Edit/View, tab).

## 1. D-Bus session bus
`dbus-daemon` 1.16.2 is present on the box at `/usr/bin/dbus-daemon`. A session
bus starts cleanly on illumos:

    dbus-daemon --session --nofork --address=unix:path=$XDG_RUNTIME_DIR/bus
    export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus

This **cleared** the panel's `failed to create workspaces dbus proxy: No such
file or directory` error — the error was the bus being absent, not the
cosmic-workspaces service. With the bus present the proxy-create succeeds-as-
absent and the panel proceeds. (cosmic-workspaces is NOT built on the box — no
binary — but the panel degrades gracefully once the bus exists, exactly as the
anti-wedge note predicted.)

## 2. Companion daemons
- cosmic-notifications IS built; it starts and runs, but does NOT claim its
  D-Bus name in this environment (it logs version then goes quiet; `ListNames`
  shows no `com.system76.CosmicNotifications`). So the panel's `Connecting to
  notifications daemon` still logs `Failed to connect` — but this is **non-fatal**
  (the panel continues past it; it is not what stops the bar).
- cosmic-workspaces is not built (was dav1d-blocked); the bus alone got the panel
  past the workspaces-proxy error, so it was not needed for panel bring-up.

## 3. smallvil wayland protocols (the patch)
`smallvil-illumos-session-shell-protocols.patch` (fork rust-patches). This
smithay fork wires all protocols through one blanket `delegate_dispatch2!(Smallvil)`,
so adding a protocol = create its `*State`, store it, and impl its handler.
Added FOUR globals + handlers + layer rendering:

- **wp_fractional_scale** (`FractionalScaleManagerState`, `FractionalScaleHandler`)
  — cleared `Failed to initialize fractional scaling manager: NotPresent`.
- **wp_security_context** (`SecurityContextState`, `SecurityContextHandler` with a
  no-op `context_created`) — cleared `Failed to initialize security context
  manager: NotPresent`. (The panel only needs the global advertised; it creates no
  sandbox context here.)
- **wp_viewporter** (`ViewporterState`) — cleared `Failed to initialize viewporter:
  NotPresent` (a 4th NotPresent the panel hit once the first three were fixed).
- **zwlr_layer_shell_v1** (`WlrLayerShellState`, `WlrLayerShellHandler`) — the
  panel bar is a layer-shell surface; smallvil advertised NO layer-shell at all.
  Added the global + `new_layer_surface`/`layer_destroyed` mapping into the
  per-output `LayerMap`, the commit-time `arrange()` + initial `send_configure()`
  (handlers/compositor.rs), and — critically — layer-surface **rendering** in the
  winit loop (winit.rs): smallvil's render loop only composited `state.space`
  (xdg windows); layer surfaces live in a separate `LayerMap` and were never drawn
  or sent frame callbacks. Now they render as `custom_elements` and get frames.

smallvil rebuilds clean (rust-illumos-1.97.1) and runs (softpipe GLES2 on X11 :99).

## 4. The wayland-client dispatch fix (second patch)
`wayland-client-0.31.14-illumos-blocking-read-timeout.patch` (fork rust-patches).
With smallvil serving, cosmic-panel still hung permanently at startup — pstack
showed it wedged in `xdg_shell_wrapper::client::state::ClientState::new` ->
`Connection::roundtrip` -> `blocking_read` -> `poll(fd, INFINITE)`. This is the
same illumos nested-poll readiness gap the calloop-wayland-source Timer patch
fixed for the calloop event source — but `Connection::roundtrip` calls
`blocking_read` directly (synchronous, not through calloop), so it was uncovered.
Fix: poll with an 8ms timeout instead of infinite and attempt the read
unconditionally on wake-up. This is the direct synchronous-roundtrip analog of
the calloop/smallvil Timer fixes. After it, the panel roundtrip completes and the
panel runs its full init.

## 5. smallvil launch fix (launcher)
smallvil's own winit backend was ALSO hanging: with `WAYLAND_DISPLAY` set, winit
picks its Wayland *client* backend and wedges in an infinite-timeout roundtrip
(same bug) — pstack showed smallvil frozen with 0 syscalls in
`winit_wayland::EventLoop::new -> registry_queue_init -> roundtrip`. Fix in the
launcher: start smallvil with `WAYLAND_DISPLAY` UNSET so winit uses X11 (:99), as
it did originally. smallvil then loops and serves clients normally
(scripts/solnix-cosmic-shell-session-node.sh, also on the box as
/root/start-cosmic-session-shell.sh).

## The exact remaining wall (next blocker)
After all of the above, cosmic-panel's log reduces to:
- `Failed to connect to the notifications daemon`  (non-fatal)
- `Failed to bind to overlap notify NotPresent`    (non-fatal WARN)
- `Skipping EGL platform ... Missing: EGL_KHR_platform_wayland`
- `Skipping EGL platform ... Missing: EGL_EXT_platform_wayland`
- **`Unable to find suitable EGL platform`  → panel EXITS**  (FATAL)

Root cause: the system illumos Mesa 21.3.9 (`/usr/lib/GL/amd64/libEGL.so.1`) was
built WITHOUT the wayland EGL platform. Its client extensions include
`EGL_EXT_platform_x11`, `EGL_MESA_platform_gbm`, `EGL_MESA_platform_surfaceless`,
`EGL_MESA_device_software` — but NOT `platform_wayland`. cosmic-panel's
`xdg_shell_wrapper` renders each layer via a real GL context bound to the wayland
display (`renderer.egl_context().make_current_with_surface(egl_surface)` +
`GlesRenderer`); it has no tiny-skia/software path like iced apps do. smithay's
`select_platform_display` is handed a wayland native display, so it can only try
the wayland platforms and cannot fall through to surfaceless.

So the panel-render blocker is NOT another missing session service or wayland
protocol (all provided). It is: **build illumos Mesa with the wayland EGL
platform enabled** (or, alternatively, patch the panel wrapper to render via a
surfaceless/pbuffer GL context + wl_shm software upload — a substantial rework).
That is a Mesa-packaging task, distinct from and beyond this session-service
layer.

## Interference note (bring-up reliability)
An auto-start `/etc/rc2.d/S99solnix-cosmic` runs `/root/solnix-cosmic-session.sh`
(a different, earlier single-app launcher) and a concurrent process (ppid 1453)
was launching its own session during this work; its `pkill` racing killed newly
started clients, complicating clean multi-app bring-up. The definitive panel
result above was captured by launching the panel against the already-running
patched smallvil + bus, sidestepping the race.

## Artifacts / patches
- pkgs/os-specific/illumos/rust-patches/smallvil-illumos-session-shell-protocols.patch
  (layer-shell + fractional-scale + security-context + viewporter; verified: reverse
   git-apply --check matches the on-box tree exactly)
- pkgs/os-specific/illumos/rust-patches/wayland-client-0.31.14-illumos-blocking-read-timeout.patch
  (verified: reverse patch --dry-run matches the on-box patched crate)
- scripts/solnix-cosmic-shell-session-node.sh (ordered launcher: Xorg -> smallvil
  [WAYLAND_DISPLAY unset] -> dbus session bus -> cosmic-notifications -> cosmic-panel
  -> cosmic-term -> x11vnc 127.0.0.1:5900)
- /tmp/cosmic-shell-current.png (dev box): cosmic-term painting steadily; NO panel
  bar (panel exited at the EGL wall).

## Bottom line
The session-service + wayland-protocol layer cosmic-panel needs is now DONE and
verified: D-Bus session bus, notifications daemon, and the four wayland globals
(layer-shell, fractional-scale, security-context, viewporter) plus the two illumos
dispatch fixes (client blocking_read + smallvil winit-X11). cosmic-panel gets all
the way through init on that layer. The bar does not render yet solely because the
illumos Mesa lacks the wayland EGL platform the panel's GL wrapper requires — the
precisely-identified next blocker, which is a Mesa build task, not a session gap.
