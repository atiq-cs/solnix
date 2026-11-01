#!/bin/sh
# link-gap.sh -- after union-probe.sh reports files clean, compile them to
# kernel objects and list every undefined symbol that neither another of
# those objects, the compat layer's obsd_kern.o, nor the running illumos
# kernel (unix + genunix) defines. That list is the compat layer's real
# remaining implementation work: a declaration that parses is not a body.
#
# Usage: link-gap.sh OBSD_DRM_DIR COMPAT_DIR OUT_DIR FILES_TXT
#   env: GATE_INC, JOBS (4), XFLAGS, CC, NM (gnm).
set -u
# KROOT: root of the target kernel tree (default the running one, /).
: "${KROOT:=}"
obsd=$1 compat=$2 out=$3 files=$4
: "${GATE_INC:=/nix/store/s7zkx8nx5sfxixmyqmlnrybrrh14jkmb-illumos-gate-proto/usr/include}"
: "${JOBS:=4}" "${XFLAGS:=}" "${CC:=gcc}" "${NM:=gnm}"
mkdir -p "$out/obj"
# -mno-mmx -mno-sse: the gate kernel's NO_SIMD, as build-module.sh.
F="-m64 -mcmodel=kernel -mno-red-zone -mno-mmx -mno-sse -D_KERNEL -ffreestanding -nostdinc -std=gnu11 \
 -O2 -fno-strict-aliasing $XFLAGS -include $compat/obsd_prelude.h -I$compat \
 -I$obsd/include -I$obsd/include/uapi -I$obsd -I$obsd/i915 -I$GATE_INC"
cd "$obsd" || exit 1
n=0
for f in $(cat "$files"); do
	o="$out/obj/$(echo "$f" | tr / _).o"
	$CC $F -c "$f" -o "$o" > "$o.log" 2>&1 &
	n=$((n + 1)); [ $((n % JOBS)) -eq 0 ] && wait
done
wait
ok=$(ls "$out"/obj/*.o 2>/dev/null | wc -l)
for k in $KROOT/platform/i86pc/kernel/amd64/unix $KROOT/kernel/amd64/genunix; do
	$NM -g --defined-only "$k" | awk '{print $3}'
done | sort -u > "$out/kernel.txt"
# every compat-layer kernel object (obsd_kern.o, obsd_time.o, ...)
for o in "$out"/obj/*.o "$compat"/obsd_*.o; do
	$NM -g --defined-only "$o" | awk '{print $3}'
done | sort -u > "$out/defined.txt"
for o in "$out"/obj/*.o; do $NM -u "$o" | awk '{print $2}'; done | sort | uniq -c |
    sort -rn > "$out/undef-counts.txt"
awk '{print $2}' "$out/undef-counts.txt" | sort -u > "$out/undef.txt"
comm -23 "$out/undef.txt" "$out/defined.txt" | comm -23 - "$out/kernel.txt" > "$out/gap.txt"
comm -12 "$out/defined.txt" "$out/kernel.txt" > "$out/collide.txt"
warn=$(cat "$out"/obj/*.log | grep -c ' warning: ')
echo "objects: $ok/$n  warnings: $warn  undefined: $(wc -l < "$out/undef.txt")" \
    "  gap (defined nowhere): $(wc -l < "$out/gap.txt")" \
    "  module/kernel name collisions: $(wc -l < "$out/collide.txt")"
