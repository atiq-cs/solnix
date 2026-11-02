#!/usr/bin/ksh93
# solnix-wsweep <older-than-secs> -- remove the fixed build dirs (W=/var/tmp/{srcpkg,cargo,go,rust,gccsrc}-<buildKey>) that a killed build left
# behind. A W is the same path on every host (it is in the NAR), so the next build of that drv must be able to create it; one left by
# another build user blocks it ("rm: cannot remove ... Permission denied", wave4 chef uv). A W is removed only when it is older than the
# limit AND no process of its owner has its cwd or an open file under it (pfiles is too slow; ptree of the owner's processes and their cwd
# via /proc/<pid>/path/cwd). Runs as root from solnix-builder before each tick. Prints each removal. Exit 0.
set -u
age=${1:-21600}; R=${SOLNIX_WSWEEP_ROOT:-/var/tmp}	# the root is a test hook (selftest below)
for w in $R/srcpkg-* $R/cargo-* $R/go-* $R/rust-* $R/gccsrc-*; do
	[[ -d $w && ! -L $w ]] || continue
	[[ ${w##*/} == +([a-z])-+([0-9a-f]) ]] || continue		# exactly <kind>-<hex buildKey>
	u=$(/usr/bin/ls -ldn "$w" | /usr/bin/nawk '{print $3}')
	(( u >= 30000 && u < 31000 )) || continue			# a build user's (nixbldN) dir only
	[[ -n $(/usr/bin/find "$w" -prune -mmin +$(( age / 60 )) 2> /dev/null) ]] || continue	# older than the limit (no stat(1) on illumos)
	busy=0
	for p in $(/usr/bin/pgrep -U "$u" 2> /dev/null); do
		c=$(/usr/bin/ls -l /proc/$p/path/cwd 2> /dev/null | /usr/bin/nawk '{print $NF}')
		[[ $c == "$w" || $c == "$w"/* ]] && { busy=1; break; }
	done
	(( busy )) && continue
	print -r -- "solnix-wsweep: removing stale $w (uid $u, older than $(( age / 60 )) min, no process of it there)"
	/usr/bin/rm -r -f -- "$w"
done
exit 0
