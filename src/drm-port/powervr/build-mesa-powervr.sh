#!/bin/sh
# build-mesa-powervr.sh -- PowerVR (Imagination's open Vulkan driver,
# src/imagination/vulkan, libvulkan_powervr_mesa.so) for illumos x86_64,
# COMPILE-phase, zero-phantom, against the C1 DRM / pvr ioctl surface. Fast
# follow-on to RADV/ANV/NVK: same Mesa 24.0.9 tree, same meson+ninja+gcc-14+
# glslang toolchain, the same 5 Mesa-wide illumos fixes + the same Linux _IOC
# ioctl shim.
#
# NO RUST / NO LLVM: PowerVR's shader compiler is "rogue" (src/imagination/
# rogue, ~18k LOC), NIR-based, pure C. Unlike NVK's NAK (Rust) it needs no
# rustc/cargo/bindgen/libclang -- the relief the task predicted.
#
# The powervr winsys (src/imagination/vulkan/winsys/powervr) talks DIRECTLY to
# the open pvr DRM kernel driver via drmIoctl(fd, DRM_IOCTL_PVR_*, ...) -- like
# ANV, NO libdrm_powervr module, just core libdrm + the drm-uapi/pvr_drm.h
# header (already in Mesa's include/drm-uapi). imagination-srv defaults false so
# the OPEN powervr winsys is selected (not the closed pvrsrvkm Services backend).
set -u
export PATH="/root/mesa-venv/bin:/usr/gnu/bin:/usr/bin:$PATH"
MESON=/root/mesa-venv/bin/meson
NINJA=/root/mesa-venv/bin/ninja
GCC=/usr/gcc/14; CC="$GCC/bin/gcc"; CXX="$GCC/bin/g++"; export CC CXX
export LD_LIBRARY_PATH="$GCC/lib/amd64:$GCC/lib:${LD_LIBRARY_PATH:-}"
NPROC=$(psrinfo | wc -l | tr -d ' ')
ver="${1:-24.0.9}"
LIBDRM=/var/tmp/libdrm-out          # core libdrm (built for RADV) -- pvr needs only this
SHIM=/root/drm-port/anv/linux-ioctl-compat.h   # the Linux _IOC shim (== RADV/ANV/NVK/C1)

sd="/var/tmp/mesa-$ver"
[ -d "$sd" ] || { echo "RESULT mesa-powervr FAIL no-srcdir ($sd)"; exit 1; }

# pkg-config shim: expose the freshly-built core libdrm .pc.
PCSHIM=$(mktemp -d /var/tmp/pcshim-pvr.XXXXXX)
for pc in "$LIBDRM"/lib/pkgconfig/libdrm.pc; do
  [ -f "$pc" ] && sed -e "s|^prefix=.*|prefix=$LIBDRM|" "$pc" > "$PCSHIM/$(basename "$pc")"
done
export PKG_CONFIG_PATH="$PCSHIM"
export PKG_CONFIG_LIBDIR="$PCSHIM"
export CFLAGS="-m64 -fPIC -O2 -D__EXTENSIONS__ -D_POSIX_PTHREAD_SEMANTICS -Wno-error=incompatible-pointer-types -I$LIBDRM/include -I$LIBDRM/include/libdrm"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-I$LIBDRM/include -I$LIBDRM/include/libdrm"
export LDFLAGS="-m64 -L$LIBDRM/lib -R$LIBDRM/lib -L/usr/lib/xorg/amd64 -R/usr/lib/xorg/amd64 -lsocket -lnsl"

# --- the 5 Mesa-wide illumos fixes (the RADV/ANV/NVK set, idempotent) ---
UA="$sd/src/util/u_atomic.h"
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
open(p,"w").write(s.replace(old,new,1))
PYX
fi

# --- the load-bearing ioctl fix: force the Linux _IOC encoding (not illumos
#     <sys/ioccom.h>) so DRM_IOCTL_PVR_* match the C-PVR-b kernel. Same shim. ---
DUH="$sd/include/drm-uapi/drm.h"
if [ -f "$DUH" ] && ! grep -q linux-ioctl-compat "$DUH"; then
  cp "$SHIM" "$sd/include/drm-uapi/linux-ioctl-compat.h"
  sed -i 's|#include <sys/ioccom.h>|#include <sys/ioccom.h>\n#include "linux-ioctl-compat.h"|' "$DUH" 2>/dev/null || true
fi
LS="$sd/src/util/libsync.h"
if [ -f "$LS" ] && ! grep -q linux-ioctl-compat "$LS"; then
  cp "$SHIM" "$sd/src/util/linux-ioctl-compat.h"
  sed -i 's|#include <sys/ioctl.h>|#include <sys/ioctl.h>\n#ifdef __sun\n#include "linux-ioctl-compat.h"\n#endif|' "$LS" 2>/dev/null || true
fi

# --- powervr-specific illumos fix: pvr_drm.h is the only drm-uapi header that
#     pulls <linux/const.h> (for _BITULL) + <linux/types.h> (for __u16/32/64,
#     __s32) AFTER "drm.h". On illumos drm.h's BSD branch already defines those
#     __sN/__uN types + (via the shim) the _BITULL family, so the linux headers
#     are absent and unneeded -- guard them for __sun. Always re-copy the shim
#     (it now carries _BITULL). ---
cp "$SHIM" "$sd/include/drm-uapi/linux-ioctl-compat.h"
PVRH="$sd/include/drm-uapi/pvr_drm.h"
if [ -f "$PVRH" ] && ! grep -q "__sun.*linux/const" "$PVRH" && ! grep -q "SOLNIX_PVR_LINUX_GUARD" "$PVRH"; then
  python3 - "$PVRH" <<'PYX'
import sys
p=sys.argv[1]; s=open(p).read()
old='#include "drm.h"\n\n#include <linux/const.h>\n#include <linux/types.h>\n'
new=('#include "drm.h"\n\n'
     '#ifdef __sun /* SOLNIX_PVR_LINUX_GUARD: drm.h BSD branch + shim supply these */\n'
     '#include "linux-ioctl-compat.h"\n'
     '#else\n'
     '#include <linux/const.h>\n#include <linux/types.h>\n'
     '#endif\n')
assert old in s, "pvr_drm.h include block not found"
open(p,"w").write(s.replace(old,new,1))
PYX
fi

out="/var/tmp/mesa-powervr-out"; mkdir -p "$out"
cat > /var/tmp/native-powervr.ini <<INI
[binaries]
c = '$CC'
cpp = '$CXX'
pkgconfig = '/usr/bin/pkg-config'
INI

log="/var/tmp/mesa-powervr.build.log"
(
cd "$sd"
[ -d _bpvr ] && MESON_SETUP_ARGS="--reconfigure" || MESON_SETUP_ARGS=""
"$MESON" setup _bpvr $MESON_SETUP_ARGS --prefix="$out" --libdir=lib --buildtype=release \
  --wrap-mode=nodownload \
  --native-file /var/tmp/native-powervr.ini \
  -Dgallium-drivers=swrast \
  -Dc_args="-Wno-error=incompatible-pointer-types -Wno-error=pointer-sign" \
  -Dcpp_args="-Wno-error=incompatible-pointer-types" \
  -Dvulkan-drivers=imagination-experimental \
  -Dimagination-srv=false \
  -Dvideo-codecs= \
  -Dplatforms= \
  -Dllvm=disabled \
  -Dosmesa=false \
  -Dglx=disabled -Degl=disabled -Dgbm=disabled -Ddri3=disabled \
  -Dgles1=disabled -Dgles2=disabled -Dopengl=true \
  -Dshared-glapi=enabled -Dzstd=disabled \
&& "$NINJA" -C _bpvr -j"$NPROC" \
&& "$NINJA" -C _bpvr install
) >"$log" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  echo "RESULT mesa-powervr FAIL build (rc=$rc)"
  grep -E "FAILED:| error:|fatal error|not found|Dependency|Program|Run-time|ERROR|meson.build|required|undefined" "$log" | head -80 | sed 's/^/  /'
  echo "  --- log: $log ---"; exit 1
fi
echo "RESULT mesa-powervr OK $out"
echo "  powervr vulkan: $(ls "$out"/lib/libvulkan_powervr* 2>/dev/null)"
echo "  powervr icd:    $(ls "$out"/share/vulkan/icd.d/powervr_icd* 2>/dev/null)"
echo "  log:            $log"
