#!/bin/sh
# build-module.sh -- link the i915 kernel module on dixi and check it against
# the running kernel, the same gates as src/wifi-port/iwm/build-dixi.sh:
#   1. every undefined symbol of the module is defined by the running
#      kernel (unix + genunix);
#   2. no global the module defines is already defined by the kernel or by
#      ANY loaded module (/dev/ksyms): krtld would bind the module's
#      references to the kernel's copy (kobj.c do_symbols); only _init,
#      _fini and _info may share a name.
# Nothing is loaded.
#
# Usage (on dixi): build-module.sh OBSD_DRM_DIR PORT_DIR OUT_DIR FILES_TXT
#   PORT_DIR is the src/drm-port copy (obsd-compat/ and i915/ under it).
#   env: GATE_INC, JOBS (4), XFLAGS, CC, NM (gnm), LD (/usr/bin/ld).
#   OBJS_FROM=DIR reuses the drm objects link-gap.sh left in DIR/obj.
set -u
obsd=$1 port=$2 out=$3 files=$4
compat=$port/obsd-compat
: "${GATE_INC:=/nix/store/s7zkx8nx5sfxixmyqmlnrybrrh14jkmb-illumos-gate-proto/usr/include}"
: "${JOBS:=4}" "${XFLAGS:=}" "${CC:=gcc}" "${NM:=gnm}" "${LD:=/usr/bin/ld}"
: "${OBJS_FROM:=}"
mkdir -p "$out/obj"
F="-m64 -mcmodel=kernel -mno-red-zone -D_KERNEL -ffreestanding -nostdinc -std=gnu11 \
 -O2 -fno-strict-aliasing $XFLAGS -include $compat/obsd_prelude.h -I$compat \
 -I$obsd/include -I$obsd/include/uapi -I$obsd -I$obsd/i915 -I$GATE_INC"
if [ -n "$OBJS_FROM" ]; then
	cp "$OBJS_FROM"/obj/*.o "$out/obj/"
else
	cd "$obsd" || exit 1
	n=0
	for f in $(cat "$files"); do
		o="$out/obj/$(echo "$f" | tr / _).o"
		$CC $F -c "$f" -o "$o" > "$o.log" 2>&1 &
		n=$((n + 1)); [ $((n % JOBS)) -eq 0 ] && wait
	done
	wait
fi
nobj=$(ls "$out"/obj/*.o | wc -l)
(cd "$compat" && gmake obj > "$out/compat.log" 2>&1) || { tail "$out/compat.log"; exit 1; }
$CC $F -I$port/i915 -I$port/i915/openbsd-orig/include -Werror -Wall \
    -c "$port/i915/i915_illumos.c" -o "$out/i915_illumos.o" || exit 1
$CC -m64 -mcmodel=kernel -mno-red-zone -D_KERNEL -ffreestanding -nostdinc \
    -std=gnu11 -O2 -Wall -Werror -I$port/i915/openbsd-orig/include -I$port/i915 \
    -I$GATE_INC -c "$port/i915/i915_pciid.c" -o "$out/i915_pciid.o" || exit 1
$LD -r -o "$out/i915" "$out"/obj/*.o "$compat"/obsd_*.o "$out/i915_illumos.o" \
    "$out/i915_pciid.o" > "$out/ld.log" 2>&1 || { cat "$out/ld.log"; exit 1; }
for k in /platform/i86pc/kernel/amd64/unix /kernel/amd64/genunix; do
	$NM -g --defined-only "$k" | awk '{print $3}'
done | sort -u > "$out/kernel.txt"
# /dev/ksyms is the symbol table of the kernel AND every loaded module.
# gnm cannot read the character device itself (measured: 0 symbols, which
# would make the collision gate pass vacuously), so copy it to a file first.
cat /dev/ksyms > "$out/ksyms.elf"
$NM -g --defined-only "$out/ksyms.elf" | awk '{print $3}' | sort -u > "$out/ksyms-all.txt"
if [ "$(wc -l < "$out/ksyms-all.txt")" -lt 10000 ]; then
	echo "ksyms snapshot has only $(wc -l < "$out/ksyms-all.txt") symbols: refusing a vacuous collision gate"
	exit 1
fi
$NM -u "$out/i915" | awk '{print $2}' | sort -u > "$out/undef.txt"
$NM -g --defined-only "$out/i915" | awk '{print $3}' | sort -u > "$out/defined.txt"
comm -23 "$out/undef.txt" "$out/kernel.txt" > "$out/unresolved.txt"
comm -12 "$out/defined.txt" "$out/ksyms-all.txt" | grep -v -x -E '_init|_fini|_info' > "$out/collide.txt"
echo "drm objects: $nobj  module: $(ls -l "$out/i915" | awk '{print $5}') bytes" \
    " text+data+bss: $(size "$out/i915" 2>/dev/null | tail -1)"
echo "undefined: $(wc -l < "$out/undef.txt")  unresolved vs running unix+genunix:" \
    "$(wc -l < "$out/unresolved.txt")  name collisions vs /dev/ksyms" \
    "($(wc -l < "$out/ksyms-all.txt") syms): $(wc -l < "$out/collide.txt")"
cat "$out/unresolved.txt" "$out/collide.txt"
test ! -s "$out/unresolved.txt" && test ! -s "$out/collide.txt"
