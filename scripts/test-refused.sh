#!/usr/bin/ksh93
# test-refused.sh -- solnix-builder's refusal memo expiry (durable1, 2026-11-11). Runs on any illumos host (ksh93, digest); no nix.
#   ksh93 scripts/test-refused.sh [builder.sh]   (last line: RESULT:)
# A refusal memo (tried/<drv>^<o>.pub) used to hold its job forever: lixu's zlib-debug was refused for a row bug, infra fixed the
# row, and the builder still held zlib's out. refused() keeps a memo only while the served rows naming the out are the ones it was
# stamped against, and for BUILDER_REFUSAL_SECS. The functions are cut out of the builder (as section 12g does nap) and driven
# against a fixture recipes.tsv; a mutant with the old test (-f <m>.pub) must fail the expiry checks; each call site must use it.
S=${1:-$(dirname "$0")/../modules/config/community/solnix-builder.sh}
W=$(mktemp -d /tmp/refused.XXXXXX); trap 'find "$W" -depth -delete' EXIT
bad=0; ok() { print "ok: $1"; }; no() { print "FAIL: $1"; bad=1; }
T=$'\t' O=/nix/store/ff3ka3rd919mb5x2ghcvp53wiq8lizc9-zlib-1.3.2-debug
mk() {	# mk <builder> <file>: the three functions + a driver: "<rc> <memo left?>" for refused <m> <out>
	{ print -r -- 'log() { print -r -- "builder: $*"; }'
	  sed -n '/^rowsha() {/p; /^refused() {/,/^}/p' "$1"
	  print -r -- 'refused "$1" "$2"; r=$?; print "$r $([[ -f $1.pub ]] && print kept || print gone)"'; } > "$2"; }
row() { print -r -- "zlib${T}1.3.2${T}u${T}s${T}autotools${T}$1${T}f${T}sparcv9-solaris${T}$O${T}"; }
recs() { { print -r -- "pname${T}version${T}url${T}sha256${T}buildsys${T}deps${T}flags${T}system${T}out${T}debug"; row "$1"
           print -r -- "libc${T}1${T}u${T}s${T}gate-slice${T}${T}f${T}sparcv9-solaris${T}/nix/store/r3hv3zc8ilhcd0dg3siiwca70hb8kp47-libc${T}"; } > "$W/st/recipes.tsv"; }
mkdir -p "$W/st/tried"; M=$W/st/tried/x-zlib-1.3.2.drv^debug
mk "$S" "$W/f.ksh"; grep -q '^refused() {' "$W/f.ksh" || { print "FAIL: no refused() in $S"; print "RESULT: FAIL"; exit 1; }
run() { env BUILDER_STATE=$W/st "$@" ksh93 "$W/f.ksh" "$M" "$O" 2> "$W/err"; }
recs zlib; print -r -- "rejected (VZgb...): authority: submitted refs omit reviewed deps" > "$M.pub"
r=$(run); [[ $r == "0 kept" && -s $M.pub.row ]] && ok "a memo with no .row: in force, stamped with the served row" || no "stamp: $r"
r=$(run); [[ $r == "0 kept" ]] && ok "the same row, a fresh memo: still in force (the job stays held)" || no "same row: $r"
recs ""; r=$(run); [[ $r == "1 gone" && -f $M.pub.expired ]] && grep -q 'expired: the served row changed' "$W/err" &&
  ok "NEG infra fixed the row (deps zlib -> empty): the memo expires, retried, logged why" || no "row change: $r $(<"$W/err")"
r=$(run); [[ $r == "1 gone" ]] && ok "no memo: not refused" || no "no memo: $r"
print -r -- "pre-submit-check.sh --leaf failed: gate" > "$M.pub"; r=$(run); r=$(run BUILDER_REFUSAL_SECS=100000)
print -r -- "$(( $(printf '%(%s)T' now) - 90000 )) $(cut -d' ' -f2 "$M.pub.row")" > "$M.pub.row"
r2=$(run BUILDER_REFUSAL_SECS=100000); r=$(run)
[[ $r2 == "0 kept" && $r == "1 gone" ]] && grep -q 'older than 86400 s' "$W/err" &&
  ok "NEG a 25 h old memo, the row unchanged: in force under a 100000 s limit, expired under the default 1 day" || no "age: $r2 / $r"
# NEG control: the old test (memo = -f <m>.pub, forever)
sed 's/^refused() {.*/refused() { [[ -f $1.pub ]]; }; refusedX() {/' "$S" > "$W/mut.sh"; mk "$W/mut.sh" "$W/f.ksh"
recs zlib; print -r -- "rejected" > "$M.pub"; rm -f "$M.pub.row"; run > /dev/null; recs ""; r=$(run)
[[ $r == "0 kept" ]] && ok "NEG a mutant with the old test (-f <m>.pub): the fixed row stays refused (so the pass above is refused()'s)" || no "mutant: $r"
# every place the builder read a .pub memo as a refusal goes through refused() (and none is left reading -f ...pub directly)
n=$(grep -c 'refused "' "$S"); x=$(sed '/^refused() {/,/^}/d' "$S" | egrep -c '(\[\[|&&) *-f [^]]*\.pub')
(( n >= 4 && x == 0 )) && ok "call sites: $n use refused(), none tests -f <memo>.pub directly (cand, firsts x2, eready)" || no "call sites: $n refused, $x direct"
(( bad )) && print "RESULT: FAIL" || print "RESULT: PASS"
