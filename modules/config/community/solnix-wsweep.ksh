#!/usr/bin/ksh93
# solnix-wsweep <older-than-secs> [<buildKey>] -- remove the fixed build dirs (W=/var/tmp/{srcpkg,cargo,go,rust,gccsrc}-<buildKey>) that a killed build left
# behind. A W is the same path on every host (it is in the NAR), so the next build of that drv must be able to create it; one left by
# another build user blocks it ("rm: cannot remove ... Permission denied", wave4 chef uv). A W is removed only when it is older than the
# limit AND its owner (a nixbld user) runs NO process at all: a build user runs one build at a time, and a live build's cwd need not be
# under W (mk-src-pkg writes W before it cds there; meson/cmake build elsewhere), so a cwd test deleted a live --check's W on woof
# (2026-11-08: a service restart's `wsweep 0` while an operator build ran through the same daemon). An owner that is busy keeps its W
# until a later tick. Runs as root from solnix-builder at start and before each tick. Prints each removal. Exit 0.
# With <buildKey> (solnix-builder, right before pre-submit-check's --check of that drv, fleet8): only that drv's W, whatever its age, by
# the same rule. Prints why it keeps one.
set -u
age=${1:-21600} k='*' one=; R=${SOLNIX_WSWEEP_ROOT:-/var/tmp}	# the root is a test hook (scripts/test-wsweep.sh)
(( $# < 2 )) || { k=$2 one=1; [[ $k == +([0-9a-f]) ]] || exit 0; }	# a key is hex, never a pattern
for w in $R/srcpkg-$k $R/cargo-$k $R/go-$k $R/rust-$k $R/gccsrc-$k; do
	[[ -d $w && ! -L $w ]] || continue
	[[ ${w##*/} == +([a-z])-+([0-9a-f]) ]] || continue		# exactly <kind>-<hex buildKey>
	u=$(/usr/bin/ls -ldn "$w" | /usr/bin/nawk '{print $3}')
	(( u >= 30000 && u < 31000 )) || continue			# a build user's (nixbldN) dir only
	[[ -n $one || -n $(/usr/bin/find "$w" -prune -mmin +$(( age / 60 )) 2> /dev/null) ]] || continue	# older than the limit (no stat(1) on illumos)
	[[ -n $(/usr/bin/pgrep -U "$u" 2> /dev/null) ]] && { [[ -n $one ]] && print -r -- "solnix-wsweep: keeping $w (uid $u runs a process: maybe a live build)"; continue; }
	print -r -- "solnix-wsweep: removing stale $w (uid $u, $([[ -z $one ]] && print "older than $(( age / 60 )) min, ")no process of uid $u runs)"
	/usr/bin/rm -r -f -- "$w"
done
exit 0
