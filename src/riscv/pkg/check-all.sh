#!/usr/bin/env bash
# check-all.sh [runs] -- stage + boot every package suite RUNS times; print per-suite pass rate.
# One boot per suite per run. Needs the out/ binaries from build-all-pkgs.sh (EXTRA_PKGS="dash ncurses less")
# and the host oracles (hostsb-bin for sbase).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RUNS="${1:-3}"; W="${W:-$HOME/scratch/rvpkg}"; T="$HERE/tests"
cd "$W"; mkdir -p logs/all
for r in $(seq 1 "$RUNS"); do
	for s in libc zlib sbase dash ncurses less; do
		st="$W/stage-all-$s-$r"; mkdir -p "$st"
		bash "$HERE/stage-$s.sh" "$st" >/dev/null
		in=""; [ -f "$T/$s.stdin" ] && in="$T/$s.stdin"
		out=$(H="$W/hostsb-bin" STDIN_FILE="$in" TMO=360 bash "$HERE/run-checks.sh" "$st" "$T/$s.checks" "logs/all/$s-$r.log" 2>&1)
		nf=$(printf '%s\n' "$out" | sed -n 's/^CHECKS FAILED: //p')
		np=$(printf '%s\n' "$out" | grep -c -E '^CHECK (PASS|XFAIL-OK) ')
		if [ "$s" = ncurses ]; then	# byte-exact escape stream vs the Linux build
			bo=$(python3 "$HERE/byte-oracle.py" "logs/all/$s-$r.log" curstest "$W/out/curs-linux.out" "curstest: LINES" 2>&1)
			case "$bo" in *EQUAL*) np=$((np+1));; *) nf=$((nf+1)); out="$out
CHECK FAIL byte-oracle $bo";; esac
		fi
		echo "run $r suite $s: failed=$nf passed=$np"
		printf '%s\n' "$out" | grep -E '^CHECK FAIL' | sed 's/^/    /'
		find "$st" -delete
	done
done
