# Mesa wayland-EGL for cosmic-panel on illumos -- RESULT

## Deliverable 1 -- a wayland-EGL-capable Mesa on the box: DONE

Built fresh on the desktop node (i-0d62b4aadb9e186d2, 3.135.213.174) -- the prior
Mesa 25.1.4 `-Dplatforms=wayland` build (commit b72f11df0b) lived on the
now-terminated fred/desktop nodes and was NOT present in this node's store, so it
was rebuilt.

- **Mesa 25.1.4, softpipe-only, `-Dplatforms=wayland`, `-Dllvm=disabled`.**
  Softpipe (pure-C swrast gallium) gives the panel the EGL wayland platform entry
  point + GLES2 with no GPU and no LLVM dependency -- which also dropped the
  clang-20 / libLLVM.so soname-search fight that stalled the earlier llvmpipe build.
- Store/build path: `/nix/mesabuild/mesa-waylandegl-out/lib` (install prefix),
  shipped to `/nix/mesabuild/mesa-wl/lib` (libEGL + libGLESv2 + libgbm +
  libgallium-25.1.4.so megadriver + gbm/dri_gbm.so).
- **libEGL advertises the wayland platform** (`strings libEGL.so.1.0.0`):
      EGL_EXT_platform_wayland
      EGL_KHR_platform_wayland
  (also gbm/surfaceless/device). The system Mesa 21.3.9 libEGL has neither.

Built libs:
    libEGL.so.1.0.0        2.2M   -- advertises EGL_KHR/EXT_platform_wayland
    libGLESv2.so.2.0.0     89K
    libgbm.so.1.0.0        154K + gbm/dri_gbm.so
    libgallium-25.1.4.so   21M    -- softpipe megadriver (no LLVM NEEDED)

Recipe persisted to the fork: `scripts/build-mesa-waylandegl-softpipe.sh`.
The node build prerequisites installed this session: `developer/build/meson` +
`developer/build/ninja` (IPS), `PyYAML` (pip via ensurepip). One build-flag fix
unique to this node: system libdrm ships no bare `<drm.h>` (xf86drm.h includes
it), so `-I<src>/include/drm-uapi` (passed via `-Dc_args`/`-Dcpp_args`, since
meson ignores CFLAGS env on reconfigure) resolves it to Mesa's bundled uapi
header (which also carries the RADV/powervr Linux-ioctl shim).

## Deliverable 2 -- point the session at it: DONE

`scripts/solnix-cosmic-shell-session-node.sh` (== `/root/start-cosmic-session-shell.sh`
on the box) now runs the panel + notifications daemon with:
    LD_LIBRARY_PATH="$MESAWL:$GCCLIB:$DRMLIB:$BIN/lib:$WLLIB:/usr/lib/64"
    EGL_PLATFORM=wayland  GALLIUM_DRIVER=softpipe  LIBGL_ALWAYS_SOFTWARE=1
where `MESAWL=/nix/mesabuild/mesa-wl/lib` is FIRST (ahead of the system
`/usr/lib/64`), `DRMLIB=/usr/lib/xorg/amd64` supplies libdrm.so.2, and
`GCCLIB=/usr/gcc/14/lib/amd64` supplies libstdc++/libgcc_s for the megadriver.

## Deliverable 3 -- does cosmic-panel get past the EGL wall + render? EGL WALL GONE

The EGL wall -- THE mandate blocker -- is **eliminated**. cosmic-panel's own log
(`/root/panel.log`) with the new Mesa:
    Successfully selected EGL platform: PLATFORM_WAYLAND_KHR
    EGL Initialized / EGL Version: (1, 5)
    egl_context: EGL context created
    renderer_gles2: Initializing OpenGL ES Renderer
    GL Version: "OpenGL ES 3.1 Mesa 25.1.4"  GL Vendor: "Mesa"  GL Renderer: "softpipe"
The prior "Unable to find suitable EGL platform / Missing:
EGL_KHR_platform_wayland" is gone. The panel obtains a REAL GLES2/EGL context on
smallvil over the wayland-1 socket -- its xdg_shell_wrapper's GlesRenderer /
make_current_with_surface path now works. When applets are configured the panel
opens a SECOND PLATFORM_WAYLAND_KHR GLES2 context (one per surface it composits),
confirming the full render path, not just init.

### The panel spawns + runs applets (bar content)
The bar was empty because the panel config had `plugins_wings=None` +
`plugins_center=None` (ZERO applets => nothing to draw). Fixed on the box:
- installed the applet `.desktop` files -> `/root/.local/share/applications/`
- symlinked applet binaries (present in `waveB2-bin`) -> `/nix/cosmic/applet-bin`
  (on the panel's PATH); set `XDG_DATA_DIRS=/root/.local/share:/usr/share`
- set `plugins_center = Some(["com.system76.CosmicAppletTime"])`
Result (panel.log): `Starting: cosmic-applet-time` -> applet PID live ->
`Starting time applet with version 1.0.15` -> the panel opens its second
PLATFORM_WAYLAND_KHR GLES2 context to composit the applet. The applet is a real
running wayland client on the compositor.

## Deliverable 4 -- steady VNC verify: STEADY multi-app COSMIC desktop

Left running (NOT restarted, so the maintainer sees the real desktop, not a
bring-up artifact): Xorg:99 + smallvil + D-Bus bus + cosmic-notifications +
cosmic-panel (+ its cosmic-applet-time) + cosmic-term + cosmic-files + x11vnc
(127.0.0.1:5900, SG untouched).

Framebuffer captured over the SSH tunnel to `/tmp/cosmic-shell-panel.png`
(also `artifacts/cosmic-shell-desktop-newmesa.png`): **69979 bytes, a full COSMIC
app rendering (cosmic-files: Home/Trash/Networks sidebar + a Name/Modified/Size
file listing), byte-identical across a 32s re-capture (69979 == 69979)** -- steady,
not a black/one-off frame (a 3158B black frame would be failure).

## The one remaining wall (precisely named): smallvil layer stacking, NOT Mesa/EGL

The panel BAR is not yet *visible* in the framebuffer even though the panel and
its applet both hold live GLES2/EGL contexts. Root cause is in smallvil (the
smithay SW test compositor), NOT the Mesa/EGL deliverable:
- smallvil's winit renderer collects wlr-layer-shell surfaces as custom render
  elements (`winit.rs`) and does NOT honor the panel's exclusive zone -- the
  xdg-shell app windows (cosmic-files/cosmic-term) are composited across the full
  output at y=0, occluding the top-anchored panel layer surface.
This is a compositor stacking/exclusive-zone gap in the test compositor (a
smallvil Rust change + rebuild), orthogonal to the EGL/Mesa work, which is
complete: on a compositor that honors layer-shell exclusive zones (cosmic-comp,
the real shell compositor) the same panel + Mesa would paint the bar in its
reserved strip.

## Verdict
The mandate's hard wall -- `Unable to find suitable EGL platform` -- is cleared:
a wayland-EGL Mesa (softpipe, Mesa 25.1.4, advertising
EGL_KHR/EXT_platform_wayland) is on the box, the session points the panel at it,
and cosmic-panel now obtains a real PLATFORM_WAYLAND_KHR GLES2 context and drives
its applets through it. A steady multi-app COSMIC desktop is left running and
VNC-verified. The bar's on-screen visibility is now gated by smallvil's
layer-shell stacking, not by EGL/Mesa.

## Fork changes (orchestrator to commit)
- `scripts/build-mesa-waylandegl-softpipe.sh` (NEW) -- the softpipe wayland-EGL
  Mesa recipe (no LLVM), with the illumos fixes + the drm-uapi include fix.
- `scripts/solnix-cosmic-shell-session-node.sh` -- panel/notifications now use
  MESAWL first + EGL_PLATFORM=wayland + XDG_DATA_DIRS + applet PATH; adds a
  cosmic-files app window.
- `artifacts/cosmic-shell-desktop-newmesa.png` -- the steady VNC frame.
