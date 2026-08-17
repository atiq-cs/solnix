#!/bin/bash
# apply-solnix-thunk-patches.sh - apply the 3-line illumos delta to a fresh
# ROCT-Thunk-Interface clone so it builds against the solnix KFD UAPI.
#
#   git clone --depth 1 https://github.com/ROCm/ROCT-Thunk-Interface
#   ./apply-solnix-thunk-patches.sh /path/to/ROCT-Thunk-Interface
#   ./build-libhsakmt-solnix.sh
#
# The ONLY source-code change to upstream is these two headers; every .c is
# upstream-unmodified (all illumos adaptation is header shims force-included by
# the build recipe). Idempotent.
set -e
ROCT="${1:-/root/ROCT-Thunk-Interface}"
ROCM="$(cd "$(dirname "$0")" && pwd)"

K="$ROCT/include/hsakmt/linux/kfd_ioctl.h"
T="$ROCT/include/hsakmt/hsakmttypes.h"

# 1) kfd_ioctl.h: pull the _IOC macros + __u32 types from the solnix shim
#    instead of <libdrm/drm.h> + <linux/ioctl.h>.
if grep -q '#include <libdrm/drm.h>' "$K"; then
	sed -i 's|#include <libdrm/drm.h>|#include "solnix-ioctl-compat.h"|; /#include <linux\/ioctl.h>/d' "$K"
	cp "$ROCM/linux-ioctl-compat.h" "$ROCT/include/hsakmt/linux/solnix-ioctl-compat.h"
	echo "patched: $K"
else
	echo "already patched: $K"
fi

# 2) hsakmttypes.h: give illumos (__sun) the same HSAuint* typedefs as __linux__.
if grep -q '^#elif defined(__linux__)$' "$T"; then
	sed -i 's/^#elif defined(__linux__)$/#elif defined(__linux__) || defined(__sun)/' "$T"
	echo "patched: $T"
else
	echo "already patched: $T"
fi
