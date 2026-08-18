# Mesa Wayland-EGL for x86_64-illumos -- STATUS

## Result summary
- Mesa built with `-Dplatforms=wayland`: **YES** (Mesa 25.1.4, gallium softpipe+llvmpipe, LLVM 20.1.8).
- libEGL advertises `EGL_KHR_platform_wayland` + `EGL_EXT_platform_wayland`: **YES**
  (client-extension string + runtime `eglGetPlatformDisplayEXT` probe both confirm).
- cosmic-panel gets an EGL context on smallvil: **YES**
  (`Successfully selected EGL platform: PLATFORM_WAYLAND_KHR`, EGL 1.5, GLES2 on
  `llvmpipe (LLVM 20.1.8)` / `OpenGL ES 3.2 Mesa 25.1.4`; smallvil maps the panel's
  layer surface `ns="Panel" layer=Top`).
- Visible pixel proof: **YES** via the wlr-layer-shell test bar (`wllayer`,
  `ns="solnix-panel-test"`), a 1280x48 top-anchored bar composited by smallvil
  (screenshot shows the bar band with COSMIC-blue content over the desktop bg).

## The blocker that was fixed
OpenIndiana Mesa 21.3.9 libEGL was built WITHOUT the Wayland EGL platform, so
cosmic-panel died at `Unable to find suitable EGL platform / Missing:
EGL_KHR_platform_wayland`. The fix is the build-option gap: `-Dplatforms=wayland`
(Mesa 25.x folded the old `-Degl-platforms` into `-Dplatforms`) plus the
wayland-client / wayland-egl-backend / wayland-scanner build deps, using the
nix-pure wayland-1.26.0 so the produced libEGL is soname/ABI-matched to the
desktop node's wayland.

## Build (build node fred v3, 3.135.239.78)
- Source: `/var/tmp/mesa-25.1.4`, build dir `_bwl`, install `/var/tmp/mesa-waylandegl-out`.
- Recipe: `/root/build-mesa-waylandegl.sh` (run as-is; version arg default 25.1.4).
- Toolchain: gcc 14 (`/usr/gcc/14`), meson/ninja in `/root/mesa-venv`, llvm-config 20.
- Key flags: `-Dgallium-drivers=softpipe,llvmpipe -Dvulkan-drivers= -Dllvm=enabled
  -Degl=enabled -Dgbm=enabled -Dgles2=enabled -Dopengl=true -Dshared-glapi=enabled
  -Dplatforms=wayland -Degl-native-platform=surfaceless -Dglx=disabled
  -Dvideo-codecs= -Dzstd=disabled`.
- wayland deps (nix store on build node):
  - `xzzwk5gs...-wayland-1.26.0-dev` (headers incl. wayland-egl-backend.h)
  - `wbs749x2...-wayland-1.26.0` (libwayland-client/server .so.0)
  - `4qvib09k...-wayland-scanner-1.26.0-bin`
  - `ngi8lkkp...-wayland-protocols-1.49`
- libdrm: `/var/tmp/libdrm-out` (the RADV core libdrm), via a pkg-config prefix shim.

## illumos Mesa fixes reused (the C-PVR/RADV set)
1. `src/util/u_atomic.h` : `#if defined(__sun)` -> `&& !defined(__GNUC__)` (gcc has intrinsics).
2. `src/util/u_thread.c` : add `!defined(__sun)` to the sched-getaffinity allowlist.
3. `src/util/macros.h`   : `#include <alloca.h>` under `__sun`.
4. `src/util/disk_cache_os.c` : `getpwuid_r` is 4-arg on SunOS.
5. `include/drm-uapi/drm.h` + `src/util/libsync.h` : force Linux `_IOC` encoding via
   `linux-ioctl-compat.h` shim (same as RADV/powervr) so DRM ioctl macros match.

## The NEW illumos break fixed this run (the actual blocker to completion)
The prior agent's meson setup + ninja got all the way to linking libEGL / libGLESv2
/ dri_gbm, then failed:
    ld: fatal: symbol referencing errors  (libEGL.so.1.0.0)
    ld: warning: file libLLVM.so.20.1: required by libgallium-25.1.4.so, not found
    Undefined: <220 LLVM symbols>, all first-referenced in libgallium-25.1.4.so
Root cause: `libgallium-25.1.4.so` has `NEEDED libLLVM.so.20.1`. When the Solaris
link-editor links the dependent shared objects (libEGL/libGLESv2/dri_gbm) with
`-z defs`, it must resolve gallium's NEEDED transitively, but `/usr/clang/20/lib`
was not on the link-time search path for those targets (meson emitted only
`-L/var/tmp/libdrm-out/lib -L/usr/lib/xorg/amd64` + RPATHs, no `-L` for LLVM).
Fix: add `/usr/clang/20/lib` to `LD_LIBRARY_PATH` for the ninja invocation -- the
Solaris `ld` searches `LD_LIBRARY_PATH` for shared-object dependencies at link
time. One-line change in `build-mesa-waylandegl.sh` (LD_LIBRARY_PATH line).
With that, the full build + install completed.

## Built libs (build node /var/tmp/mesa-waylandegl-out/lib)
    libEGL.so.1.0.0        (2.2M) -- advertises EGL_KHR/EXT_platform_wayland
    libGLESv2.so.2.0.0     (89K)
    libgbm.so.1.0.0        (154K) + gbm/dri_gbm.so
    libgallium-25.1.4.so   (22M, softpipe+llvmpipe megadriver, NEEDED libLLVM.so.20.1)
EGL/GLESv2 headers in .../include.

## Render (desktop node solnix, 18.117.248.120)
- Shipped Mesa: `/var/tmp/mesa-wl/lib` (the 4 libs + runtime deps libLLVM.so.20.1,
  libstdc++.so.6, libgcc_s.so.1, libffi.so.8). Soname-resolves cleanly against the
  desktop's own nix wayland `9paxj153...-wayland-1.26.0` (ldd: no "not found").
- Session: `/root/solnix-cosmic-session.sh -c /bin/true` -> Xvfb :99 + smallvil
  (wayland-1) + x11vnc 127.0.0.1:5900.
- Panel launcher: `/root/run-panel-newmesa.sh` (LD_LIBRARY_PATH = new Mesa first,
  WAYLAND_DISPLAY=wayland-1, GDK_BACKEND=wayland, LIBGL_ALWAYS_SOFTWARE=1,
  GALLIUM_DRIVER=llvmpipe, EGL_PLATFORM=wayland).
- Panel log `/root/cosmic-panel-newmesa.log`: selects PLATFORM_WAYLAND_KHR, EGL 1.5,
  GLES2 context on Mesa 25.1.4 llvmpipe; smallvil maps its layer surface. The panel
  paints no persistent bar (no applets / no live configure-frame loop in this nested
  setup) -- render path proven, but the bare COSMIC panel draws an empty surface.
- Visible-pixel proof: `/root/wllayer` (wlr-layer-shell test bar) rendered a
  1280x48 top-anchored bar that smallvil composited. Screenshots:
    /root/panel-newmesa.ppm  (panel run; uniform bg -- panel surface empty)
    /root/layerbar.ppm       (layer bar; 1280x48 bar band, COSMIC-blue content)

## Pixel-complete COSMIC shell verdict
The EGL wall -- THE blocker -- is gone: Mesa 25.1.4 libEGL with the Wayland EGL
platform lets cosmic-panel obtain a GLES2/EGL context on the nix-pure smallvil
compositor over the wayland-1 socket, and smallvil composits layer-shell clients
to visible pixels (proven by the layer test bar). cosmic-panel itself needs its
applet/config/frame loop wired up to paint a persistent visible bar; that is a
panel-side task beyond the Mesa/EGL deliverable, which is complete.
