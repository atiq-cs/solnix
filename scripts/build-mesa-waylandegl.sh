#!/bin/sh
# build-mesa-waylandegl.sh -- rebuild Mesa for x86_64-illumos WITH the Wayland
# EGL platform, so cosmic-panel (a nested layer-shell compositor) can get an
# EGL context on the nix-pure smallvil Wayland compositor.
#
# The whole blocker: OpenIndiana's Mesa 21.3.9 libEGL was built WITHOUT the
# Wayland EGL platform (only x11/xcb/gbm/surfaceless), so client EGL lacks
# EGL_KHR_platform_wayland / EGL_EXT_platform_wayland. cosmic-panel dies at
# "Unable to find suitable EGL platform / Missing: EGL_KHR_platform_wayland".
# The fix is a build-option gap: -Dplatforms=wayland,x11 (Mesa 25.x folded the
# old -Degl-platforms into -Dplatforms) plus the wayland-client /
# wayland-egl-backend / wayland-scanner build deps.
#
# The wayland platform links libwayland-client + wayland-egl-backend: this build
# uses the SAME nix-pure wayland-1.26.0 the desktop node (smallvil + the panel)
# uses, imported into /nix/store here, so the produced libEGL is ABI-matched.
#
# Reuses this session's Mesa illumos fixes (the C-PVR / RADV set), the ones that
# apply to the gallium/EGL half rather than the vulkan/drm half:
#   1. u_atomic.h  : #if defined(__sun) -> && !defined(__GNUC__)  (gcc has intrinsics)
#   2. u_thread.c  : add !defined(__sun) to the sched-getaffinity allowlist
#   3. macros.h    : #include <alloca.h> under __sun
#   4. disk_cache_os.c : getpwuid_r is 4-arg on SunOS
set -u
export PATH="/root/mesa-venv/bin:/usr/gnu/bin:/usr/bin:$PATH"
MESON=/root/mesa-venv/bin/meson
NINJA=/root/mesa-venv/bin/ninja
GCC=/usr/gcc/14; CC="$GCC/bin/gcc"; CXX="$GCC/bin/g++"; export CC CXX

ver="${1:-25.1.4}"
sd="/var/tmp/mesa-$ver"
[ -d "$sd" ] || { echo "RESULT mesa-waylandegl FAIL no-srcdir ($sd)"; exit 1; }

# --- the nix-pure wayland toolkit (imported from the desktop node) ---
WLDEV=/nix/store/xzzwk5gs0ljyrfinbhp7acw3s74b7yz9-wayland-1.26.0-dev
WLLIB=/nix/store/wbs749x2qhivx35sl75r443gadh8hn3d-wayland-1.26.0
WLSCAN=/nix/store/4qvib09kn9ivgxbqhhnjvmjwk59k27ji-wayland-scanner-1.26.0-bin
WLPROTO=/nix/store/ngi8lkkps02plz7p2h4wvz7bi51ckiri-wayland-protocols-1.49
LLVMCFG=/usr/clang/20/bin/llvm-config
LIBDRM=/var/tmp/libdrm-out          # core libdrm (built for RADV) -- supplies drm.h + xf86drm.h + the ioctl shim

# pkg-config shim: expose the freshly-built core libdrm .pc with a rewritten prefix.
PCSHIM=$(mktemp -d /var/tmp/pcshim-wl.XXXXXX)
for pc in "$LIBDRM"/lib/pkgconfig/libdrm.pc; do
  [ -f "$pc" ] && sed -e "s|^prefix=.*|prefix=$LIBDRM|" "$pc" > "$PCSHIM/$(basename "$pc")"
done

# LLVM 20 runtime for llvmpipe: llvm-config on PATH so meson finds it.
export PATH="/usr/clang/20/bin:$PATH"
export PKG_CONFIG_PATH="$WLDEV/lib/pkgconfig:$WLPROTO/share/pkgconfig:$PCSHIM"
export PKG_CONFIG_LIBDIR="$WLDEV/lib/pkgconfig:$WLPROTO/share/pkgconfig:$PCSHIM:/usr/lib/amd64/pkgconfig:/usr/lib/pkgconfig"
export LD_LIBRARY_PATH="$GCC/lib/amd64:$GCC/lib:/usr/clang/20/lib:$WLLIB/lib:/nix/store/5rpqnrdy868id7bbnnbdz35drgr4yj5h-libffi-3.7.0/lib:${LD_LIBRARY_PATH:-}"

export CFLAGS="-m64 -fPIC -O2 -D__EXTENSIONS__ -D_POSIX_PTHREAD_SEMANTICS -Wno-error=incompatible-pointer-types -I$LIBDRM/include -I$LIBDRM/include/libdrm"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-I$LIBDRM/include -I$LIBDRM/include/libdrm"
export LDFLAGS="-m64 -L$LIBDRM/lib -R$LIBDRM/lib -L/usr/lib/xorg/amd64 -R/usr/lib/xorg/amd64 -R$WLLIB/lib -L/usr/clang/20/lib -R/usr/clang/20/lib -lsocket -lnsl"

# --- the Mesa-wide illumos fixes (idempotent) ---
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

# the load-bearing ioctl fix (== RADV/powervr): force the Linux _IOC encoding via the
# shim so any DRM ioctl macros match; illumos <sys/ioccom.h> would mis-encode.
SHIM=/root/drm-port/anv/linux-ioctl-compat.h
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

out="/var/tmp/mesa-waylandegl-out"; mkdir -p "$out"
cat > /var/tmp/native-waylandegl.ini <<INI
[binaries]
c = '$CC'
cpp = '$CXX'
pkgconfig = '/usr/bin/pkg-config'
llvm-config = '$LLVMCFG'
wayland-scanner = '$WLSCAN/bin/wayland-scanner'
INI

log="/var/tmp/mesa-waylandegl.build.log"
GALLIUM="${GALLIUM:-softpipe,llvmpipe}"
LLVMOPT="${LLVMOPT:-enabled}"
(
cd "$sd"
[ -d _bwl ] && MSA="--reconfigure" || MSA=""
"$MESON" setup _bwl $MSA --prefix="$out" --libdir=lib --buildtype=release \
  --wrap-mode=nodownload \
  --native-file /var/tmp/native-waylandegl.ini \
  -Dc_args="-Wno-error=incompatible-pointer-types -Wno-error=pointer-sign" \
  -Dcpp_args="-Wno-error=incompatible-pointer-types" \
  -Dgallium-drivers="$GALLIUM" \
  -Dvulkan-drivers= \
  -Dllvm="$LLVMOPT" \
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
  echo "RESULT mesa-waylandegl FAIL build (rc=$rc)"
  grep -nE "FAILED:| error:|fatal error|not found|Dependency|Program|Run-time|ERROR|meson.build|required|undefined|llvm|wayland" "$log" | tail -60 | sed 's/^/  /'
  echo "  --- log: $log ---"; exit 1
fi
echo "RESULT mesa-waylandegl OK $out"
echo "  libEGL:    $(ls "$out"/lib/libEGL* 2>/dev/null)"
echo "  libGLESv2: $(ls "$out"/lib/libGLESv2* 2>/dev/null)"
echo "  libgbm:    $(ls "$out"/lib/libgbm* 2>/dev/null)"
echo "  gallium:   $(ls "$out"/lib/dri/*.so "$out"/lib/gallium* 2>/dev/null)"
echo "  log:       $log"
