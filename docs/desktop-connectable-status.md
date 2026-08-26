# solnix connectable COSMIC desktop — honest status

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
