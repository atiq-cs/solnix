# solnix COSMIC shell -- the panel BAR renders (full pop!_OS COSMIC desktop on illumos)

## Result: WIN

The cosmic-panel BAR is now VISIBLE and the full COSMIC shell renders on illumos
under the patched smallvil (smithay test compositor). Steady VNC-verified:
`/tmp/cosmic-full-shell.png` (also `artifacts/cosmic-full-shell.png`), 69916 bytes,
**byte-identical (md5 64b93265...) across a 30s re-capture** -- a stable, non-black
session, not a bring-up artifact.

The frame shows:
- **A top panel bar with the LIVE clock applet ("Aug 27, 11:09 AM")** in a 32px
  strip anchored top / full width.
- **cosmic-term** ("New terminal", File/Edit/View, +) and **cosmic-files**
  (Home/Trash/Networks sidebar + file listing) app windows composited BELOW the
  panel's reserved strip -- the exclusive zone is honored (apps no longer sit
  under the bar).

So a real COSMIC desktop = panel BAR (with a live applet) + app windows in the
remaining area.

## What was actually wrong (the mandate's premise refined)

The mandate framed the last piece as "smallvil render-order / exclusive-zone."
That part of smallvil was ALREADY correct: the prior session-shell-protocols
patch renders TOP-layer surfaces as `custom_elements` (which smithay's
`render_output` draws ABOVE the Space toplevels) and calls `layer_map.arrange()`
(which does the exclusive-zone math). The real blockers were three separate
illumos nested-poll / socket gaps in the CLIENT pipeline that starved the panel's
layer surface of a buffer, so there were no pixels to stack in the first place:

1. **cosmic-applet-time was a stale binary built against an UNPATCHED
   wayland-client** (built Aug 23; the `wayland-client-0.31.14
   blocking_read` finite-timeout patch landed Aug 27). Its winit-wayland
   `registry_queue_init` roundtrip wedged in `poll(fd, INFINITE)`
   (`blocking_read`), so the applet never finished setup -> never rendered ->
   provided ZERO thickness to the panel.

2. **The panel's embedded applet server used a level-triggered calloop `Generic`
   FD source**, which does not fire on illumos (the same nested-poll readiness
   gap that breaks the wayland client blocking_read and smallvil's server
   dispatch). So even once the applet connected, its requests to the panel's
   nested server were never dispatched -> its registry roundtrip never completed.

3. **smallvil's `SecurityContextHandler::context_created` was a no-op that
   DROPPED the wp_security_context listener socket.** cosmic-panel hands each
   applet a privileged wayland socket (`X_PRIVILEGED_WAYLAND_SOCKET`) created via
   wp_security_context; libcosmic's applet token thread connects to it and does
   `registry_queue_init(&conn).unwrap()`. With the listener dropped, that connect
   got ECONNREFUSED (os error 146) and the applet PANICKED
   (`libcosmic/.../token/wayland_handler.rs:110`), exiting code 137.

The cascade: applet dead/starved -> panel's `layout_()` computes list thickness =
`2*padding + max(applet thickness)` = 8px (no applet) -> panel requests an 8px
layer -> the panel's own render gate (`render.rs:126`,
`dimensions.h <= 20 => return`) refuses to render -> the panel commits NO buffer
to its layer surface -> `layer.geometry()` stays 0x0 and
`render_elements_from_surface_tree` yields 0 elements -> nothing to composite.
(Diagnosed on-box: `SMALLVIL-COMMIT` fired but `SMALLVIL-LAYERBUF` never did =
layer commits carried no NewBuffer; `SMALLVIL-LAYER geo=0x0 elems=0`.)

## The fixes (all persisted to the fork rust-patches; pulled to the dev box)

### 1. smallvil -- accept the privileged applet socket + place toplevels below the panel
`smallvil-illumos-session-shell-protocols.patch` (now the authoritative combined
smallvil patch -- it also subsumes the former `smallvil-illumos-timer-dispatch`
and `smallvil-illumos-cascade-toplevels` patches, which are removed to avoid a
double-apply).

New in this patch beyond the prior session-shell work:
- `state.rs`: store the calloop `LoopHandle<'static, Smallvil>` on the state
  (needed to register the security-context listener); `new()` /
  `init_wayland_listener()` take `&mut EventLoop<'static, Self>`.
- `handlers/mod.rs`: `SecurityContextHandler::context_created` now INSERTS the
  `SecurityContextListenerSource` into the event loop and `insert_client`s each
  incoming privileged stream (was a no-op drop). This is the fix that stops the
  applet's ECONNREFUSED panic.
- `handlers/xdg_shell.rs`: `new_toplevel` maps windows at
  `layer_map_for_output(o).non_exclusive_zone().loc + cascade` so app windows
  start below the panel's exclusive strip instead of under the bar.
- (Retained) TOP-layer surfaces rendered as `custom_elements` (above toplevels),
  `arrange()` + initial `send_configure()` on layer commit, per-frame layer frame
  callbacks, and the 4ms server dispatch+flush Timer.

### 2. cosmic-panel -- drive the embedded applet server off a Timer on illumos
`cosmic-panel-illumos-embedded-server-timer-dispatch.patch`
(`xdg_shell_wrapper/mod.rs`). On illumos/solaris, replace the level-triggered
`Generic` embedded-server source with a 4ms `Timer` that calls
`dispatch_clients` + `flush_clients` unconditionally (mirrors the smallvil and
calloop-wayland-source Timer fixes). Non-illumos keeps the Generic source.

### 3. wayland-client blocking_read finite timeout for the other crate versions
`wayland-client-0.31.11-illumos-blocking-read-timeout.patch` and
`wayland-client-0.31.15-illumos-blocking-read-timeout.patch` -- the same
8ms-timeout + read-unconditionally fix already carried for 0.31.14, applied to the
two sibling versions present in the cargo home (so any app/applet resolving those
versions is covered).

### 4. The decisive operational step: REBUILD cosmic-applet-time
The applet binary was rebuilt against the (already-patched) wayland-client 0.31.14
(`cargo clean -p wayland-client` + `cargo build -p cosmic-applet-time`). This is
what let its winit registry roundtrip complete. The stale Aug-23 binary was the
proximate cause; the source was already correct.

## Verification (on the box, RUST_LOG=info)
- applet log: `SCTK setup complete`, then stays alive (no ECONNREFUSED / no panic).
- smallvil (instrumented during bring-up): layer `anchor=TOP|LEFT|RIGHT
  req_size h:32 excl=Exclusive(32) arranged_geo=1280x32`, and the layer render
  element count went 0 -> **1** (the panel's shm buffer is imported and drawn).
- panel grew from its 8px minimum to 32px, clearing its own 20px render gate.
- VNC: panel bar with live clock at top + app windows below; two captures 30s
  apart are byte-identical (steady).

## Session left running (maintainer VNC target)
Xorg:99 + patched smallvil + D-Bus session bus + cosmic-notifications +
cosmic-panel (+ cosmic-applet-time) + cosmic-term + cosmic-files + x11vnc on
127.0.0.1:5900 (SG untouched). NOT restarted at the end -- the maintainer sees the
real steady desktop.

## Fork changes (orchestrator to commit)
- `pkgs/os-specific/illumos/rust-patches/smallvil-illumos-session-shell-protocols.patch`
  (combined/authoritative smallvil patch; supersedes + replaces the removed
  `smallvil-illumos-timer-dispatch.patch` and `smallvil-illumos-cascade-toplevels.patch`).
- `pkgs/os-specific/illumos/rust-patches/cosmic-panel-illumos-embedded-server-timer-dispatch.patch` (NEW).
- `pkgs/os-specific/illumos/rust-patches/wayland-client-0.31.11-illumos-blocking-read-timeout.patch` (NEW).
- `pkgs/os-specific/illumos/rust-patches/wayland-client-0.31.15-illumos-blocking-read-timeout.patch` (NEW).
- `artifacts/cosmic-full-shell.png` (NEW) -- the steady VNC frame (panel bar + apps).
- Operational note for the app build recipe: cosmic-applet-time (and any
  winit-wayland applet) must be rebuilt against the patched wayland-client, else
  it wedges in its startup roundtrip.
