#!/usr/bin/env bash
# check-kernel.sh [runs] -- the raw-syscall kernel-defect probes, one boot per case.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; W="${W:-$HOME/scratch/rvpkg}"; cd "$W"
st="$W/stage-kpipe-probe"; mkdir -p "$st" logs/kernel; bash "$HERE/stage-kpipe.sh" "$st"
for r in $(seq 1 "${1:-1}"); do
	for m in ctl conout execfd leak; do
		echo "run $r $m: $(TMO=${TMO:-90} bash "$HERE/run-checks.sh" "$st" "$HERE/tests/kpipe-$m.checks" "logs/kernel/$m-$r.log" 2>&1 | grep '^CHECK ')"
	done
done
