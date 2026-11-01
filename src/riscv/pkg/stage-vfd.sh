#!/usr/bin/env bash
# stage-vfd.sh <stage-dir> -- the dash root, but /bin/dash and /bin/sbase-box are the NEGATIVE
# CONTROL builds linked against the glue WITH rvpkg's userland fd table (build-vfd.sh). Same
# names as the normal root, so vfd.checks run the same command lines (argv0 picks the applet).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$1"; OUT="${OUT:-$HOME/scratch/rvsh/out}"
bash "$HERE/stage-dash.sh" "$S"
cp "$OUT/dash-vfd" "$S/bin/dash"; cp "$OUT/sbase-box-vfd" "$S/bin/sbase-box"
