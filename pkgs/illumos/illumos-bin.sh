#!/usr/bin/bash
# illumos-bin.sh: sourced by store-only builders. Finds the illumos elfedit/elfdump/ldd/digest (the world's usr/bin, a
# nativeTools entry) on PATH and exports ILLUMOS_BIN for the shared gate scripts (zero-checksum.sh, ts-errno-gate.sh,
# store-gate.sh) and IB for the builder's own text. Never /usr/gnu/bin's GNU elfedit (a different program: an exempt OI PATH
# found it first, and every DT_CHECKSUM edit failed; chef P0 run c). Fails the build when none is on PATH.
ILLUMOS_BIN=""; _o=$IFS; IFS=:
for _d in $PATH; do [ -x "$_d/elfedit" ] && [ -x "$_d/elfdump" ] && [ -x "$_d/digest" ] && { ILLUMOS_BIN=$_d; break; }; done
IFS=$_o
[ -n "$ILLUMOS_BIN" ] || { echo "FATAL: illumos-bin.sh: no illumos elfedit/elfdump/digest on PATH" >&2; exit 1; }
"$ILLUMOS_BIN/elfedit" -h 2>&1 | grep -q 'GNU' && { echo "FATAL: illumos-bin.sh: $ILLUMOS_BIN/elfedit is GNU elfedit" >&2; exit 1; }
export ILLUMOS_BIN; IB=$ILLUMOS_BIN
