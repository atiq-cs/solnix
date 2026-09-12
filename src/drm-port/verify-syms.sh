#!/bin/sh
# verify-syms.sh - zero-phantom check for the `drm` ET_REL module.
#
# Every UNDEF symbol in the linked `drm` object must resolve to a symbol that a
# real illumos kernel module (unix/genunix/specfs/other misc drivers) or the
# illumos `virtio` framework module exports. Any UNDEF that resolves nowhere is
# a phantom (a Linux/NetBSD symbol with no illumos backing) and fails the build.

set -e
cd "$(dirname "$0")"

# The module to audit (default `drm`; `make kfd` passes `drm-full`).
MODULE="${1:-drm}"

# comm(1) requires both inputs in the same collation order; force C locale so
# the mixed-case kernel symbol list and the drm undef list sort identically.
export LC_ALL=C

KMODS="/kernel/misc/amd64/virtio"
for m in /platform/i86pc/kernel/amd64/unix /kernel/amd64/genunix \
         /kernel/misc/amd64/* /kernel/fs/amd64/specfs; do
	[ -f "$m" ] && KMODS="$KMODS $m"
done

for m in $KMODS; do
	elfdump -s "$m" 2>/dev/null | grep "GLOB" | grep -v UNDEF | awk '{print $NF}'
done | sort -u > /tmp/kernel_syms.txt

elfdump -s "$MODULE" 2>/dev/null | grep UNDEF | awk '{print $NF}' \
	| grep -v '^UNDEF$' | grep -v '^$' | sort -u > /tmp/drm_undef.txt

PHANTOM=$(comm -23 /tmp/drm_undef.txt /tmp/kernel_syms.txt || true)
NUNDEF=$(wc -l < /tmp/drm_undef.txt | tr -d ' ')
if [ -n "$PHANTOM" ]; then
	echo "PHANTOM SYMBOLS (resolve to no illumos KPI / virtio export):"
	echo "$PHANTOM"
	exit 1
fi
echo "zero-phantom OK: all $NUNDEF undefined symbols resolve to illumos KPI or virtio exports"
