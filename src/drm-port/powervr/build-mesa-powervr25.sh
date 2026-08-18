#!/bin/sh
# build-mesa-powervr25.sh -- PowerVR (Imagination's open Vulkan driver,
# src/imagination/vulkan, libvulkan_powervr_mesa.so) from Mesa 25.3.6 for
# illumos x86_64, COMPILE-phase, zero-phantom. This is the Mesa-25.x follow-on
# to the 24.0.9 build (build-mesa-powervr.sh): 25.3.6 is the first Mesa that
# ships the Milk-V Jupiter's EXACT GPU -- the Imagination BXE-2-32 (BVNC
# 36.29.52.182, device_id 0x36052182) -- in src/imagination/common/device_info/
# bxe-2-32.h, matched by CASE_PACKED_BVNC_DEVICE_INFO(36, 29, 52, 182) in
# pvr_device_info.c. 24.0.9 had only GX6250 / AXE-1-16M / BXS-4-64.
#
# COMPILER CHANGE: 25.x's default imagination shader compiler is "pco" (the new
# NIR compiler, src/imagination/pco), NOT the old "rogue". The top meson.build
# now does subdir('pco') unconditionally; rogue is legacy. pco itself is pure C
# / NIR (no Rust), BUT its usclib (src/imagination/pco/usclib) compiles OpenCL-C
# (.cl) helper shaders through mesa_clc, and with_imagination_vk is in Mesa's
# with_driver_using_cl list -> forces with_clc -> HARD-requires LLVM (>=18) +
# SPIRV-Tools + SPIRV-LLVM-Translator + libclc at build time. The illumos host
# has clang-21 (LLVM 21.1.8, satisfies >=18) but NO llvm-config binary, NO
# SPIRV-Tools, NO libclc -> mesa_clc cannot be built without first building
# that CLC toolchain (the newer-toolchain wedge the task predicted for 25.x).
#
# Reuses the C-PVR-a illumos fixes unchanged: the 5 Mesa-wide fixes + the Linux
# _IOC ioctl shim + the pvr_drm.h __sun linux-header guard + the _BITULL shim.
# pvr_drm.h ABI is BYTE-IDENTICAL 24.0.9 <-> 25.3.6 (the 14 ioctls 0x00..0x0d,
# all struct layouts, all flags) -> ZERO ABI delta vs C-PVR-b.
set -u
export PATH="/root/mesa-venv/bin:/usr/gnu/bin:/usr/bin:$PATH"
MESON=/root/mesa-venv/bin/meson
NINJA=/root/mesa-venv/bin/ninja
GCC=/usr/gcc/14; CC="$GCC/bin/gcc"; CXX="$GCC/bin/g++"; export CC CXX
export LD_LIBRARY_PATH="$GCC/lib/amd64:$GCC/lib:${LD_LIBRARY_PATH:-}"
NPROC=$(psrinfo | wc -l | tr -d ' ')
ver="${1:-25.3.6}"
LIBDRM=/var/tmp/libdrm-out          # core libdrm (built for RADV) -- pvr needs only this
SHIM=/root/drm-port/anv/linux-ioctl-compat.h   # the Linux _IOC shim (== RADV/ANV/NVK/C-PVR-a)

sd="/var/tmp/mesa-$ver"
[ -d "$sd" ] || { echo "RESULT mesa-powervr25 FAIL no-srcdir ($sd)"; exit 1; }

# pkg-config shim: expose the freshly-built core libdrm .pc.
PCSHIM=$(mktemp -d /var/tmp/pcshim-pvr25.XXXXXX)
for pc in "$LIBDRM"/lib/pkgconfig/libdrm.pc; do
  [ -f "$pc" ] && sed -e "s|^prefix=.*|prefix=$LIBDRM|" "$pc" > "$PCSHIM/$(basename "$pc")"
done
export PKG_CONFIG_PATH="$PCSHIM"
export PKG_CONFIG_LIBDIR="$PCSHIM"
export CFLAGS="-m64 -fPIC -O2 -D__EXTENSIONS__ -D_POSIX_PTHREAD_SEMANTICS -Wno-error=incompatible-pointer-types -I$LIBDRM/include -I$LIBDRM/include/libdrm"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-I$LIBDRM/include -I$LIBDRM/include/libdrm"
export LDFLAGS="-m64 -L$LIBDRM/lib -R$LIBDRM/lib -L/usr/lib/xorg/amd64 -R/usr/lib/xorg/amd64 -lsocket -lnsl"

# --- the 5 Mesa-wide illumos fixes (the C-PVR-a set, idempotent) ---
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

# --- powervr-specific illumos fix (== C-PVR-a): pvr_drm.h pulls
#     <linux/const.h>/<linux/types.h> AFTER "drm.h"; guard for __sun, use the
#     shim (which carries _BITULL). Always re-copy the shim. ---
cp "$SHIM" "$sd/include/drm-uapi/linux-ioctl-compat.h"
PVRH="$sd/include/drm-uapi/pvr_drm.h"
if [ -f "$PVRH" ] && ! grep -q "SOLNIX_PVR_LINUX_GUARD" "$PVRH"; then
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

out="/var/tmp/mesa-powervr25-out"; mkdir -p "$out"
cat > /var/tmp/native-powervr25.ini <<INI
[binaries]
c = '$CC'
cpp = '$CXX'
pkgconfig = '/usr/bin/pkg-config'
INI

log="/var/tmp/mesa-powervr25.build.log"
# CLC gate: with_imagination_vk is in Mesa 25.x's with_driver_using_cl
# list, which forces with_clc -> HARD-requires LLVM to build the pco usclib
# (.cl OpenCL-C helper shaders -> mesa_clc -> SPIR-V). To reach setup we set
# -Dmesa-clc=system: that makes with_clc = with_gallium_rusticl = false (we
# build no rusticl), so the 'CLC requires LLVM' gate is bypassed and meson
# find_program()s mesa_clc + vtn_bindgen2 instead. -Dprecomp-compiler=auto
# then BUILDS pco_clc from the tree (pure C/NIR, no LLVM). A prebuilt/stub
# mesa_clc + vtn_bindgen2 must be on PATH (e.g. /var/tmp/clcstub) for setup;
# the real ninja step .cl->.spv still needs an LLVM-backed mesa_clc, absent on
# this illumos host (clang-21 runtime libs only: no llvm-config, no headers,
# no SPIRV-Tools, no libclc). See POWERVR-STATUS.md "the CLC/LLVM wedge".
export PATH="/var/tmp/clcstub:$PATH"
(
cd "$sd"
[ -d _bpvr25 ] && MESON_SETUP_ARGS="--reconfigure" || MESON_SETUP_ARGS=""
# 25.x renamed the vulkan driver: imagination-experimental -> imagination.
"$MESON" setup _bpvr25 $MESON_SETUP_ARGS --prefix="$out" --libdir=lib --buildtype=release \
  --wrap-mode=nodownload \
  --native-file /var/tmp/native-powervr25.ini \
  -Dgallium-drivers= \
  -Dc_args="-Wno-error=incompatible-pointer-types -Wno-error=pointer-sign" \
  -Dcpp_args="-Wno-error=incompatible-pointer-types" \
  -Dvulkan-drivers=imagination \
  -Dimagination-srv=false \
  -Dvideo-codecs= \
  -Dplatforms= \
  -Dmesa-clc=system \
  -Dprecomp-compiler=auto \
  -Dglx=disabled -Degl=disabled -Dgbm=disabled \
  -Dgles1=disabled -Dgles2=disabled -Dopengl=true \
  -Dshared-glapi=enabled -Dzstd=disabled \
&& "$NINJA" -C _bpvr25 -j"$NPROC" \
&& "$NINJA" -C _bpvr25 install
) >"$log" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  echo "RESULT mesa-powervr25 FAIL build (rc=$rc)"
  grep -E "FAILED:| error:|fatal error|not found|Dependency|Program|Run-time|ERROR|meson.build|required|undefined|CLC|LLVM|llvm|libclc|SPIRV" "$log" | head -80 | sed 's/^/  /'
  echo "  --- log: $log ---"; exit 1
fi
echo "RESULT mesa-powervr25 OK $out"
echo "  powervr vulkan: $(ls "$out"/lib/libvulkan_powervr* 2>/dev/null)"
echo "  powervr icd:    $(ls "$out"/share/vulkan/icd.d/powervr* 2>/dev/null)"
echo "  log:            $log"
