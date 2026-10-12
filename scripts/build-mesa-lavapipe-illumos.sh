#!/bin/sh
# build-mesa-lavapipe-illumos.sh -- Mesa software Vulkan (lavapipe) + llvmpipe GL
# for x86_64-illumos (solnix). The REPRODUCIBLE form of the C2 "software Vulkan"
# milestone: a build the clean x86 build-host AMI can re-run from scratch to
# produce the lavapipe ICD + libvulkan_lvp.so, then stage + nix-store --add it
# (same host-build-then-bank pattern as the from-source Rust toolchain, because
# Mesa+LLVM do not build through the nixpkgs fork -- see scratch/mesa.nix).
#
# WHAT this gives: a working CPU Vulkan 1.3 device on solnix.
#   lavapipe (libvulkan_lvp.so)  -> DRIVER_ID_MESA_LLVMPIPE, enumerated by
#                                   vulkaninfo via its ICD manifest (lvp_icd.json)
#   llvmpipe (libgallium*.so)    -> JIT software GL/GLES (the fast SW rasterizer)
#   the Vulkan loader (libvulkan.so.1) resolves the ICD -> a real VkPhysicalDevice
# This is the API substrate COSMIC (wgpu-GL) and llama.cpp GGML_VULKAN need, and
# it is HONEST: software, not hardware. No /dev/dri, no DRM, no GPU.
#
# lavapipe = -Dvulkan-drivers=swrast  (the "swrast" vulkan driver IS lavapipe)
# llvmpipe = -Dgallium-drivers=llvmpipe + -Dllvm=enabled
# Both JIT the rasterizer with LLVM, so a target LLVM (libLLVM) is REQUIRED and
# meson must run llvm-config. The riscv64 lavapipe build
# (scripts/build-mesa-riscv64-lavapipe.sh) proved this exact meson config needs
# ZERO source patches on Mesa 25.1.4; on illumos we add the two upstreamable
# u_atomic.h / u_thread.c cuts (same as softpipe) + the libdrm-off pkgconfig trick.
#
# PREREQS on the illumos node (the clean build-host AMI provisions these):
#   - gcc-14 (/usr/gcc/14), GNU make, nix 2.24.x
#   - a python3 venv with meson>=1.3 + mako + pyyaml + packaging; ninja (samurai)
#   - LLVM for x86_64-illumos providing llvm-config. OI packages it:
#       pkg install developer/clang-20   (or clang-18) -> /usr/clang/NN/bin/llvm-config
#     (the CLC-toolchain work already installed clang-20 on a node; clang-18 also
#      works -- lavapipe needs LLVM>=15, the X86 target, mcjit+native.)
#   - Vulkan-Loader (libvulkan.so.1) + Vulkan-Headers for x86_64-illumos. OI has
#     no package; build from source once (src/drm-port/ggml-vulkan already did:
#     4 small __sun patches, see GGML-VULKAN-STATUS.md). This script can reuse
#     that prefix via VULKAN_LOADER_PREFIX, or build the loader if absent.
#   - zlib + expat (nix store paths, as softpipe used).
set -eu

MESA_VER="${MESA_VER:-25.1.4}"           # matches the proven riscv64 lavapipe pin
LLVM_CONFIG="${LLVM_CONFIG:-$(command -v llvm-config 2>/dev/null || echo /usr/clang/20/bin/llvm-config)}"
GCC="${GCC:-/usr/gcc/14}"
VENV="${VENV:-/root/mesa-venv}"
VULKAN_LOADER_PREFIX="${VULKAN_LOADER_PREFIX:-/root/ggml-vulkan/prefix}"  # libvulkan.so.1 + headers
ZLIB="${ZLIB:-}"; EXPAT="${EXPAT:-}"     # nix store paths; auto-found below if empty
JOBS="${JOBS:-$(psrinfo | wc -l | tr -d ' ')}"
OUTBASE="${OUTBASE:-/var/tmp}"

CC="$GCC/bin/gcc"; CXX="$GCC/bin/g++"; export CC CXX
export PATH="$VENV/bin:$GCC/bin:/usr/gnu/bin:/usr/bin:$PATH"
export LD_LIBRARY_PATH="$GCC/lib/amd64:$GCC/lib:${LD_LIBRARY_PATH:-}"

[ -x "$LLVM_CONFIG" ] || { echo "FAIL: no llvm-config at $LLVM_CONFIG (set LLVM_CONFIG=)"; exit 1; }
echo "llvm-config: $LLVM_CONFIG  ($("$LLVM_CONFIG" --version 2>&1))"
echo "llvm targets: $("$LLVM_CONFIG" --targets-built 2>&1)"
"$LLVM_CONFIG" --targets-built 2>/dev/null | grep -qw X86 || { echo "FAIL: LLVM has no X86 target"; exit 1; }

# auto-locate zlib/expat in the store if not given
if [ -z "$ZLIB" ]; then ZLIB=$(ls -d /nix/store/*-zlib-*/lib/.. 2>/dev/null | head -1 | xargs -I{} dirname {}/x 2>/dev/null); fi
if [ -z "$EXPAT" ]; then EXPAT=$(ls -d /nix/store/*-expat-*/lib/.. 2>/dev/null | head -1 | xargs -I{} dirname {}/x 2>/dev/null); fi
[ -d "$ZLIB/lib" ]  || { echo "FAIL: no zlib store path (set ZLIB=)"; exit 1; }
[ -d "$EXPAT/lib" ] || { echo "FAIL: no expat store path (set EXPAT=)"; exit 1; }
echo "zlib=$ZLIB expat=$EXPAT loader=$VULKAN_LOADER_PREFIX"

# pkg-config shim: only our store deps + the Vulkan loader; HIDE host /usr/lib
# pkgconfig so meson cannot auto-find the host's partial libdrm (no drm.h) --
# the exact softpipe fix (u_screen.c would fail on <xf86drm.h> with no drm.h).
PCSHIM=$(mktemp -d "$OUTBASE/pcshim.XXXXXX")
DEPI=""; DEPL=""; DEPR=""
for d in "$ZLIB" "$EXPAT" "$VULKAN_LOADER_PREFIX"; do
  [ -d "$d/include" ] && DEPI="$DEPI -I$d/include"
  [ -d "$d/lib" ] && { DEPL="$DEPL -L$d/lib"; DEPR="$DEPR -R$d/lib"; }
  for pcd in "$d/lib/pkgconfig" "$d/share/pkgconfig" "$d/lib/amd64/pkgconfig"; do
    [ -d "$pcd" ] || continue
    for pc in "$pcd"/*.pc; do
      [ -f "$pc" ] || continue
      sed -e "s|^prefix=.*|prefix=$d|" "$pc" > "$PCSHIM/$(basename "$pc")" 2>/dev/null || cp "$pc" "$PCSHIM/"
    done
  done
done
export PKG_CONFIG_PATH="$PCSHIM"
export PKG_CONFIG_LIBDIR="$PCSHIM"
export CFLAGS="-m64 -fPIC -O2 -D__EXTENSIONS__ -D_POSIX_PTHREAD_SEMANTICS -Wno-error=incompatible-pointer-types $DEPI"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="$DEPI"
export LDFLAGS="-m64 $DEPL $DEPR -lsocket -lnsl"

# fetch Mesa
[ -s /var/tmp/ca-bundle.crt ] || cat /etc/certs/CA/*.pem > /var/tmp/ca-bundle.crt 2>/dev/null || true
DLCA=""; [ -s /var/tmp/ca-bundle.crt ] && DLCA="--cacert /var/tmp/ca-bundle.crt"
w=$(mktemp -d "$OUTBASE/mesa-lvp.XXXXXX"); cd "$w"; tb=mesa.tar.xz
curl -fsSLk $DLCA -o "$tb" "https://archive.mesa3d.org/mesa-$MESA_VER.tar.xz" \
  || curl -fsSLk $DLCA -o "$tb" "https://mesa.freedesktop.org/archive/mesa-$MESA_VER.tar.xz" \
  || { echo "RESULT	lavapipe	FAIL	download"; exit 1; }
python3 -c "import tarfile; tarfile.open('$tb').extractall('.')" 2>/dev/null \
  || { xz -dc "$tb" | /usr/gnu/bin/tar xf - ; } \
  || { echo "RESULT	lavapipe	FAIL	untar"; exit 1; }
sd="$w/mesa-$MESA_VER"
[ -d "$sd" ] || { echo "RESULT	lavapipe	FAIL	no-srcdir"; exit 1; }

# illumos portability cuts (same two as softpipe; upstreamable)
UA="$sd/src/util/u_atomic.h"
sed -i 's/^#if defined(__sun)$/#if defined(__sun) \&\& !defined(__GNUC__)/' "$UA" 2>/dev/null || true
UT="$sd/src/util/u_thread.c"
sed -i 's/!defined(__HAIKU__) \&\& !defined(__managarm__)/!defined(__HAIKU__) \&\& !defined(__managarm__) \&\& !defined(__sun)/' "$UT" 2>/dev/null || true

out="$w/out"; mkdir -p "$out"
cat > /var/tmp/native-lvp.$$.ini <<NFEOF
[binaries]
c = '$CC'
cpp = '$CXX'
pkgconfig = '/usr/bin/pkg-config'
llvm-config = '$LLVM_CONFIG'
NFEOF

log="$w/.build.log"
(
cd "$sd"
"$VENV/bin/meson" setup _b --prefix="$out" --libdir=lib --buildtype=release \
  --wrap-mode=nodownload \
  --native-file /var/tmp/native-lvp.$$.ini \
  -Dvulkan-drivers=swrast \
  -Dgallium-drivers=llvmpipe \
  -Dllvm=enabled -Dshared-llvm=enabled \
  -Dplatforms= \
  -Dosmesa=true \
  -Dglx=disabled -Degl=disabled -Dgbm=disabled -Ddri3=disabled \
  -Dgles1=disabled -Dgles2=disabled \
  -Dopengl=true -Dshared-glapi=enabled \
  -Dvideo-codecs= -Dgallium-va=disabled -Dgallium-vdpau=disabled \
  -Dzstd=disabled \
&& ninja -C _b -j"$JOBS" \
&& ninja -C _b install
) >"$log" 2>&1 || {
  echo "RESULT	lavapipe	FAIL	build"
  grep -E "FAILED:| error:|fatal error|not found|Dependency|Program|Run-time|ERROR|meson.build|Problem|llvm" "$log" | head -60 | sed 's/^/  /'
  echo "  --- log: $log ---"; exit 1
}

# fix RUNPATHs so the .so's are host-free (resolve via store)
LLVMLIB="$("$LLVM_CONFIG" --libdir 2>/dev/null)"
RP="$out/lib:$GCC/lib/amd64:$GCC/lib:$ZLIB/lib:$EXPAT/lib:$VULKAN_LOADER_PREFIX/lib:$LLVMLIB"
find "$out" -type f 2>/dev/null | while read -r f; do /usr/bin/elfedit -e "dyn:runpath $RP" "$f" 2>/dev/null || true; done

# the lavapipe ICD manifest the Vulkan loader reads to find libvulkan_lvp.so.
# meson emits share/vulkan/icd.d/lvp_icd.x86_64.json with an abs library_path;
# rewrite it ICD-dir-relative so the loader resolves it wherever the store lands.
for icd in "$out"/share/vulkan/icd.d/*.json; do
  [ -f "$icd" ] || continue
  sed -i 's|"library_path"[[:space:]]*:[[:space:]]*".*/\(lib[^/"]*\.so[^"]*\)"|"library_path": "../../../lib/\1"|' "$icd" 2>/dev/null || true
done

named="$OUTBASE/mesa-lavapipe-$MESA_VER"; [ -e "$named" ] && named="$named.$$"; cp -a "$out" "$named"
spo=$(nix-store --add "$named" 2>/dev/null)
[ -n "$spo" ] || { echo "RESULT	lavapipe	FAIL	nix-store-add"; exit 1; }
nix-store --add-root /root/c2-gcroots/mesa-lavapipe --indirect --realise "$spo" >/dev/null 2>&1 || true

echo "RESULT	lavapipe	OK	$spo"
echo "  vulkan_lvp: $(ls "$spo"/lib/libvulkan_lvp* 2>/dev/null)"
echo "  gallium:    $(ls "$spo"/lib/libgallium* 2>/dev/null | head -1)"
echo "  icd:        $(ls "$spo"/share/vulkan/icd.d/*.json 2>/dev/null)"
echo "  srcdir:     $sd   log: $log"
echo
echo "NEXT (negative-controlled vulkaninfo proof -- see vulkaninfo-lavapipe-proof.sh):"
echo "  export VK_ICD_FILENAMES=$spo/share/vulkan/icd.d/lvp_icd.x86_64.json"
echo "  export VK_DRIVER_FILES=\$VK_ICD_FILENAMES   # newer loaders"
echo "  LD_LIBRARY_PATH=$VULKAN_LOADER_PREFIX/lib:$spo/lib vulkaninfo | grep -i llvmpipe"
