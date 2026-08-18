#!/bin/sh
# link-powervr25.sh -- FINISH the PowerVR link: Mesa 25.3.6 libvulkan_powervr_mesa.so
# with the real CLC toolchain (LLVM 20.1.8 + SPIRV-Tools + SPIRV-LLVM-Translator
# + libclc) now co-located on this node. CLC-TOOLCHAIN-STATUS.md section 6 options:
# -Dmesa-clc=enabled -Dllvm=enabled -Dprecomp-compiler=enabled. Keeps the C-PVR-a
# illumos fixes (already applied to the tree) + the same env.
set -u
. /root/clc-toolchain/env.sh
export PATH="/root/mesa-venv/bin:/root/clc-toolchain/install/bin:/usr/clang/20/bin:/usr/gnu/bin:/usr/bin:$PATH"
MESON=/root/mesa-venv/bin/meson
NINJA=/root/mesa-venv/bin/ninja
GCC=/usr/gcc/14; CC="$GCC/bin/gcc"; CXX="$GCC/bin/g++"; export CC CXX
export LD_LIBRARY_PATH="/usr/clang/20/lib:$GCC/lib/amd64:$GCC/lib:/usr/gcc/14/lib/amd64:${LD_LIBRARY_PATH:-}"
NPROC=$(psrinfo | wc -l | tr -d ' ')
ver="${1:-25.3.6}"
LIBDRM=/var/tmp/libdrm-out

sd="/var/tmp/mesa-$ver"
[ -d "$sd" ] || { echo "RESULT powervr25-link FAIL no-srcdir ($sd)"; exit 1; }

PCSHIM=$(mktemp -d /var/tmp/pcshim-pvr25link.XXXXXX)
sed -e "s|^prefix=.*|prefix=$LIBDRM|" "$LIBDRM/lib/pkgconfig/libdrm.pc" > "$PCSHIM/libdrm.pc"
export PKG_CONFIG_PATH="$PCSHIM:/root/clc-toolchain/install/lib/pkgconfig:/root/clc-toolchain/install/share/pkgconfig"

export CFLAGS="-m64 -fPIC -O2 -D__EXTENSIONS__ -D_POSIX_PTHREAD_SEMANTICS -Wno-error=incompatible-pointer-types -I$LIBDRM/include -I$LIBDRM/include/libdrm"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-I$LIBDRM/include -I$LIBDRM/include/libdrm"
export LDFLAGS="-m64 -L$LIBDRM/lib -R$LIBDRM/lib -L/usr/lib/xorg/amd64 -R/usr/lib/xorg/amd64 -lsocket -lnsl"

out="/var/tmp/mesa-powervr25-out"; mkdir -p "$out"
cat > /var/tmp/native-powervr25.ini <<INI
[binaries]
c = '$CC'
cpp = '$CXX'
pkgconfig = '/usr/bin/pkg-config'
INI

log="/var/tmp/mesa-powervr25-link.build.log"
BUILD=_bpvr25link
(
cd "$sd"
[ -d "$BUILD" ] && mv "$BUILD" "$BUILD.old.$$"
"$MESON" setup "$BUILD" --prefix="$out" --libdir=lib --buildtype=release \
  --wrap-mode=nodownload \
  --native-file /var/tmp/native-powervr25.ini \
  -Dgallium-drivers= \
  -Dc_args="-Wno-error=incompatible-pointer-types -Wno-error=pointer-sign" \
  -Dcpp_args="-Wno-error=incompatible-pointer-types" \
  -Dvulkan-drivers=imagination \
  -Dimagination-srv=false \
  -Dvideo-codecs= \
  -Dplatforms= \
  -Dllvm=enabled \
  -Dmesa-clc=enabled \
  -Dprecomp-compiler=enabled \
  -Dglx=disabled -Degl=disabled -Dgbm=disabled \
  -Dgles1=disabled -Dgles2=disabled -Dopengl=true \
  -Dshared-glapi=enabled -Dzstd=disabled \
&& "$NINJA" -C "$BUILD" -j"$NPROC" src/imagination/vulkan/libvulkan_powervr_mesa.so
) >"$log" 2>&1
rc=$?
echo "=== tail of log ==="
tail -40 "$log"
if [ $rc -ne 0 ]; then
  echo "RESULT powervr25-link FAIL (rc=$rc)"
  echo "=== error grep ==="
  grep -nE "FAILED:| error:|fatal error|not found|Dependency|Program|Run-time|ERROR|required|undefined|CLC|LLVM|llvm-spirv|libclc|SPIRV|mesa_clc" "$log" | head -60
  exit 1
fi
echo "RESULT powervr25-link OK"
ls -l "$sd/$BUILD/src/imagination/vulkan/libvulkan_powervr_mesa.so"
