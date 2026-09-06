# solnix connectable COSMIC desktop — honest status

> **⚠️ STALE CLOUD IDENTIFIERS.** Every AWS instance/AMI/snapshot id below belongs to a
> CLOSED account (chiuso / mala / lala) and no longer resolves. The findings, root causes
> and recipes here remain valid — only the ids are dead. Current substrate ids live in the
> gitignored `.infra/`; the rebuild paths are `docs/base-ami-rebuild-runbook.md` (x86_64,
> from the public OI cloudimage) and `docs/aarch64-buildhost-runbook.md` (the aarch64 gate
> host). See `docs/durability-account-loss.md` for why this keeps happening and the rules
> that limit the damage.

## What's REAL and verified (deterministic)
A connectable solnix Wayland desktop on x86_64-illumos, on the 10/10-reliable base
(ami-08028a88f6e53ff49, PIT-hang fixed). VNC-verified end-to-end:
- RFB 003.008 handshake on 127.0.0.1:5900, ServerInit 1280x800 on Xorg :99.
- **smallvil (smithay SW compositor, Mesa softpipe GLES2) composites a wl_shm client** — four
  colour bands + white box + cursor, real pixels over VNC (artifacts/solnix-smallvil-wlshm-paint.png).
  This is the DETERMINISTIC proof: a raw wl_shm client paints reliably every time.
- The full COSMIC stack is on the box (cosmic-term/files/settings/launcher/session/panel + applets +
  smallvil), the built store on nixpool (4654 paths), VNC 127.0.0.1-bound (SSH-tunnel access only).

Connect:
  ssh -N -L 5900:127.0.0.1:5900 root@<ip>
  vncviewer localhost:5900

## RESOLVED: cosmic-term now paints RELIABLY (the client-dispatch fix)
cosmic-term (and every iced/libcosmic GUI app) now reaches a STEADY visible paint under smallvil on illumos.
Verified byte-identical VNC captures across t0/+30s/poke/+60s (agent) + independently re-verified across time
(orchestrator, matching md5 628cd67b) — the full COSMIC terminal (File/Edit/View + New terminal + tab +
cursor). NOT a lucky one-off this time.

The earlier black frames were the illumos wayland-CLIENT dispatch stall: illumos nested-epoll readiness
doesn't propagate -> calloop's Generic FD source (wrapping the wayland conn FD in calloop-wayland-source's
WaylandSource) never fires -> the client never pumps its wayland queue -> no frame -> black. FIXED by
calloop-wayland-source-illumos-timer-dispatch.patch (the direct client-side analog of the smallvil server-
side Timer fix): an 8ms calloop Timer sub-source pumps the queue unconditionally (TimerWheel is polled by the
loop core, not epoll). THE single highest-leverage patch — fixes every iced/winit COSMIC app at once (all
route through sctk's WaylandSource). The desktop is now USABLE, not just connectable.

Still to do: rebuild the OTHER COSMIC apps (files/settings/panel) against the patched
calloop-wayland-source so they paint too (cosmic-term is rebuilt + proven).

## Launcher / auto-start (scripts/solnix-cosmic-session-node.sh, on the node + in repo)
Xorg:99-dummy + smallvil (softpipe) + a Wayland client + x11vnc(127.0.0.1:5900). Two illumos-vs-GNU gotchas
fixed in the launcher: (1) illumos `env` has NO `-u` (use a subshell `unset WAYLAND_DISPLAY; exec x11vnc`);
(2) x11vnc EXITS if WAYLAND_DISPLAY is in its env ("Wayland display server detected ... Exiting") — it's an
X11 tool serving :99. Auto-start hook: /etc/rc2.d/S99solnix-cosmic + nixpool cachefile (survives reboot;
the 10/10 AMI reboots reliably, nixpool auto-imports).

## gburd@solnix activation gap (mkHome needs the solnix overlay)
lib/helpers.nix mkHome uses `inputs.nixpkgs.legacyPackages.${platform}` — stock nixpkgs has NO
`x86_64-solaris` (verified: builtins.hasAttr == false), so `gburd@solnix` can't resolve packages. FIX:
  pkgs = import inputs.nixpkgs {
    system = "x86_64-solaris";
    overlays = [ inputs.solnix.overlays.default ];   # the nixpkgs-illumos overlay
    config.allowUnsupportedSystem = true;
  };
(needs solnix added as a nix-config flake input exposing overlays.default). A gburd user was created
manually on the box; full home-manager activation awaits this mkHome change.

## The path to a genuinely usable desktop (in order)
1. The iced/winit illumos wayland-client dispatch fix (so cosmic-term + every COSMIC app paints reliably) —
   THE desktop-quality blocker.
2. Deterministic auto-start paint -> bake a reproducible desktop AMI.
3. Wire the solnix overlay into mkHome -> gburd@solnix activates the real config.
4. cosmic-greeter (Solaris-PAM port) for the login-manager parity.

## Multi-app full-desktop: NOT yet reliably painting (honest)
The client-dispatch fix reliably paints a LONE cosmic-term (proven, steady, re-verified). But a MULTI-APP
session (cosmic-panel + cosmic-term + cosmic-files together, all rebuilt against the dispatch patch) does
NOT reliably composite -- the framebuffer is black despite all procs running + VNC listening. The apps
BUILT fine (panel/files/launcher/notifications rebuilt OK; settings/bg blocked by a dav1d-sys native-lib,
unrelated). The gap is session-composition reliability (start-ordering / layer-shell panel + app interaction
/ a mixed old-new proc state from repeated restarts), NOT the per-app dispatch (that's fixed).
STATUS: single COSMIC app paints reliably; the full panel+apps desktop needs a clean, ordered session
bring-up + per-app paint re-verification. Deferred as desktop-polish (below the higher-priority build-farm +
aarch64-native goals). The reliable-boot + connectable-VNC + single-app-paint wins stand.

## Multi-app: RESOLVED to the precise boundary (cosmic-term paints; cosmic-panel needs a fuller session)
Re-verified: cosmic-term paints STEADILY in the multi-app session too (8497B byte-identical VNC captures
across 25s -- the client-dispatch fix holds for normal COSMIC apps). The multi-app "black" was NOT a
compositor/dispatch regression -- it was cosmic-PANEL crashing (the panel process ran but exited, so nothing
new to composite; a lone painting cosmic-term remained).

cosmic-panel's EXACT failure (its own log): it EXITS on missing SESSION SERVICES, not a paint/dispatch bug:
  - "failed to create workspaces dbus proxy: No such file or directory" (no D-Bus session bus / no
    cosmic-workspaces service)
  - "Failed to connect to the notifications daemon"
  - "Failed to initialize fractional scaling manager: NotPresent"  (wp_fractional_scale protocol not in smallvil)
  - "Failed to initialize security context manager: NotPresent"    (wp_security_context protocol not in smallvil)
cosmic-panel is the desktop SHELL BAR -- it expects a full COSMIC session: a D-Bus session bus + companion
daemons (cosmic-workspaces, cosmic-notifications) + richer wayland protocols (fractional-scale,
security-context) that the minimal smallvil compositor doesn't advertise. This is a SESSION-INTEGRATION gap,
distinct from (and beyond) the per-app client-dispatch fix.

## Honest desktop state (final for now)
- COSMIC *apps* (cosmic-term, and by the same fix cosmic-files/edit/etc.) PAINT reliably + steady on illumos.
- The COSMIC *shell* (cosmic-panel) needs a fuller session substrate to render: D-Bus session bus + the
  companion daemons + the fractional-scale/security-context wayland protocols added to smallvil (or a real
  cosmic-comp, which is itself a rewrite on illumos -- see cosmic-comp-illumos-finding.md).
- So: "a connectable box running COSMIC apps" = DONE + reliable. "The full pop!_OS COSMIC shell (panel +
  workspaces + notifications)" = needs the session-service + wayland-protocol layer (the next desktop phase,
  below the build-farm/aarch64/GPU priorities).

## RESOLVED: the session-service layer is built; the panel-render wall is now a Mesa EGL gap
The session-service + wayland-protocol layer cosmic-panel needs has been PROVIDED and verified, and the
panel now runs its full init on it. The remaining blocker is NOT a missing service/protocol -- it is a Mesa
build-config gap. What was done (patches in pkgs/os-specific/illumos/rust-patches/):
- **D-Bus session bus** (`dbus-daemon` 1.16.2 is on the box): starts cleanly; clearing the panel's
  "workspaces dbus proxy: No such file" (that error was the BUS being absent -- with the bus the proxy
  succeeds-as-absent; cosmic-workspaces need not be built). cosmic-notifications runs (does not claim its
  D-Bus name here, so "connect to notifications daemon" still logs, but NON-FATALLY).
- **smallvil-illumos-session-shell-protocols.patch**: adds FOUR globals + handlers to the smithay-fork
  smallvil (one blanket `delegate_dispatch2!` wires dispatch): `zwlr_layer_shell_v1` (the panel bar IS a
  layer surface -- smallvil advertised none; also added LayerMap arrange/configure at commit + rendering
  layer surfaces as custom_elements in the winit loop, which stock smallvil never did), `wp_fractional_scale`,
  `wp_security_context`, `wp_viewporter`. Clears ALL of: fractional NotPresent, security NotPresent,
  viewporter NotPresent.
- **wayland-client-0.31.14-illumos-blocking-read-timeout.patch**: the panel's synchronous startup
  `Connection::roundtrip -> blocking_read -> poll(fd, INFINITE)` wedged on the same illumos nested-poll
  readiness gap the calloop-wayland-source Timer patch fixes for the async path. Poll with an 8ms timeout +
  read unconditionally. (Also: launch smallvil with WAYLAND_DISPLAY UNSET so its winit uses X11, not a
  nested wayland client that hits the identical infinite-roundtrip hang.)
- After all of it, cosmic-panel connects, binds globals, spawns applets, then EXITS on the sole FATAL:
  **"Unable to find suitable EGL platform" -- missing `EGL_KHR/EXT_platform_wayland`**. The system illumos
  Mesa 21.3.9 (`/usr/lib/GL/amd64/libEGL`) has `platform_x11`/`gbm`/`surfaceless` but NOT wayland. The
  panel's `xdg_shell_wrapper` is a GL nested compositor (`egl_context().make_current_with_surface` +
  GlesRenderer per layer) -- it hard-requires an EGL wayland platform; no tiny-skia/SW path like iced apps.
- NEXT (the precise blocker): build illumos Mesa WITH the wayland EGL platform enabled (or rework the panel
  wrapper to a surfaceless/pbuffer GL + wl_shm software-upload path). This is a Mesa-packaging task, distinct
  from the (now-complete) session-service + wayland-protocol layer.
