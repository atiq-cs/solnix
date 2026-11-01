#!/usr/bin/env bash
# build-vfd.sh -- the NEGATIVE CONTROL builds for rvsh: dash and sbase-box linked against the
# glue WITH rvpkg's userland fd table (built without -DSOLNIX_NO_VFD). Every package is now built
# -DSOLNIX_NO_VFD (build-all-pkgs.sh); these "-vfd" builds keep the old STUB so stage-vfd.sh /
# vfd.checks can show that the exec'd-program pipe/redirect checks depend on dropping it.
# Reuses the dash objects from build-dash.sh's tree; rebuilds sbase into a temp dir.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$HOME/scratch/rvsh/out}"
DASH="${DASH:-$HOME/ws/rvpkg/dl/dash-0.5.12}"
"$HERE/solnix-cc" -O2 -c "$HERE/solnix-libc/glue.c" -o "$OUT/glue-vfd.o"
( cd "$DASH/src" && SOLNIX_GLUE="$OUT/glue-vfd.o" "$HERE/solnix-cc" -O2 -o "$OUT/dash-vfd" *.o bltin/*.o )
T="$(mktemp -d)"
SOLNIX_GLUE="$OUT/glue-vfd.o" OUT="$T" bash "$HERE/build-sbase.sh" | tail -1
cp "$T/sbase-box" "$OUT/sbase-box-vfd"; find "$T" -delete
echo VFD_DONE "$(sha256sum "$OUT/dash-vfd" "$OUT/sbase-box-vfd" | cut -c1-16 | tr '\n' ' ')"
