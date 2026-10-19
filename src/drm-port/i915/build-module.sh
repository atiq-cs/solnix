#!/bin/sh
# build-module.sh -- link the i915 kernel module on dixi and check it against
# the running kernel, the same gates as src/ports/wifi/iwm/build-dixi.sh:
#   1. every undefined symbol of the module is defined by the running
#      kernel (unix + genunix) or by a module named in the i915 module's
#      _depends_on (misc/gfx_private, the console framebuffer code krtld
#      loads before i915);
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
# KROOT: root of the target kernel tree (default the running one, /).
: "${KROOT:=}"
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
# i915_drmglue.c includes OpenBSD's drm/i915 headers, so it is built the way
# the OpenBSD objects are (their headers do not pass -Wall -Werror here:
# the OpenBSD kprintf format attribute, redefined Linux macros).
$CC $F -I$port/i915 -c "$port/i915/i915_drmglue.c" -o "$out/i915_drmglue.o" \
    > "$out/drmglue.log" 2>&1 || { grep -E 'error|Error' "$out/drmglue.log"; exit 1; }
grep -E 'i915_drmglue.c:[0-9]+:[0-9]+: warning' "$out/drmglue.log"
$CC -m64 -mcmodel=kernel -mno-red-zone -D_KERNEL -ffreestanding -nostdinc \
    -std=gnu11 -O2 -Wall -Werror -I$port/i915/openbsd-orig/include -I$port/i915 \
    -I$GATE_INC -c "$port/i915/i915_pciid.c" -o "$out/i915_pciid.o" || exit 1
# -Breduce + the mapfile scope every symbol local except the module interface
# krtld looks up by name (_init/_fini/_info/_depends_on). Without this the
# OpenBSD-compat globals (tsleep, bus_dmamap_*, timeout_*, ...) stay global and
# krtld cross-wires them against any other loaded compat module (iwm). See
# i915.mapfile. Path is relative to this script, found via the port dir.
mapfile=$port/i915/i915.mapfile
$LD -r -Breduce -M "$mapfile" -o "$out/i915" "$out"/obj/*.o "$compat"/obsd_*.o "$out/i915_illumos.o" \
    "$out/i915_drmglue.o" "$out/i915_pciid.o" > "$out/ld.log" 2>&1 || { cat "$out/ld.log"; exit 1; }
for k in $KROOT/platform/i86pc/kernel/amd64/unix $KROOT/kernel/amd64/genunix \
    $KROOT/platform/i86pc/kernel/misc/amd64/gfx_private; do
	$NM -g --defined-only "$k" | awk '{print $3}'
done | sort -u > "$out/kernel.txt"
# /dev/ksyms is the symbol table of the kernel AND every loaded module.
# gnm cannot read the character device itself (measured: 0 symbols, which
# would make the collision gate pass vacuously), so copy it to a file first.
# KSYMS: a saved copy of the target's /dev/ksyms (default: read it live).
cat "${KSYMS:-/dev/ksyms}" > "$out/ksyms.elf"
$NM -g --defined-only "$out/ksyms.elf" | awk '{print $3}' | sort -u > "$out/ksyms-all.txt"
if [ "$(wc -l < "$out/ksyms-all.txt")" -lt 10000 ]; then
	echo "ksyms snapshot has only $(wc -l < "$out/ksyms-all.txt") symbols: refusing a vacuous collision gate"
	exit 1
fi
$NM -u "$out/i915" | awk '{print $2}' | sort -u > "$out/undef.txt"
$NM -g --defined-only "$out/i915" | awk '{print $3}' | sort -u > "$out/defined.txt"
comm -23 "$out/undef.txt" "$out/kernel.txt" > "$out/unresolved.txt"
comm -12 "$out/defined.txt" "$out/ksyms-all.txt" | grep -v -E '^(_init|_fini|_info)$' > "$out/collide.txt"
# Load-order-independent gate: the linked module must export NOTHING but the
# kernel loader interface (_init/_fini/_info/_depends_on). This proves the
# i915.mapfile reduction took effect and catches the OpenBSD-compat global
# cross-wiring defect even when the other compat module (iwm) is not loaded.
# Same logic as scripts/check-compat-local.sh, inlined so the build is self-
# contained on dixi (the port tree is scp'd without the repo's scripts/).
grep -v -E '^(_init|_fini|_info|_depends_on)$' "$out/defined.txt" > "$out/compat-local.txt" || true
echo "drm objects: $nobj  module: $(ls -l "$out/i915" | awk '{print $5}') bytes" \
    " text+data+bss: $(size "$out/i915" 2>/dev/null | tail -1)"
echo "undefined: $(wc -l < "$out/undef.txt")  unresolved vs running unix+genunix:" \
    "$(wc -l < "$out/unresolved.txt")  name collisions vs /dev/ksyms" \
    "($(wc -l < "$out/ksyms-all.txt") syms): $(wc -l < "$out/collide.txt")" \
    " non-interface exported globals: $(wc -l < "$out/compat-local.txt")"
cat "$out/unresolved.txt" "$out/collide.txt" "$out/compat-local.txt"
test ! -s "$out/unresolved.txt" && test ! -s "$out/collide.txt" && test ! -s "$out/compat-local.txt"
