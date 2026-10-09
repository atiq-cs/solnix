#!/bin/sh
# probe-headers.sh -- measure how far an UNMODIFIED OpenBSD drm source file
# gets against illumos kernel headers, past the header wall.
#
# Loop: compile; if gcc stops at "fatal error: X: No such file", create an
# EMPTY X in a scratch stub dir and retry. When no header is missing any
# more, the remaining errors are the real KPI gap (undeclared types and
# functions), which is what the compat layer has to supply.
#
# The stubs are measurement scaffolding, never part of the port: they live
# in $STUB (default /var/tmp/streamE2/probe-stubs/<file>), outside the repo.
#
# Usage: probe-headers.sh OBSD_DRM_DIR FILE.c [FILE.c ...]
#   env: GATE_INC (illumos proto usr/include), COMPAT (solnix compat dir,
#        searched before the stubs), STUB_ROOT, CC.
# Output per file: number of stubbed headers, then error count and the
# 40 most frequent "unknown identifier" names.
set -u
obsd=$1; shift
: "${GATE_INC:=/nix/store/s7zkx8nx5sfxixmyqmlnrybrrh14jkmb-illumos-gate-proto/usr/include}"
: "${STUB_ROOT:=/var/tmp/streamE2/probe-stubs}"
: "${COMPAT:=}"
: "${CC:=gcc}"
KFLAGS="-m64 -mcmodel=kernel -mno-red-zone -D_KERNEL -ffreestanding -nostdinc -std=gnu11 -fno-strict-aliasing"
for f in "$@"; do
	stub="$STUB_ROOT/$(echo "$f" | tr / _)"
	mkdir -p "$stub"
	inc="${COMPAT:+-I$COMPAT} -I$obsd/include -I$obsd/include/uapi -I$obsd -I$obsd/i915 -I$GATE_INC -I$stub"
	n=0
	while :; do
		miss=$(cd "$obsd" && $CC $KFLAGS $inc -fsyntax-only "$f" 2>&1 |
		    sed -n 's/.*fatal error: \([^:]*\): No such file or directory.*/\1/p' | head -1)
		[ -z "$miss" ] && break
		mkdir -p "$stub/$(dirname "$miss")"
		: > "$stub/$miss"
		n=$((n + 1))
		[ $n -gt 400 ] && { echo "$f: stub loop did not converge"; break; }
	done
	log="$stub.errors"
	(cd "$obsd" && $CC $KFLAGS $inc -fsyntax-only -fmax-errors=0 "$f") > "$log" 2>&1
	ne=$(grep -c ' error: ' "$log")
	echo "== $f: $n empty stub headers, $ne errors (log $log)"
	grep -o "error: [^']*'[A-Za-z_0-9]*'" "$log" |
	    sed "s/.*'\([A-Za-z_0-9]*\)'/\1/" | sort | uniq -c | sort -rn | head -40 |
	    awk '{printf "%s(%s) ", $2, $1} END {print ""}'
done
