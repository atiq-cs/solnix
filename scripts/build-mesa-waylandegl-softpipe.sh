#!/bin/sh
# build-mesa-waylandegl-softpipe.sh -- Mesa 25.1.4 for x86_64-illumos WITH the
# Wayland EGL platform, softpipe-only (NO LLVM -> no llvmpipe).
#
# THE BLOCKER this clears: OpenIndiana's system Mesa 21.3.9 libEGL
# (/usr/lib/GL/amd64/libEGL.so.1) was built WITHOUT the wayland EGL platform
# (only x11/gbm/surfaceless/device_software), so it lacks
# EGL_KHR_platform_wayland / EGL_EXT_platform_wayland. cosmic-panel's
# xdg_shell_wrapper renders each layer via a REAL GLES2 context bound to the
# wayland display (GlesRenderer / make_current_with_surface) -- no software
# path -- so it dies at "Unable to find suitable EGL platform".
#
# The panel needs the EGL WAYLAND PLATFORM entry point + GLES2, NOT GPU accel,
# so softpipe (a pure-C swrast gallium driver) suffices and drops the entire
# LLVM dependency (no clang-20 / no libLLVM.so soname-search fight). The built
# libEGL advertises EGL_KHR_platform_wayland + EGL_EXT_platform_wayland; the
# panel log then shows "Successfully selected EGL platform:
# PLATFORM_WAYLAND_KHR" -> EGL 1.5 -> GLES2 renderer "softpipe" on
# "OpenGL ES 3.1 Mesa 25.1.4".
#
# Node prerequisites (10/10 desktop AMI):
#   - gcc 14 at /usr/gcc/14
#   - meson + ninja:  pkg install developer/build/meson developer/build/ninja
#   - PyYAML:         python3 -m ensurepip && python3 -m pip install PyYAML
#   - system libdrm 2.4.109 (/usr/lib/xorg/amd64/libdrm.so.2, /usr/include/libdrm)
#   - nix-pure wayland-1.26.0 store paths (below)
#   - the RADV/powervr Linux-ioctl shim copied to $SHIM
#     (src/drm-port/anv/linux-ioctl-compat.h in the fork)
#
# Build under /nix (root slice is small); source: /nix/mesabuild/mesa-25.1.4.
# Install: /nix/mesabuild/mesa-waylandegl-out; ship dir: /nix/mesabuild/mesa-wl.
#
# Reuses the C-PVR/RADV illumos Mesa fixes:
#   1. u_atomic.h      : #if defined(__sun) -> && !defined(__GNUC__) (gcc has intrinsics)
#   2. u_thread.c      : add !defined(__sun) to the sched-getaffinity allowlist
#   3. macros.h        : #include <alloca.h> under __sun
#   4. disk_cache_os.c : getpwuid_r is 4-arg on SunOS
#   5. drm.h/libsync.h : force Linux _IOC encoding via linux-ioctl-compat.h
# Plus one build-flag fix unique to this node: system libdrm ships no bare
# <drm.h> (xf86drm.h includes it), so -I<src>/include/drm-uapi resolves it to
# Mesa's bundled uapi header (which also carries the ioctl shim). This MUST be
# passed via -Dc_args / -Dcpp_args (meson ignores CFLAGS env on reconfigure).
set -u
export PATH="/usr/gnu/bin:/usr/bin:$PATH"
MESON=/usr/bin/meson
NINJA=/usr/bin/ninja
GCC=/usr/gcc/14; CC="$GCC/bin/gcc"; CXX="$GCC/bin/g++"; export CC CXX

ver="25.1.4"
sd="/nix/mesabuild/mesa-$ver"
[ -d "$sd" ] || { echo "RESULT FAIL no-srcdir ($sd)"; exit 1; }

# nix-pure wayland toolkit (desktop-node store paths)
WLDEV=/nix/store/2kdv0plxa54k85a76pxyvrjs2f5ky0nv-wayland-1.26.0-dev
WLLIB=/nix/store/jp5g7biz7c2bsqz48awsd5qwa9asig73-wayland-1.26.0
WLSCAN=/nix/store/66v6c2320v3bpv2ay4y3fnp0lbnnbrfq-wayland-scanner-1.26.0-bin
WLSCANDEV=/nix/store/4pqi40rnfxykrkxg40y6rj9syayqgxbg-wayland-scanner-1.26.0-dev
WLPROTO=/nix/store/df4cnm5vwxqkczpzisrn47scvpzc38fb-wayland-protocols-1.49

export PKG_CONFIG_PATH="$WLDEV/lib/pkgconfig:$WLSCANDEV/lib/pkgconfig:$WLPROTO/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$WLDEV/lib/pkgconfig:$WLSCANDEV/lib/pkgconfig:$WLPROTO/share/pkgconfig:/usr/lib/amd64/pkgconfig:/usr/lib/pkgconfig"
export LD_LIBRARY_PATH="$GCC/lib/amd64:$GCC/lib:$WLLIB/lib:${LD_LIBRARY_PATH:-}"

export CFLAGS="-m64 -fPIC -O2 -D__EXTENSIONS__ -D_POSIX_PTHREAD_SEMANTICS -Wno-error=incompatible-pointer-types -I/usr/include/libdrm -I/usr/include/drm -I$sd/include/drm-uapi"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-I/usr/include/libdrm -I/usr/include/drm -I$sd/include/drm-uapi"
export LDFLAGS="-m64 -L/usr/lib/xorg/amd64 -R/usr/lib/xorg/amd64 -R$WLLIB/lib -lsocket -lnsl"

# --- Mesa-wide illumos fixes (idempotent) ---
UA="$sd/src/util/u_atomic.h"
grep -q "!defined(__GNUC__)" "$UA" 2>/dev/null || \
  sed -i 's/^#if defined(__sun)$/#if defined(__sun) \&\& !defined(__GNUC__)/' "$UA" 2>/dev/null || true
UT="$sd/src/util/u_thread.c"
sed -i 's/!defined(__HAIKU__) \&\& !defined(__managarm__)/!defined(__HAIKU__) \&\& !defined(__managarm__) \&\& !defined(__sun)/' "$UT" 2>/dev/null || true
MAC="$sd/src/util/macros.h"
if [ -f "$MAC" ] && ! grep -q alloca.h "$MAC"; then
  sed -i 's|#include <stdio.h>|#include <stdio.h>\n#ifdef __sun\n#include <alloca.h>\n#endif|' "$MAC" 2>/dev/null || true
fi
DCO="$sd/src/util/disk_cache_os.c"
if [ -f "$DCO" ] && ! grep -q "4-arg SunOS" "$DCO"; then
  python3 - "$DCO" <<'PYX'
import sys
p=sys.argv[1]; s=open(p).read()
old="         getpwuid_r(getuid(), &pwd, buf, buf_size, &result);\n"
new=("#ifdef __sun\n         result = getpwuid_r(getuid(), &pwd, buf, buf_size); /* 4-arg SunOS */\n"
     "#else\n         getpwuid_r(getuid(), &pwd, buf, buf_size, &result);\n#endif\n")
open(p,"w").write(s.replace(old,new,1)) if old in s else None
PYX
fi

# load-bearing ioctl fix (== RADV/powervr): force Linux _IOC encoding via the shim.
SHIM=/nix/mesabuild/linux-ioctl-compat.h   # copy of src/drm-port/anv/linux-ioctl-compat.h
DUH="$sd/include/drm-uapi/drm.h"
if [ -f "$SHIM" ] && [ -f "$DUH" ] && ! grep -q linux-ioctl-compat "$DUH"; then
  cp "$SHIM" "$sd/include/drm-uapi/linux-ioctl-compat.h"
  sed -i 's|#include <sys/ioccom.h>|#include <sys/ioccom.h>\n#include "linux-ioctl-compat.h"|' "$DUH" 2>/dev/null || true
fi
LS="$sd/src/util/libsync.h"
if [ -f "$SHIM" ] && [ -f "$LS" ] && ! grep -q linux-ioctl-compat "$LS"; then
  cp "$SHIM" "$sd/src/util/linux-ioctl-compat.h"
  sed -i 's|#include <sys/ioctl.h>|#include <sys/ioctl.h>\n#ifdef __sun\n#include "linux-ioctl-compat.h"\n#endif|' "$LS" 2>/dev/null || true
fi

out="/nix/mesabuild/mesa-waylandegl-out"; mkdir -p "$out"
cat > /nix/mesabuild/native-wl.ini <<INI
[binaries]
c = '$CC'
cpp = '$CXX'
pkgconfig = '/usr/bin/pkg-config'
wayland-scanner = '$WLSCAN/bin/wayland-scanner'
INI

log="/nix/mesabuild/mesa-wl.build.log"
(
cd "$sd"
[ -d _bwl ] && MSA="--reconfigure" || MSA=""
"$MESON" setup _bwl $MSA --prefix="$out" --libdir=lib --buildtype=release \
  --wrap-mode=nodownload \
  --native-file /nix/mesabuild/native-wl.ini \
  -Dc_args="-Wno-error=incompatible-pointer-types -Wno-error=pointer-sign -I$sd/include/drm-uapi" \
  -Dcpp_args="-Wno-error=incompatible-pointer-types -I$sd/include/drm-uapi" \
  -Dgallium-drivers=softpipe \
  -Dvulkan-drivers= \
  -Dllvm=disabled \
  -Degl=enabled \
  -Dgbm=enabled \
  -Dgles1=disabled -Dgles2=enabled -Dopengl=true \
  -Dshared-glapi=enabled \
  -Dplatforms=wayland \
  -Degl-native-platform=surfaceless \
  -Dglx=disabled \
  -Dvideo-codecs= -Dzstd=disabled \
&& "$NINJA" -C _bwl -j"$(psrinfo | wc -l | tr -d ' ')" \
&& "$NINJA" -C _bwl install
) >"$log" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  echo "RESULT FAIL build (rc=$rc)"
  grep -nE "FAILED:| error:|fatal error|not found|Dependency|Program|Run-time|ERROR|meson.build|required|undefined|Undefined|ld:" "$log" | tail -50 | sed 's/^/  /'
  echo "  --- log: $log ---"; exit 1
fi
echo "RESULT OK $out"
ls -la "$out"/lib/libEGL* "$out"/lib/libGLESv2* "$out"/lib/libgbm* 2>/dev/null

# Verify the wayland EGL platform is advertised.
echo "=== platform_wayland extensions in libEGL ==="
strings "$out"/lib/libEGL.so.1.0.0 | grep -oE 'EGL_(KHR|EXT)_platform_wayland' | sort -u

# Stage a ship dir with the megadriver + gbm loader alongside libEGL/libGLESv2.
SHIP=/nix/mesabuild/mesa-wl
mkdir -p "$SHIP/lib"
/usr/gnu/bin/cp -a "$out"/lib/libEGL.so* "$out"/lib/libGLESv2.so* "$out"/lib/libgbm.so* \
  "$out"/lib/libgallium-25.1.4.so "$SHIP/lib/" 2>/dev/null
/usr/gnu/bin/cp -a "$out"/lib/gbm "$SHIP/lib/" 2>/dev/null
echo "=== shipped to $SHIP/lib ==="; ls "$SHIP/lib/"
