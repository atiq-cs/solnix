#!/bin/sh
# build-mesa-radv.sh -- C3-RADV: Mesa RADV (the real AMD hardware Vulkan driver,
# src/amd/vulkan) for illumos x86_64, host-free COMPILE-phase. RADV uses ACO (its
# own compiler) by default -- no LLVM. It links libdrm_amdgpu (built by
# build-libdrm.sh against the C1/amdgpu Linux-_IOC ioctl surface). Same
# standalone meson+ninja+gcc pattern as the C2 virgl/venus build, plus:
#   -Dvulkan-drivers=amd  (RADV)  -- keep swrast so the Vulkan WSI/runtime base +
#     shared gallium aux still build; virtio (Venus) kept so the ICD set matches C3a.
#   libdrm shim points pkg-config at the freshly-built libdrm-out (amdgpu module).
set -u
export PATH=/root/mesa-venv/bin:/usr/gnu/bin:/usr/bin:$PATH
MESON=/root/mesa-venv/bin/meson
NINJA=/root/mesa-venv/bin/ninja
GCC=/usr/gcc/14; CC="$GCC/bin/gcc"; CXX="$GCC/bin/g++"; export CC CXX
export LD_LIBRARY_PATH="$GCC/lib/amd64:$GCC/lib:${LD_LIBRARY_PATH:-}"
NPROC=$(psrinfo | wc -l | tr -d ' ')
ZLIB=""; EXPAT=""
ver="${1:-24.0.9}"
LIBDRM=/var/tmp/libdrm-out          # from build-libdrm.sh (libdrm_amdgpu)

sd="/var/tmp/mesa-$ver"
[ -d "$sd" ] || { echo "RESULT mesa-radv FAIL no-srcdir ($sd) -- run mesa download first"; exit 1; }

# pkg-config shim: expose the freshly-built libdrm + libdrm_amdgpu .pc, prefix
# rewritten to the store-free build path. RADV meson wants libdrm_amdgpu>=2.4.119.
PCSHIM=$(mktemp -d /var/tmp/pcshim.XXXXXX)
for pc in "$LIBDRM"/lib/pkgconfig/*.pc; do
  [ -f "$pc" ] || continue
  sed -e "s|^prefix=.*|prefix=$LIBDRM|" "$pc" > "$PCSHIM/$(basename "$pc")"
done

# --- shim drm-uapi headers (same as the venus build) so xf86drm.h's <drm.h>
#     resolves; RADV also needs the bundled amdgpu_drm.h. Use the freshly-built
#     libdrm's own headers (they carry the Linux-_IOC encoding + amdgpu.h). ---
DRMSHIM="$LIBDRM"   # libdrm-out/include/libdrm has xf86drm.h, drm.h, amdgpu.h

export PKG_CONFIG_PATH="$PCSHIM"
export PKG_CONFIG_LIBDIR="$PCSHIM"
export CFLAGS="-m64 -fPIC -O2 -D__EXTENSIONS__ -D_POSIX_PTHREAD_SEMANTICS -Wno-error=incompatible-pointer-types -I$DRMSHIM/include -I$DRMSHIM/include/libdrm"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-I$DRMSHIM/include -I$DRMSHIM/include/libdrm"
export LDFLAGS="-m64 -L$LIBDRM/lib -R$LIBDRM/lib -L/usr/lib/xorg/amd64 -R/usr/lib/xorg/amd64 -lsocket -lnsl"

# --- illumos portability patches (the venus set 1-9, re-applied; idempotent) ---
UA="$sd/src/util/u_atomic.h"
sed -i 's/^#if defined(__sun)$/#if defined(__sun) \&\& !defined(__GNUC__)/' "$UA" 2>/dev/null || true
UT="$sd/src/util/u_thread.c"
sed -i 's/!defined(__HAIKU__) \&\& !defined(__managarm__)/!defined(__HAIKU__) \&\& !defined(__managarm__) \&\& !defined(__sun)/' "$UT" 2>/dev/null || true
LS="$sd/src/util/libsync.h"
if [ -f "$LS" ] && ! grep -q 'sys/ioccom.h' "$LS"; then
  sed -i 's|#include <sys/ioctl.h>|#include <sys/ioctl.h>\n#ifdef __sun\n#include <sys/types.h>\n#include <sys/ioccom.h>\n#endif|' "$LS" 2>/dev/null || true
fi
VCH="$sd/src/virtio/vulkan/vn_common.h"
if [ -f "$VCH" ] && grep -q 'syscall(SYS_gettid)' "$VCH"; then
  sed -i 's|   return syscall(SYS_gettid);|#ifdef __sun\n   return (pid_t)(uintptr_t)pthread_self();\n#else\n   return syscall(SYS_gettid);\n#endif|' "$VCH" 2>/dev/null || true
fi
VMB="$sd/src/virtio/vulkan/meson.build"
if [ -f "$VMB" ] && ! grep -q 'idep_nir' "$VMB"; then
  sed -i 's|^  idep_vulkan_runtime,|  idep_vulkan_runtime,\n  idep_nir,\n  idep_vtn,|' "$VMB" 2>/dev/null || true
fi

# illumos: alloca lives in <alloca.h> (not <stdlib.h>). RADV/ACO/ac_common use
# alloca; inject a guarded include into the two shared headers they pull.
MAC="$sd/src/util/macros.h"
if [ -f "$MAC" ] && ! grep -q alloca.h "$MAC"; then
  sed -i 's|#include <stdio.h>|#include <stdio.h>\n#ifdef __sun\n#include <alloca.h>\n#endif|' "$MAC" 2>/dev/null || true
fi
ACOIR="$sd/src/amd/compiler/aco_ir.h"
if [ -f "$ACOIR" ] && ! grep -q alloca.h "$ACOIR"; then
  sed -i 's|#define ACO_IR_H|#define ACO_IR_H\n#ifdef __sun\n#include <alloca.h>\n#endif|' "$ACOIR" 2>/dev/null || true
fi

# illumos: getpwuid_r is the 4-arg SunOS form (returns struct passwd*), not the
# 5-arg POSIX form disk_cache_os.c assumes.
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

RVM="$sd/src/amd/vulkan/meta/radv_meta.c"
if [ -f "$RVM" ] && ! grep -q "4-arg SunOS" "$RVM"; then
  python3 - "$RVM" <<'PYM'
import sys
p=sys.argv[1]; s=open(p).read()
old="   getpwuid_r(getuid(), &pwd, path2, PATH_MAX - strlen(suffix2), &result);\n"
new=("#ifdef __sun\n   result = getpwuid_r(getuid(), &pwd, path2, PATH_MAX - strlen(suffix2)); /* 4-arg SunOS */\n"
     "#else\n   getpwuid_r(getuid(), &pwd, path2, PATH_MAX - strlen(suffix2), &result);\n#endif\n")
open(p,"w").write(s.replace(old,new,1))
PYM
fi

out="/var/tmp/mesa-radv-out"; mkdir -p "$out"
cat > /var/tmp/native-radv.$$.ini <<NFEOF
[binaries]
c = '$CC'
cpp = '$CXX'
pkgconfig = '/usr/bin/pkg-config'
NFEOF

log="/var/tmp/mesa-radv.build.log"
(
cd "$sd"
"$MESON" setup _brad --prefix="$out" --libdir=lib --buildtype=release \
  --wrap-mode=nodownload \
  --native-file /var/tmp/native-radv.$$.ini \
  -Dgallium-drivers=swrast \
  -Dc_args="-Wno-error=incompatible-pointer-types -Wno-error=pointer-sign" \
  -Dcpp_args="-Wno-error=incompatible-pointer-types" \
  -Dvulkan-drivers=amd,virtio \
  -Dvideo-codecs= \
  -Dplatforms= \
  -Dllvm=disabled \
  -Dosmesa=false \
  -Dglx=disabled -Degl=disabled -Dgbm=disabled -Ddri3=disabled \
  -Dgles1=disabled -Dgles2=disabled -Dopengl=true \
  -Dshared-glapi=enabled -Dzstd=disabled \
&& "$NINJA" -C _brad -j"$NPROC" \
&& "$NINJA" -C _brad install
) >"$log" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  echo "RESULT mesa-radv FAIL build (rc=$rc)"
  grep -E "FAILED:| error:|fatal error|not found|Dependency|Program|Run-time|ERROR|meson.build|Problem|required|undefined" "$log" | head -60 | sed 's/^/  /'
  echo "  --- log: $log ---"; exit 1
fi
echo "RESULT mesa-radv OK $out"
echo "  radv vulkan: $(ls "$out"/lib/libvulkan_radeon* 2>/dev/null)"
echo "  radv icd:    $(ls "$out"/share/vulkan/icd.d/radeon_icd* 2>/dev/null)"
echo "  venus:       $(ls "$out"/lib/libvulkan_virtio* 2>/dev/null)"
echo "  log:         $log"
