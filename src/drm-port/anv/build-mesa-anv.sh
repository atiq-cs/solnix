#!/bin/sh
# build-mesa-anv.sh -- ANV (Intel's Vulkan driver, src/intel/vulkan,
# libvulkan_intel.so) for illumos x86_64, COMPILE-phase, zero-phantom, against
# the C1 DRM / i915+xe ioctl surface. Fast follow-on to RADV: same Mesa 24.0.9
# tree, same meson+ninja+gcc-14+glslang toolchain. ANV uses its own compiler
# (brw/elk) -- no LLVM. Unlike RADV it needs NO libdrm_intel: it issues the
# i915/xe DRM ioctls directly via intel_ioctl() -> ioctl(), with the ioctl
# numbers coming from the bundled include/drm-uapi/{drm,i915,xe}_drm.h headers.
# The load-bearing illumos fix is the same as RADV: force the Linux _IOC
# encoding (not illumos <sys/ioccom.h>) so the ioctl numbers match the C1 kernel.
set -u
export PATH=/root/mesa-venv/bin:/usr/gnu/bin:/usr/bin:$PATH
MESON=/root/mesa-venv/bin/meson
NINJA=/root/mesa-venv/bin/ninja
GCC=/usr/gcc/14; CC="$GCC/bin/gcc"; CXX="$GCC/bin/g++"; export CC CXX
export LD_LIBRARY_PATH="$GCC/lib/amd64:$GCC/lib:${LD_LIBRARY_PATH:-}"
NPROC=$(psrinfo | wc -l | tr -d ' ')
ver="${1:-24.0.9}"
LIBDRM=/var/tmp/libdrm-out          # plain libdrm (dep_libdrm: syncobj/prime helpers)
SHIM=/root/drm-port/anv/linux-ioctl-compat.h

sd="/var/tmp/mesa-$ver"
[ -d "$sd" ] || { echo "RESULT mesa-anv FAIL no-srcdir ($sd)"; exit 1; }

# pkg-config shim: expose the freshly-built libdrm .pc (prefix rewritten).
PCSHIM=$(mktemp -d /var/tmp/pcshim-anv.XXXXXX)
for pc in "$LIBDRM"/lib/pkgconfig/libdrm.pc; do
  [ -f "$pc" ] || continue
  sed -e "s|^prefix=.*|prefix=$LIBDRM|" "$pc" > "$PCSHIM/$(basename "$pc")"
done
DRMSHIM="$LIBDRM"
export PKG_CONFIG_PATH="$PCSHIM"
export PKG_CONFIG_LIBDIR="$PCSHIM"
export CFLAGS="-m64 -fPIC -O2 -D__EXTENSIONS__ -D_POSIX_PTHREAD_SEMANTICS -Wno-error=incompatible-pointer-types -I$DRMSHIM/include -I$DRMSHIM/include/libdrm"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="-I$DRMSHIM/include -I$DRMSHIM/include/libdrm"
export LDFLAGS="-m64 -L$LIBDRM/lib -R$LIBDRM/lib -L/usr/lib/xorg/amd64 -R/usr/lib/xorg/amd64 -lsocket -lnsl"

# --- Mesa-wide illumos portability patches (the RADV set, idempotent) ---
UA="$sd/src/util/u_atomic.h"
sed -i 's/^#if defined(__sun)$/#if defined(__sun) \&\& !defined(__GNUC__)/' "$UA" 2>/dev/null || true
UT="$sd/src/util/u_thread.c"
sed -i 's/!defined(__HAIKU__) \&\& !defined(__managarm__)/!defined(__HAIKU__) \&\& !defined(__managarm__) \&\& !defined(__sun)/' "$UT" 2>/dev/null || true

# alloca lives in <alloca.h> on illumos.
MAC="$sd/src/util/macros.h"
if [ -f "$MAC" ] && ! grep -q alloca.h "$MAC"; then
  sed -i 's|#include <stdio.h>|#include <stdio.h>\n#ifdef __sun\n#include <alloca.h>\n#endif|' "$MAC" 2>/dev/null || true
fi

# illumos has no futex(2). ANV's anv_allocator.c calls futex_wake/futex_wait
# unconditionally (state-pool grow path). Add a portable illumos impl: one
# global mutex+condvar, wake broadcasts, wait rechecks the value word. Spurious
# wakeups are fine (all callers loop). Sets UTIL_FUTEX_SUPPORTED=1 for __sun.
FXH="$sd/src/util/futex.h"
if [ -f "$FXH" ] && ! grep -q '__sun' "$FXH"; then
  python3 - "$FXH" <<'PYFH'
import sys
p=sys.argv[1]; s=open(p).read()
old="#elif defined(_WIN32) && !defined(WINDOWS_NO_FUTEX)\n#define UTIL_FUTEX_SUPPORTED 1"
new=("#elif defined(__sun)\n#define UTIL_FUTEX_SUPPORTED 1\n"
     "#elif defined(_WIN32) && !defined(WINDOWS_NO_FUTEX)\n#define UTIL_FUTEX_SUPPORTED 1")
open(p,"w").write(s.replace(old,new,1))
PYFH
fi
FXC="$sd/src/util/futex.c"
if [ -f "$FXC" ] && ! grep -q '__sun' "$FXC"; then
  python3 - "$FXC" <<'PYFC'
import sys
p=sys.argv[1]; s=open(p).read()
sun=("#elif defined(__sun)\n\n"
     "/* illumos has no futex(2); portable fallback: one global mutex+condvar.\n"
     " * futex: global lock, one shared condvar for all addresses -- fine here\n"
     " * (low-contention pool-grow path). Per-address hashing if it ever matters. */\n"
     "#include <pthread.h>\n#include <errno.h>\n#include <time.h>\n"
     "static pthread_mutex_t futex_mtx = PTHREAD_MUTEX_INITIALIZER;\n"
     "static pthread_cond_t  futex_cnd = PTHREAD_COND_INITIALIZER;\n\n"
     "int futex_wake(uint32_t *addr, int count)\n{\n"
     "   (void)addr; (void)count;\n"
     "   pthread_mutex_lock(&futex_mtx);\n"
     "   pthread_cond_broadcast(&futex_cnd);\n"
     "   pthread_mutex_unlock(&futex_mtx);\n   return 0;\n}\n\n"
     "int futex_wait(uint32_t *addr, int32_t value, const struct timespec *timeout)\n{\n"
     "   int ret = 0;\n"
     "   pthread_mutex_lock(&futex_mtx);\n"
     "   if (*(volatile uint32_t *)addr == (uint32_t)value) {\n"
     "      if (timeout)\n"
     "         ret = pthread_cond_timedwait(&futex_cnd, &futex_mtx, timeout);\n"
     "      else\n"
     "         ret = pthread_cond_wait(&futex_cnd, &futex_mtx);\n"
     "   }\n"
     "   pthread_mutex_unlock(&futex_mtx);\n"
     "   return ret == ETIMEDOUT ? ETIMEDOUT : 0;\n}\n\n")
old="#else\n#error UTIL_FUTEX_SUPPORTED is not implemented"
open(p,"w").write(s.replace(old, sun+"#else\n#error UTIL_FUTEX_SUPPORTED is not implemented",1))
PYFC
fi

# getpwuid_r is the 4-arg SunOS form (returns struct passwd*).
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

# --- THE load-bearing ANV ioctl fix: the bundled include/drm-uapi/drm.h BSD
#     branch pulls illumos <sys/ioccom.h> (IOCPARM_MASK=0xff -- WRONG encoding).
#     The i915/xe ioctl numbers (DRM_IOCTL_XE_*, DRM_IOCTL_I915_*) are built from
#     _IOWR/_IOW/_IOR there. Override with the Linux _IOC encoding (matches the
#     C1 kernel drm.h) by injecting the shim right after the <sys/ioccom.h>. ---
DUH="$sd/include/drm-uapi/drm.h"
if [ -f "$DUH" ] && ! grep -q linux-ioctl-compat "$DUH"; then
  cp "$SHIM" "$sd/include/drm-uapi/linux-ioctl-compat.h"
  sed -i 's|#include <sys/ioccom.h>|#include <sys/ioccom.h>\n#include "linux-ioctl-compat.h"|' "$DUH" 2>/dev/null || true
fi
# libsync.h (util) also uses _IOWR on __sun; give it the Linux encoding too.
LS="$sd/src/util/libsync.h"
if [ -f "$LS" ] && ! grep -q linux-ioctl-compat "$LS"; then
  cp "$SHIM" "$sd/src/util/linux-ioctl-compat.h"
  sed -i 's|#include <sys/ioctl.h>|#include <sys/ioctl.h>\n#ifdef __sun\n#include "linux-ioctl-compat.h"\n#endif|' "$LS" 2>/dev/null || true
fi

out="/var/tmp/mesa-anv-out"; mkdir -p "$out"
cat > /var/tmp/native-anv.$$.ini <<NFEOF
[binaries]
c = '$CC'
cpp = '$CXX'
pkgconfig = '/usr/bin/pkg-config'
NFEOF

log="/var/tmp/mesa-anv.build.log"
(
cd "$sd"
[ -d _banv ] && MESON_SETUP_ARGS="--reconfigure" || MESON_SETUP_ARGS=""
"$MESON" setup _banv $MESON_SETUP_ARGS --prefix="$out" --libdir=lib --buildtype=release \
  --wrap-mode=nodownload \
  --native-file /var/tmp/native-anv.$$.ini \
  -Dgallium-drivers=swrast \
  -Dc_args="-Wno-error=incompatible-pointer-types -Wno-error=pointer-sign" \
  -Dcpp_args="-Wno-error=incompatible-pointer-types" \
  -Dvulkan-drivers=intel \
  -Dvideo-codecs= \
  -Dplatforms= \
  -Dllvm=disabled \
  -Dosmesa=false \
  -Dglx=disabled -Degl=disabled -Dgbm=disabled -Ddri3=disabled \
  -Dgles1=disabled -Dgles2=disabled -Dopengl=true \
  -Dshared-glapi=enabled -Dzstd=disabled \
&& "$NINJA" -C _banv -j"$NPROC" \
&& "$NINJA" -C _banv install
) >"$log" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  echo "RESULT mesa-anv FAIL build (rc=$rc)"
  grep -E "FAILED:| error:|fatal error|not found|Dependency|Program|Run-time|ERROR|meson.build|Problem|required|undefined" "$log" | head -80 | sed 's/^/  /'
  echo "  --- log: $log ---"; exit 1
fi
echo "RESULT mesa-anv OK $out"
echo "  anv vulkan: $(ls "$out"/lib/libvulkan_intel* 2>/dev/null)"
echo "  anv icd:    $(ls "$out"/share/vulkan/icd.d/intel_icd* 2>/dev/null)"
echo "  log:        $log"
