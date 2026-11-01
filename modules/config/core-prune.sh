#!/usr/bin/ksh93
# core-prune -- bound /var/cores the way NixOS bounds systemd-coredump (modules/config/coreadm.nix maxAge/maxUse/keepPerProgram).
# One SMF contract loop (SMF has no periodic model; census.nix does the same). Every pass, over the regular files named
# core.<prog>.<pid>.<time> (the coreadm patterns' %f.%p.%t) in CORE_DIR and its per-uid subdirectories, newest first by %t:
# drop those older than CORE_MAX_AGE_DAYS, keep the newest CORE_KEEP_PER_PROGRAM per program (a desktop logout writes a dozen
# of one program), then drop the oldest past CORE_MAX_USE_MB in total. Never follows a link, never leaves CORE_DIR.
#   core-prune --once   one pass, then exit (the unit test uses this)
PATH=/usr/bin:/usr/sbin
: ${CORE_DIR:=/var/cores} ${CORE_MAX_AGE_DAYS:=14} ${CORE_KEEP_PER_PROGRAM:=3} ${CORE_MAX_USE_MB:=4096} ${CORE_INTERVAL:=3600}

list() {	# "<time> <bytes> <path>" per core file, newest first; a name without a numeric %t sorts as oldest (0)
	typeset d f t
	for d in "$CORE_DIR" "$CORE_DIR"/*/; do
		[[ -d $d && ! -L ${d%/} ]] || continue
		for f in "${d%/}"/core.*; do
			[[ -f $f && ! -L $f ]] || continue
			t=${f##*.}; [[ $t == +([0-9]) ]] || t=0
			print -r -- "$t $(ls -n "$f" | awk '{print $5}') $f"
		done
	done | sort -k1,1nr
}

pass() {
	# -li: ksh93 -i is 32-bit, and 4096 MiB in bytes overflowed it to 0 (every core removed; caught by a dry run on lixi)
	typeset -A seen; typeset -li total=0 cap=CORE_MAX_USE_MB*1048576 old n t b
	typeset p prog
	old=$(( $(date +%s) - CORE_MAX_AGE_DAYS * 86400 ))
	list | while read -r t b p; do
		prog=${p##*/core.}; prog=${prog%.*.*}
		n=${seen[$prog]:-0}; seen[$prog]=$((n + 1))
		if (( t < old || n >= CORE_KEEP_PER_PROGRAM || total + b > cap )); then
			rm -f -- "$p" && print -r -- "core-prune: removed $p"
		else
			total=total+b
		fi
	done
}

if [[ $1 == --once ]]; then pass; exit 0; fi
while :; do pass; sleep "$CORE_INTERVAL"; done
