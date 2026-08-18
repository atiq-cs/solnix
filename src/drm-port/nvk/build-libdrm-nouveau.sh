#!/bin/sh
# build-libdrm-nouveau.sh -- add the nouveau module (libdrm_nouveau) to the
# libdrm already built for RADV. NVK's nouveau winsys (src/nouveau/winsys)
# links dep_libdrm_nouveau (>= 2.4.102) -- the exact analogue of RADV's
# libdrm_amdgpu. libdrm_nouveau wraps the nouveau DRM ioctls (DRM_NOUVEAU_*)
# and ships the nvif/ headers (ioctl.h, cl0080.h, class.h) that
# nouveau_device.c includes. Same standalone meson+ninja+gcc-14 pattern as
# build-libdrm.sh; reuses the /var/tmp/libdrm-out prefix (already carries the
# amdgpu module + the Linux _IOC shim + core libdrm) and the shimmed drm.h.
set -u
export PATH=/root/mesa-venv/bin:/usr/gnu/bin:/usr/bin:$PATH
GCC=/usr/gcc/14; CC="$GCC/bin/gcc"; CXX="$GCC/bin/g++"; export CC CXX
export LD_LIBRARY_PATH="$GCC/lib/amd64:$GCC/lib:${LD_LIBRARY_PATH:-}"
MESON=/root/mesa-venv/bin/meson
NINJA=/root/mesa-venv/bin/ninja
NPROC=$(psrinfo | wc -l | tr -d ' ')
ver="${1:-2.4.120}"
sd="/var/tmp/libdrm-$ver"; out="/var/tmp/libdrm-out"
[ -d "$sd" ] || { echo "RESULT libdrm-nouveau FAIL no-srcdir ($sd) -- run build-libdrm.sh first"; exit 1; }

# The Linux _IOC shim must be in drm.h's __sun path already (build-libdrm.sh).
# nouveau.c issues DRM_NOUVEAU_* via drmCommandWrite/WriteRead -> the Linux DRM
# ioctl numbers, matching the C1 kernel. The shim guarantees the encoding.
grep -q linux-ioctl-compat "$sd/include/drm/drm.h" \
  || { echo "RESULT libdrm-nouveau FAIL drm.h missing the Linux _IOC shim -- run build-libdrm.sh"; exit 1; }

export CFLAGS="-m64 -fPIC -O2 -D__EXTENSIONS__ -D_POSIX_PTHREAD_SEMANTICS -Wno-error=incompatible-pointer-types"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-m64 -lsocket -lnsl"

# native file (single-quoted paths -- meson rejects double quotes)
printf "[binaries]\nc = '%s'\ncpp = '%s'\npkgconfig = '/usr/bin/pkg-config'\n" "$CC" "$CXX" > /var/tmp/native-libdrm-nv.ini

log="/var/tmp/libdrm-nouveau.build.log"; bdir="_bnv"
(
cd "$sd"
"$MESON" setup "$bdir" --prefix="$out" --libdir=lib --buildtype=release \
  --wrap-mode=nodownload --native-file /var/tmp/native-libdrm-nv.ini \
  -Damdgpu=enabled -Dnouveau=enabled \
  -Dradeon=disabled -Dintel=disabled -Dvmwgfx=disabled \
  -Dvc4=disabled -Dfreedreno=disabled -Detnaviv=disabled \
  -Dcairo-tests=disabled -Dman-pages=disabled -Dvalgrind=disabled -Dtests=false \
  && "$NINJA" -C "$bdir" -j"$NPROC" \
  && "$NINJA" -C "$bdir" install
) >"$log" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  echo "RESULT libdrm-nouveau FAIL build (rc=$rc)"
  grep -E "FAILED:| error:|fatal error|not found|Dependency|ERROR|undefined" "$log" | head -40 | sed 's/^/  /'
  echo "  --- log: $log ---"; exit 1
fi
echo "RESULT libdrm-nouveau OK $out"
echo "  nouveau lib: $(ls "$out"/lib/libdrm_nouveau* 2>/dev/null)"
echo "  nouveau pc:  $(ls "$out"/lib/pkgconfig/libdrm_nouveau.pc 2>/dev/null)"
echo "  nvif hdrs:   $(ls "$out"/include/libdrm/nouveau/nvif/ioctl.h 2>/dev/null)"
