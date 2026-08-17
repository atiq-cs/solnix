#!/bin/bash
# audit-undef.sh - zero-phantom audit for libhsakmt.so (the KFD thunk).
# Every dynamic undef must resolve to a real illumos library:
#   libc, libpthread, librt, libdl (the POSIX/libc KPI + ioctl/mmap path)
#   libdrm / libdrm_amdgpu (the DRM userspace the thunk dlopen's/links for
#     render-node open + amdgpu_device_* -- from the RADV libdrm build)
# plus the linker-synthesized _ITM_*/__cxa_finalize (compiler runtime,
# defined by crtstuff into any consumer at final link).
#
# Uses BSD-portable `nm -p`: "<addr> <type> <name>", type 'U' = undefined.
set -e
SO=/root/drm-port/rocm/build/libhsakmt.so.1
LIBS="/lib/64/libc.so.1 /lib/64/libpthread.so.1 /lib/64/librt.so.1 \
/lib/64/libdl.so.1 /var/tmp/libdrm-out/lib/libdrm.so.2 \
/var/tmp/libdrm-out/lib/libdrm_amdgpu.so.1"

# defined symbols across all resolver libs (type != U)
for l in $LIBS; do nm -p -D "$l" 2>/dev/null | awk '$2!="U"{print $3}'; done \
	| sort -u > /tmp/defined-syms.txt

echo "=== undef -> resolution ==="
PHANTOM=0; TOTAL=0
for s in $(nm -p -D "$SO" 2>/dev/null | awk '$2=="U"{print $3}' | sort -u); do
  [ -z "$s" ] && continue
  TOTAL=$((TOTAL+1))
  case "$s" in
    _ITM_*|__cxa_finalize|__cxa_atexit|_GLOBAL_OFFSET_TABLE_|__gmon_start__)
      echo "  $s -> compiler-runtime (crt, resolved at consumer link)"; continue;;
  esac
  if grep -qx "$s" /tmp/defined-syms.txt; then
    echo "  $s -> OK"
  else
    echo "  $s -> *** PHANTOM ***"; PHANTOM=$((PHANTOM+1))
  fi
done
echo "=== total undef: $TOTAL   phantom: $PHANTOM ==="
[ "$PHANTOM" = 0 ] && echo "zero-phantom OK: all undef resolve to real illumos libs"
