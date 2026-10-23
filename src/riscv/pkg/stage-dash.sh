#!/usr/bin/env bash
# stage-dash.sh <stage-dir> -- dash + sbase-box (for ed and externals) + inputs.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$1"; OUT="${OUT:-$HOME/scratch/rvpkg/out}"
bash "$HERE/stage-sbase.sh" "$S"
cp "$OUT/dash" "$S/bin/dash"; cp "$OUT/dash-novfd" "$S/bin/dash-novfd"
cp "$HERE/tests/dash-test.sh" "$S/etc/dash-test.sh"
