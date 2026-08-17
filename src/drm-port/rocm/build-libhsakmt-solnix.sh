#!/bin/bash
# build-libhsakmt-solnix.sh - compile libhsakmt (ROCT-Thunk-Interface) for
# illumos x86_64 against the solnix KFD uapi.
#
# The KFD ABI (AMDKFD_IOC_*) is already ours (src/drm-port/amdkfd/uapi/
# kfd_ioctl.h == the Linux v1.14 crib), so the thunk's hsaKmt* API maps 1:1
# onto the /dev/kfd ioctls the C3-KFD driver dispatches. The illumos
# adaptations are all in the -include/-I shims below (no Linux .c is touched
# except the __linux__|__sun typedef guard + the libdrm/linux-ioctl include
# swap in the two shipped headers):
#   solnix-compat.h       : alloca<->stdlib, MADV_* Linux hints -> 0 no-ops
#   rocm/numa.h,numaif.h  : libnuma stub (numa_available()==-1, binding no-ops)
#   rocm/linux/perf_event.h : just PERF_EVENT_IOC_* for perfctr.c
#   linux-ioctl-compat.h  : the Linux _IOC encoding (shared with RADV/ANV)
#   libdrm headers        : from the RADV libdrm build (/var/tmp/libdrm-out)
set -e

ROCT=/root/ROCT-Thunk-Interface
ROCM=/root/drm-port/rocm
LIBDRM=/var/tmp/libdrm-out/include/libdrm

CFLAGS="-fPIC -O2 -Wall -fno-strict-aliasing"
INC="-I$ROCT/include -I$ROCT/src -I$ROCM -I$LIBDRM"
FORCE="-include $ROCM/solnix-compat.h"

OUT=$ROCM/build
mkdir -p "$OUT"

SRCS="globals time libhsakmt openclose version queues memory events svm debug \
spm topology fmm perfctr pc_sampling pmc_table rbtree"

OBJS=""
for f in $SRCS; do
	echo "  CC   $f.c"
	gcc -c $CFLAGS $INC $FORCE "$ROCT/src/$f.c" -o "$OUT/$f.o"
	OBJS="$OBJS $OUT/$f.o"
done

echo "  LINK libhsakmt.so.1"
gcc -shared -fPIC -o "$OUT/libhsakmt.so.1" $OBJS -lpthread -ldl -lrt
ln -sf libhsakmt.so.1 "$OUT/libhsakmt.so"

echo "built: $OUT/libhsakmt.so.1"
ls -l "$OUT/libhsakmt.so.1"
