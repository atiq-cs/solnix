#!/bin/sh
# build-libdrm.sh -- libdrm with the amdgpu module (libdrm_amdgpu) for illumos.
# RADV's amdgpu winsys links libdrm_amdgpu (>= 2.4.119). The host ships an old
# libdrm.so.2 with no amdgpu module; build a fresh libdrm from source with
# -Damdgpu=enabled. libdrm_amdgpu wraps the amdgpu DRM ioctls -- the exact
# C1/amdgpu ioctl surface. Same standalone meson+ninja+gcc pattern as the C2
# Mesa build.
set -u
export PATH=/root/mesa-venv/bin:/usr/gnu/bin:/usr/bin:$PATH
GCC=/usr/gcc/14; CC="$GCC/bin/gcc"; CXX="$GCC/bin/g++"; export CC CXX
export LD_LIBRARY_PATH="$GCC/lib/amd64:$GCC/lib:${LD_LIBRARY_PATH:-}"
MESON=/root/mesa-venv/bin/meson
NINJA=/root/mesa-venv/bin/ninja
NPROC=$(psrinfo | wc -l | tr -d ' ')
ver="${1:-2.4.120}"

[ -s /var/tmp/ca-bundle.crt ] || cat /etc/certs/CA/*.pem > /var/tmp/ca-bundle.crt 2>/dev/null || true
DLCA="--cacert /var/tmp/ca-bundle.crt"
cd /var/tmp
if [ ! -d "libdrm-$ver" ]; then
  curl -fsSLk $DLCA -o libdrm.tar.xz "https://dri.freedesktop.org/libdrm/libdrm-$ver.tar.xz" \
    || { echo "RESULT libdrm FAIL download"; exit 1; }
  python3 -c "import tarfile; tarfile.open('libdrm.tar.xz').extractall('.')" \
    || { echo "RESULT libdrm FAIL untar"; exit 1; }
fi
sd="/var/tmp/libdrm-$ver"
out="/var/tmp/libdrm-out"; mkdir -p "$out"

# --- illumos portability ---
# THE load-bearing fix: the C1 amdgpu kernel driver decodes the *Linux* _IOC
# ioctl encoding (drm-port/src/uapi/drm/drm.h reproduces the Linux _IOC scheme,
# NOT illumos <sys/ioccom.h>). So libdrm userspace must emit Linux ioctl numbers
# too. libdrm's drm.h / xf86drm.h fall into their "BSD" branch on __sun, which
# uses <sys/ioccom.h> (incompatible encoding: IOCPARM_MASK is 0xff, wrong bit
# layout). Force the Linux _IOC encoding on illumos via a shim header.
cat > /var/tmp/linux-ioctl-compat.h <<'IOCEOF'
/* Linux _IOC encoding shim for illumos -- matches drm-port/src/uapi/drm/drm.h. */
#ifndef _SOLNIX_LINUX_IOCTL_COMPAT_H_
#define _SOLNIX_LINUX_IOCTL_COMPAT_H_
#include <stdint.h>
#include <sys/types.h>
typedef int8_t   __s8;   typedef uint8_t  __u8;
typedef int16_t  __s16;  typedef uint16_t __u16;
typedef int32_t  __s32;  typedef uint32_t __u32;
typedef int64_t  __s64;  typedef uint64_t __u64;
#define _IOC_NRBITS   8
#define _IOC_TYPEBITS 8
#define _IOC_SIZEBITS 14
#define _IOC_DIRBITS  2
#define _IOC_NRSHIFT   0
#define _IOC_TYPESHIFT (_IOC_NRSHIFT + _IOC_NRBITS)
#define _IOC_SIZESHIFT (_IOC_TYPESHIFT + _IOC_TYPEBITS)
#define _IOC_DIRSHIFT  (_IOC_SIZESHIFT + _IOC_SIZEBITS)
#define _IOC_NONE  0U
#define _IOC_WRITE 1U
#define _IOC_READ  2U
#define _IOC(dir,type,nr,size) \
  (((dir)<<_IOC_DIRSHIFT)|((type)<<_IOC_TYPESHIFT)|((nr)<<_IOC_NRSHIFT)|((size)<<_IOC_SIZESHIFT))
#define _IOC_TYPECHECK(t) (sizeof(t))
#undef _IO
#undef _IOR
#undef _IOW
#undef _IOWR
#define _IO(type,nr)         _IOC(_IOC_NONE,(type),(nr),0)
#define _IOR(type,nr,size)   _IOC(_IOC_READ,(type),(nr),(_IOC_TYPECHECK(size)))
#define _IOW(type,nr,size)   _IOC(_IOC_WRITE,(type),(nr),(_IOC_TYPECHECK(size)))
#define _IOWR(type,nr,size)  _IOC(_IOC_READ|_IOC_WRITE,(type),(nr),(_IOC_TYPECHECK(size)))
#define _IOC_NR(nr)   (((nr) >> _IOC_NRSHIFT) & ((1 << _IOC_NRBITS)-1))
#define _IOC_TYPE(nr) (((nr) >> _IOC_TYPESHIFT) & ((1 << _IOC_TYPEBITS)-1))
#define _IOC_SIZE(nr) (((nr) >> _IOC_SIZESHIFT) & ((1 << _IOC_SIZEBITS)-1))
#define _IOC_DIR(nr)  (((nr) >> _IOC_DIRSHIFT) & ((1 << _IOC_DIRBITS)-1))
#endif
IOCEOF
cp /var/tmp/linux-ioctl-compat.h "$sd/include/drm/linux-ioctl-compat.h"
# drm.h __sun: use the Linux _IOC shim instead of <sys/ioccom.h>. The BSD branch
# opens with '#include <stdint.h>' + '#include <sys/ioccom.h>' + typedefs; on
# __sun include the shim (which supplies the __sN/__uN typedefs + Linux _IO*)
# and skip <sys/ioccom.h>.
DH="$sd/include/drm/drm.h"
if ! grep -q 'linux-ioctl-compat' "$DH"; then
  python3 - "$DH" <<'PYEOF'
import sys,re
p=sys.argv[1]; s=open(p).read()
# Replace the BSD-branch opener with a __sun-aware include.
s=s.replace('#else /* One of the BSDs */\n\n#include <stdint.h>\n#include <sys/ioccom.h>\n#include <sys/types.h>',
            '#else /* One of the BSDs (or illumos) */\n\n#include <stdint.h>\n#include <sys/types.h>\n#if defined(__sun)\n#include "linux-ioctl-compat.h"\n#else\n#include <sys/ioccom.h>\n#endif')
open(p,'w').write(s)
PYEOF
fi
# xf86drm.h __sun: take the Linux DRM_IOC* branch (needs _IOC_NR/_IOC_NONE/... +
# _IOC from the shim, which drm.h already pulled in on __sun).
XF="$sd/xf86drm.h"
sed -i 's|^#if defined(__linux__)$|#if defined(__linux__) \|\| defined(__sun)|' "$XF" 2>/dev/null || true
export CFLAGS="-m64 -fPIC -O2 -D__EXTENSIONS__ -D_POSIX_PTHREAD_SEMANTICS -Wno-error=incompatible-pointer-types"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-m64 -lsocket -lnsl"

cat > /var/tmp/native-libdrm.$$.ini <<NFEOF
[binaries]
c = '$CC'
cpp = '$CXX'
pkgconfig = '/usr/bin/pkg-config'
NFEOF

log="/var/tmp/libdrm.build.log"
(
cd "$sd"
"$MESON" setup _b --prefix="$out" --libdir=lib --buildtype=release \
  --wrap-mode=nodownload \
  --native-file /var/tmp/native-libdrm.$$.ini \
  -Damdgpu=enabled \
  -Dradeon=disabled -Dnouveau=disabled -Dintel=disabled -Dvmwgfx=disabled \
  -Dvc4=disabled -Dfreedreno=disabled -Detnaviv=disabled \
  -Dcairo-tests=disabled -Dman-pages=disabled -Dvalgrind=disabled \
  -Dtests=false \
  && "$NINJA" -C _b -j"$NPROC" \
  && "$NINJA" -C _b install
) >"$log" 2>&1
rc=$?
if [ $rc -ne 0 ]; then
  echo "RESULT libdrm FAIL build"
  grep -E "FAILED:| error:|fatal error|not found|Dependency|ERROR|meson.build|undefined" "$log" | head -40 | sed 's/^/  /'
  echo "  --- log: $log ---"; exit 1
fi
echo "RESULT libdrm OK $out"
echo "  amdgpu lib: $(ls "$out"/lib/libdrm_amdgpu* 2>/dev/null)"
echo "  amdgpu pc:  $(ls "$out"/lib/pkgconfig/libdrm_amdgpu.pc 2>/dev/null)"
echo "  headers:    $(ls "$out"/include/libdrm/amdgpu*.h 2>/dev/null)"
