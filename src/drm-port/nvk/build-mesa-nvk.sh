#!/bin/sh
# build-mesa-nvk.sh -- NVK (NVIDIA's open Vulkan driver, src/nouveau/vulkan,
# libvulkan_nouveau.so) for illumos x86_64, COMPILE-phase, zero-phantom, against
# the C1 DRM / nouveau ioctl surface. Fast follow-on to RADV/ANV: same Mesa
# 24.0.9 tree, same meson+ninja+gcc-14+glslang toolchain, the same 5 Mesa-wide
# illumos fixes + the same Linux _IOC ioctl shim. NVK's winsys links
# libdrm_nouveau (build-libdrm-nouveau.sh) and issues the nouveau DRM ioctls
# (DRM_NOUVEAU_*) through drmCommandWrite/WriteRead -- the exact analogue of
# RADV's libdrm_amdgpu winsys.
#
# GATE: NVK's shader compiler NAK (src/nouveau/compiler/nak) is written in RUST
# (requires rustc >= 1.73.0 + rust.bindgen -> libclang). This is unlike RADV
# (ACO, C++) and ANV (brw, C++), which need no LLVM/Rust. Mesa 24.0.9 names the
# driver `nouveau-experimental` -- upstream's own signal that NVK is early here.
# meson config resolves EVERY dependency (libdrm_nouveau/libdrm found, glslang
# found, nvidia_headers/nil/mme/winsys all C) and dies at exactly one point:
#   src/nouveau/compiler/meson.build:7: ERROR: Unknown compiler(s): [['rustc']]
# The node has no rustc/cargo/bindgen/libclang. Bootstrapping the Rust 1.73
# toolchain + bindgen (which needs libclang == building LLVM/clang, the very
# drag NVK's NAK avoids at runtime) on illumos is a separate multi-hour project.
# This script configures NVK to that gate; the nouveau ioctl port + libdrm_nouveau
# + the ICD contract are all COMPILE-ready behind it.
set -u
export PATH=/root/mesa-venv/bin:/usr/gnu/bin:/usr/bin:$PATH
MESON=/root/mesa-venv/bin/meson
NINJA=/root/mesa-venv/bin/ninja
GCC=/usr/gcc/14; CC="$GCC/bin/gcc"; CXX="$GCC/bin/g++"; export CC CXX
export LD_LIBRARY_PATH="$GCC/lib/amd64:$GCC/lib:${LD_LIBRARY_PATH:-}"
NPROC=$(psrinfo | wc -l | tr -d ' ')
ver="${1:-24.0.9}"
LIBDRM=/var/tmp/libdrm-out          # libdrm + libdrm_nouveau (winsys ioctl wrappers)
SHIM=/root/drm-port/anv/linux-ioctl-compat.h   # the Linux _IOC shim (== RADV/ANV/C1)

sd="/var/tmp/mesa-$ver"
[ -d "$sd" ] || { echo "RESULT mesa-nvk FAIL no-srcdir ($sd)"; exit 1; }

# pkg-config shim: expose the freshly-built libdrm + libdrm_nouveau .pc.
PCSHIM=$(mktemp -d /var/tmp/pcshim-nvk.XXXXXX)
for pc in "$LIBDRM"/lib/pkgconfig/libdrm.pc "$LIBDRM"/lib/pkgconfig/libdrm_nouveau.pc "$LIBDRM"/lib/pkgconfig/libdrm_amdgpu.pc; do
  [ -f "$pc" ] && sed -e "s|^prefix=.*|prefix=$LIBDRM|" "$pc" > "$PCSHIM/$(basename "$pc")"
done
export PKG_CONFIG_PATH="$PCSHIM"
export PKG_CONFIG_LIBDIR="$PCSHIM"
export CFLAGS="-m64 -fPIC -O2 -D__EXTENSIONS__ -D_POSIX_PTHREAD_SEMANTICS -Wno-error=incompatible-pointer-types -I$LIBDRM/include -I$LIBDRM/include/libdrm"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-I$LIBDRM/include -I$LIBDRM/include/libdrm"
export LDFLAGS="-m64 -L$LIBDRM/lib -R$LIBDRM/lib -L/usr/lib/xorg/amd64 -R/usr/lib/xorg/amd64 -lsocket -lnsl"

# --- the 5 Mesa-wide illumos fixes (the RADV/ANV set, idempotent) ---
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
#     <sys/ioccom.h>) so DRM_NOUVEAU_* match the C1 kernel. Same shim as RADV/ANV.
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

out="/var/tmp/mesa-nvk-out"; mkdir -p "$out"
printf "[binaries]\nc = '%s'\ncpp = '%s'\npkgconfig = '/usr/bin/pkg-config'\n" "$CC" "$CXX" > /var/tmp/native-nvk.ini

# NVK config: add nouveau to the RADV/ANV driver set. In Mesa 24.0.9 the driver
# is named `nouveau-experimental`. NAK needs no LLVM (its own compiler) -- so
# -Dllvm=disabled stays. The full triad target line is:
#   -Dvulkan-drivers=amd,intel,nouveau-experimental
# (this script builds nouveau alone to isolate the NVK/NAK gate; flip to the
#  triad once a Rust 1.73 toolchain is present.)
log="/var/tmp/mesa-nvk.build.log"
(
cd "$sd"
[ -d _bnvk ] && MESON_SETUP_ARGS="--reconfigure" || MESON_SETUP_ARGS=""
"$MESON" setup _bnvk $MESON_SETUP_ARGS --prefix="$out" --libdir=lib --buildtype=release \
  --wrap-mode=nodownload \
  --native-file /var/tmp/native-nvk.ini \
  -Dgallium-drivers=swrast \
  -Dc_args="-Wno-error=incompatible-pointer-types -Wno-error=pointer-sign" \
  -Dcpp_args="-Wno-error=incompatible-pointer-types" \
  -Dvulkan-drivers=nouveau-experimental \
  -Dvideo-codecs= \
  -Dplatforms= \
  -Dllvm=disabled \
  -Dosmesa=false \
  -Dglx=disabled -Degl=disabled -Dgbm=disabled -Ddri3=disabled \
  -Dgles1=disabled -Dgles2=disabled -Dopengl=true \
  -Dshared-glapi=enabled -Dzstd=disabled \
&& "$NINJA" -C _bnvk -j"$NPROC" \
&& "$NINJA" -C _bnvk install
) >"$log" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  if grep -q "Unknown compiler(s): \[\['rustc'\]\]" "$log"; then
    echo "RESULT mesa-nvk GATED rust (NAK requires rustc >= 1.73.0; not on node)"
    echo "  Config resolved every non-Rust dep:"
    grep -E "libdrm_nouveau found|libdrm found|glslangValidator found" "$log" | sed 's/^/    /'
    echo "  Gate: $(grep -n rustc "$log" | head -2 | sed 's/^/    /')"
    echo "  --- log: $log ---"; exit 2
  fi
  echo "RESULT mesa-nvk FAIL build (rc=$rc)"
  grep -E "FAILED:| error:|fatal error|not found|Dependency|Program|Run-time|ERROR|meson.build|required|undefined" "$log" | head -80 | sed 's/^/  /'
  echo "  --- log: $log ---"; exit 1
fi
echo "RESULT mesa-nvk OK $out"
echo "  nvk vulkan: $(ls "$out"/lib/libvulkan_nouveau* 2>/dev/null)"
echo "  nvk icd:    $(ls "$out"/share/vulkan/icd.d/nouveau_icd* 2>/dev/null)"
echo "  log:        $log"
