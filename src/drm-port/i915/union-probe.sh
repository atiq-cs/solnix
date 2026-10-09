#!/bin/sh
# union-probe.sh -- compile every inteldrm + drm-core source listed in
# OpenBSD's files.drm, UNMODIFIED, against illumos + src/drm-port/obsd-compat,
# and report how many compile with zero errors.
#
# Usage: union-probe.sh OBSD_DRM_DIR COMPAT_DIR OUT_DIR
#   env: GATE_INC (illumos proto usr/include), JOBS (default 4), CC,
#        XFLAGS (extra cpp flags, e.g. "-D__HAVE_ACPI -DNACPI=1").
#
# Headers still missing after the compat dir are created EMPTY in
# OUT_DIR/stubs (measurement scaffolding, never part of the port) and listed
# in OUT_DIR/stubs.txt, so the clean count never hides a missing header.
#
# The clean count reads only the per-file logs named from files.txt. (An
# earlier version globbed *.err and counted an empty concatenation file as
# one clean source: the "1/377" baseline was really 0/377.)
set -u
obsd=$1 compat=$2 out=$3
: "${GATE_INC:=/nix/store/s7zkx8nx5sfxixmyqmlnrybrrh14jkmb-illumos-gate-proto/usr/include}"
: "${JOBS:=4}"
: "${CC:=gcc}"
: "${XFLAGS:=}"
S=$out/stubs L=$out/logs
mkdir -p "$S" "$L"
# SET=377 (default): files.drm entries tagged drm or inteldrm, the set the
# earlier survey measured. SET=full: also the ttm entries (inteldrm depends
# on ttm in files.drm) and drm_drv.c, which sys/conf/files lists as
# "drm needs-flag" -- the complete inteldrm kernel closure minus AGP.
: "${SET:=377}"
awk -v set="$SET" '$1=="file" && ($3=="drm" || $0 ~ /inteldrm/ ||
    (set=="full" && $3=="ttm" && NF==3)) {sub("dev/pci/drm/","",$2); print $2}' \
    "$obsd/files.drm" > "$out/files.txt"
[ "$SET" = full ] && echo drm_drv.c >> "$out/files.txt"
F="-m64 -mcmodel=kernel -mno-red-zone -D_KERNEL -ffreestanding -nostdinc -std=gnu11 \
 -fno-strict-aliasing $XFLAGS -include $compat/obsd_prelude.h -I$compat \
 -I$obsd/include -I$obsd/include/uapi -I$obsd -I$obsd/i915 -I$GATE_INC -I$S"
cd "$obsd" || exit 1
# Pass 1: grow the empty-stub set until no file stops at a missing header.
for round in 1 2 3 4 5 6; do
	added=0
	for f in $(cat "$out/files.txt"); do
		[ -f "$f" ] || continue
		k=0
		while [ $k -lt 100 ]; do
			m=$($CC $F -fsyntax-only "$f" 2>&1 |
			    sed -n 's/.*fatal error: \([^:]*\.h\): No such file or directory.*/\1/p' | head -1)
			[ -z "$m" ] && break
			[ -f "$S/$m" ] && { echo "stub loop: $f $m" >&2; break; }
			mkdir -p "$S/$(dirname "$m")"; : > "$S/$m"; added=$((added + 1)); k=$((k + 1))
		done
	done
	[ $added -eq 0 ] && break
done
(cd "$S" && find . -type f | sed 's,^\./,,' | sort) > "$out/stubs.txt"
# Pass 2: full logs, JOBS at a time.
n=0
for f in $(cat "$out/files.txt"); do
	[ -f "$f" ] || continue
	$CC $F -fsyntax-only -fmax-errors=0 "$f" > "$L/$(echo "$f" | tr / _).err" 2>&1 &
	n=$((n + 1))
	[ $((n % JOBS)) -eq 0 ] && wait
done
wait
clean=0; : > "$out/clean.txt"; : > "$out/per-file.txt"
for f in $(cat "$out/files.txt"); do
	e="$L/$(echo "$f" | tr / _).err"
	[ -f "$e" ] || continue
	c=$(grep -c ' error: ' "$e")
	echo "$c $f" >> "$out/per-file.txt"
	[ "$c" -eq 0 ] && { clean=$((clean + 1)); echo "$f" >> "$out/clean.txt"; }
done
sort -n "$out/per-file.txt" -o "$out/per-file.txt"
for f in $(cat "$out/files.txt"); do cat "$L/$(echo "$f" | tr / _).err" 2>/dev/null; done > "$out/all.txt"
grep ' error: ' "$out/all.txt" | sed 's/.* error: //' | sed "s/'[^']*'/Q/g" |
    sort | uniq -c | sort -rn | head -40 > "$out/top-shapes.txt"
grep -o " error: .*" "$out/all.txt" | sort | uniq -c | sort -rn | head -60 > "$out/top-errors.txt"
grep -ho "implicit declaration of function .[A-Za-z_0-9]*" "$out/all.txt" | sed "s/.* .//" |
    sort | uniq -c | sort -rn > "$out/funcs.txt"
grep -ho "unknown type name .[A-Za-z_0-9]*" "$out/all.txt" | sed "s/.* .//" |
    sort | uniq -c | sort -rn > "$out/types.txt"
grep -ho "error: .[A-Za-z_0-9]*. undeclared" "$out/all.txt" | sed "s/error: .//; s/. undeclared//" |
    sort | uniq -c | sort -rn > "$out/undeclared.txt"
echo "compiled: $n  clean: $clean  error lines: $(grep -c ' error: ' "$out/all.txt")" \
    "  stubs: $(wc -l < "$out/stubs.txt")  funcs: $(wc -l < "$out/funcs.txt")" \
    "  types: $(wc -l < "$out/types.txt")  undeclared: $(wc -l < "$out/undeclared.txt")"
