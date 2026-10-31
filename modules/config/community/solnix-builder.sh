#!/usr/bin/ksh93
# solnix-builder -- the idle-time solnix.io queue drainer (modules/config/community/builder.nix, .kiro/steering/builder-queue.md).
# Build first, then claim only what was built. Each tick: if idle, read the public rows listing and plan every row against
# the SERVED recipes.tsv. For each BUILD row, in the listing's order, prove the job here before touching the queue:
# dry run (decline unless every input is a substitute), fetch the served out, rebuild it (`nix build --rebuild` fails
# unless the build is identical), and check the NarHash against the served narinfo's. Only then claim exactly that job
# (pnames=[pname], max 1) and complete it done. The queue spends an attempt AT CLAIM (registry.rebuild_claim), so a
# declined or failed job costs it nothing, and no job is ever completed failed because this host cannot do it.
# Without the bearer file it never claims (dry run).
# Parallel (qbuild4): each tick sizes itself from the CPUs NOT busy with other work (none of ours runs between ticks):
# K jobs of C cores (size), each BUILD row one job in its own state dir, up to K at once (ksh93 JOBMAX). A tick that
# rebuilt or claimed something re-ticks soon (BUILDER_BUSY_TICK_*), one that found nothing to do backs off (BUILDER_TICK_*).
#   solnix-builder plan <rows.json> <recipes.tsv>   print one decision per row (the unit test drives this)
#   solnix-builder rows <out.json> <recipes.tsv>    this system's listing window + every row of a served recipe's pname
#   solnix-builder size                             print "<jobs> <cores> <busy>" for this tick
#   solnix-builder once                             one tick (rc 0: it rebuilt or claimed);  no args: the SMF loop
#   solnix-builder ready <pname> <outs>             prove one job here (dry run, fetch, rebuild, NarHash), never claim
PATH=${BUILDER_PATH:-/usr/bin:/usr/sbin}
: ${BUILDER_API:=https://telemetry.solnix.io/api/v1/build-queue} ${BUILDER_RECIPES:=https://cache.solnix.io/registry/recipes.tsv}
: ${BUILDER_CACHE:=https://cache.solnix.io}
: ${BUILDER_STATE:=/var/lib/solnix/builder} ${BUILDER_BEARER_FILE:=/var/lib/solnix/build-queue-bearer}
# The recipes' outs come from solnix main, not from the system registry's `solnix` (= the 26.11 edition: other outs).
: ${BUILDER_FLAKE:=git+https://git.solnix.io/solnix.git?ref=main}
: ${BUILDER_SYSTEM:=x86_64-solaris} ${BUILDER_AGENT:=$(uname -n)} ${BUILDER_LOAD_MAX:=2} ${BUILDER_LEASE:=600}
# between ticks: a random BUILDER_TICK_MIN..BUILDER_TICK_MAX s (10-30 min), so a fleet doesn't poll solnix.io in step;
# after a tick that rebuilt or claimed, BUILDER_BUSY_TICK_MIN..MAX (the same unless the operator shortens it)
: ${BUILDER_TICK_MIN:=600} ${BUILDER_TICK_MAX:=1800} ${BUILDER_BUSY_TICK_MIN:=$BUILDER_TICK_MIN} ${BUILDER_BUSY_TICK_MAX:=$BUILDER_TICK_MAX}
# BUILDER_JOBS: at most this many jobs at once (auto: as many as fit); BUILDER_CORES: nix `cores` per job (0: CPUs / jobs).
# BUILDER_LOAD_MAX: no job unless fewer CPUs than this are busy (auto: unless C are idle). BUILDER_BUSY: a test hook.
: ${BUILDER_JOBS:=1} ${BUILDER_CORES:=0} ${BUILDER_NICE:=19} ${BUILDER_NCPU:=$(/usr/sbin/psrinfo | wc -l | tr -d ' ')}
: ${BUILDER_BUILD_SECS:=14400}
J=$BUILDER_STATE C=0 flake=$BUILDER_FLAKE	# a job's state dir, its cores, the flake (locked once per tick)
log() { printf '%(%Y-%m-%dT%H:%M:%SZ)T builder: %s\n' now "$*"; }
bounded() {	# bounded <secs> <cmd...>: run it, TERM it after <secs> (illumos has no timeout(1)). A `nix store ls` against
	# cache.solnix.io hung > 8 min on dixi (2026-10-29, past stalled-download-timeout), which would wedge the loop for good.
	typeset s=$1 p w rc; shift
	"$@" & p=$!
	{ sleep "$s"; kill "$p"; } > /dev/null 2>&1 & w=$!
	wait "$p"; rc=$?; kill "$w" 2> /dev/null; return $rc
}

# plan: rows (the listing's JSON) x served recipes -> "<pname> <decision> <detail>" per row. Decisions:
# <outs> is every served row's out at that (pname, version, system), comma-separated: recipes.tsv has one row per output
# path, and rows from older solnix commits stay (jq 1.7.1 has two), so the gate builds the one BUILDER_FLAKE evaluates to.
#   BUILD <outs> <version>  a served recipe row matches (pname or pname-version, version, system) and the job is not met
#                    (manpage-missing: only the outs cache.solnix.io does not serve yet)
#   MET <outs>       manpage-missing, and a served out already ships share/man/man* (nothing to do; tell infra)
#   MAN-GAP <outs>   manpage-missing, has_manpages=y, every out IS served and none has share/man: rebuilding the same
#                    out cannot add pages, so `done` would be false (a recipe fix)
#   NO-MAN <outs>    manpage-missing, but the recipe says has_manpages=n (a recipe change, not a rebuild)
#   NO-RECIPE        no served row at that (pname, version, system): not ours to guess
#   OTHER-SYSTEM     a system this host does not build
plan() {	# in claim order (priority ascending, then oldest): /build-queue/rows lists priority DESC, so deferred rows would come first
	jq -r '.rows | sort_by(.priority // 0, -(.age_secs // 0)) | .[] | [.pname, .target // .current, .system, .reasons] | @tsv' "$1" | while IFS=$'\t' read -r p v s why; do
		[[ $s == "$BUILDER_SYSTEM" ]] || { print -r -- "$p OTHER-SYSTEM $s"; continue; }
		n=${p%-"$v"}; [[ $n == openssl3 ]] && n=openssl	# the queue's pname for openssl-3 (recipes.tsv says openssl)
		row=$(nawk -F'\t' -v n="$n" -v v="$v" -v s="$s" '$1==n && $2==v && $8==s {if (!f) f=$7; o=o (o ? "," : "") $9} END {if (o) print f "\t" o}' "$2")
		[[ -z $row ]] && { print -r -- "$p NO-RECIPE $n $v"; continue; }
		outs=${row#*$'\t'} flags=${row%%$'\t'*} d=BUILD
		if [[ $why == *manpage-missing* ]]; then
			[[ $flags == *has_manpages=n* ]] && { print -r -- "$p NO-MAN $outs"; continue; }
			b=; for o in ${outs//,/ }; do has_man "$o" && { d=MET; break; }; served "$o" > /dev/null || b=$b${b:+,}$o; done
			[[ $d == MET ]] && { print -r -- "$p MET $outs"; continue; }
			[[ -z $b ]] && { print -r -- "$p MAN-GAP $outs"; continue; }
			outs=$b	# only an unserved out can add pages: a served one rebuilt is the same bytes
		fi
		print -r -- "$p BUILD $outs $v"
	done
}
has_man() { bounded 120 nix store ls --store "$BUILDER_CACHE" "$1/share/man" 2>/dev/null | grep -q '^\./man'; }
served() {	# served <out>: print the NarHash cache.solnix.io serves for <out> (sha256:<nix32>, the nix-store -q --hash form)
	typeset h=${1#/nix/store/}
	curl -sf -m 30 "$BUILDER_CACHE/${h%%-*}.narinfo" | nawk '/^NarHash: sha256:/ {print $2; f=1} END {exit !f}'
}

api() {	# api <method> <path> [json-body]: body in $J/resp (the job's own), HTTP code in $code (called directly, never in
	# $(...), so $code reaches the caller). The bearer goes to curl on stdin (-H @-), never in its arguments: psargs is
	# world-readable on illumos.
	code=$(printf 'X-Solnix-Build: %s\n' "$(<"$BUILDER_BEARER_FILE")" | curl -sS -m 60 -o "$J/resp" -w '%{http_code}' \
	    -X "$1" -H @- -H 'Content-Type: application/json' ${3:+--data-binary "$3"} "$BUILDER_API$2" 2>"$J/curl.err")
}
size() {	# "<jobs> <cores> <busy>" for this tick. busy: CPUs busy over a 5 s sample. None of ours runs between ticks, so that
	# is OTHER work; the 1-min load average would still count the last tick's builds. In a zone the per-CPU tick kstats
	# are still the machine's (pools off), while avenrun counts only the zone's threads (kstat_fr.c).
	typeset b=${BUILDER_BUSY:-$(vmstat 5 2 | nawk -v n="$BUILDER_NCPU" 'END {printf "%.2f", (100 - $NF) * n / 100}')} c=$BUILDER_CORES k
	(( c > 0 )) || { [[ $BUILDER_JOBS == auto ]] && c=4 || c=$(( BUILDER_NCPU / BUILDER_JOBS )); }; (( c > 0 )) || c=1
	k=$(nawk -v n="$BUILDER_NCPU" -v b="$b" -v c="$c" -v j="$BUILDER_JOBS" -v m="$BUILDER_LOAD_MAX" 'BEGIN {
		k = int((n - b) / c); if (j != "auto" && k > j + 0) k = j + 0
		if (m != "auto") k = (b >= m + 0) ? 0 : (k < 1 ? 1 : k)	# a numeric loadMax: the old gate, at least one job
		print (k < 0 ? 0 : k) }')
	print -r -- "$k $c $b"
}

complete() {	# complete <id> <token> <result-json>
	api POST "/$1/complete" "{\"agent_id\":\"$BUILDER_AGENT\",\"claim_token\":\"$2\",$3}"
	log "complete $1 -> $code $(<"$J/resp") ($3)"
}
drv_for() {	# drv_for <pname> <outs>: "<out> <drv>^<output>" of the BUILDER_FLAKE packages attr whose outPath is one of <outs>
	typeset n=${1%-[0-9]*} a r
	[[ $n == openssl3 ]] && n=openssl
	for a in "$n" "${n//-/_}"; do
		r=$(bounded 900 nix eval --raw "$flake#packages.$BUILDER_SYSTEM.$a" --apply 'd: d.outPath + " " + d.drvPath + "^" + (d.outputName or "out")' 2>/dev/null) &&
		    [[ ,$2, == *,"${r%% *}",* ]] && { print -r -- "$r"; return 0; }
	done
	return 1
}
ready() {	# ready <pname> <outs>: 0 when the out ($out) was rebuilt here and is the NAR cache.solnix.io serves ($nar); else log why not
	typeset d m x ins nh; nar= out=
	d=$(drv_for "$1" "$2") || { log "decline $1: no packages.$BUILDER_SYSTEM attr of $flake evaluates to $2"; return 1; }
	out=${d%% *} d=${d#* }; set -- "$1" "$out"
	nar=$(served "$2") || { log "decline $1: $2 is not served (a first build is a submission: needs the submit key)"; return 1; }
	m=$BUILDER_STATE/tried/${d##*/}	# shortcut: a failed build is never retried for that drv; rm the file to retry
	[[ -f $m && $(<"$m") != ok ]] && { log "decline $1: $(<"$m")"; return 1; }
	# the dry run covers the leaf AND its inputs: a dry run of a substitutable leaf alone lists nothing to build
	bounded 300 nix derivation show "${d%^*}" > "$J/drv.json" 2>&1 && ins=$(jq -r '.[].inputDrvs | to_entries[] |
	    .key + "^" + ((if (.value|type) == "array" then .value else .value.outputs end) | join(","))' "$J/drv.json") &&
	    bounded 600 nix build --dry-run --no-link "$d" $ins > "$J/dry" 2>&1 || { log "decline $1: dry run of $d failed ($J/dry)"; return 1; }
	# fixed-output inputs (source tarballs, vendor dirs) may build here: their outputs are checked against the pinned
	# hash, so where they are fetched does not matter (NixOS fetches them on any builder). Any other input must substitute.
	x=0; for f in $(nawk -v d="${d%^*}" '/will be built/ {b=1; next} /will be fetched/ {b=0} b && $1 ~ /\.drv$/ && $1 != d {print $1}' "$J/dry"); do
		bounded 120 nix derivation show "$f" 2> /dev/null | jq -e '[.[].outputs[] | has("hash") or has("hashAlgo")] | all' > /dev/null || x=$((x + 1))
	done
	(( x == 0 )) || { log "decline $1: the dry run would build $x non-fixed-output derivations here first ($J/dry)"; return 1; }
	[[ -s $BUILDER_BEARER_FILE ]] || { log "dry run: would fetch $2 and rebuild $d"; return 1; }	# no fetch or CPU for what it cannot claim
	# --rebuild compares the new build with the LOCAL copy, so that copy must be the served NAR (a copied-in one may not be)
	bounded 1800 nix-store -r "$2" > /dev/null 2>&1 && nh=$(nix-store -q --hash "$2") || { log "decline $1: cannot fetch the served $2"; return 1; }
	[[ $nh == "$nar" ]] || { log "decline $1: the local $2 has $nh, cache.solnix.io serves $nar"; return 1; }
	[[ -f $m ]] && { log "$1: rebuilt and matched on an earlier tick ($m)"; return 0; }
	mkdir -p "${m%/*}"; log "$1: rebuilding $d ($C cores)"
	bounded "$BUILDER_BUILD_SECS" nice -n "$BUILDER_NICE" nix build --option cores "$C" --no-link --rebuild "$d" > "$m.log" 2>&1 ||
	    { print -r -- "nix build --rebuild $d failed rc=$? ($m.log)" > "$m"; log "decline $1: $(<"$m")"; return 1; }
	print ok > "$m"; : > "$J/worked"; log "$1: rebuilt $2 here, identical to the served NAR $nar"
}
claim() {	# claim <pname> <out> <version> <nar_hash>: claim exactly that job, then complete it done
	[[ -s $BUILDER_BEARER_FILE ]] || { log "dry run: no $BUILDER_BEARER_FILE, not claiming $1"; return 0; }
	api POST /claim "{\"agent_id\":\"$BUILDER_AGENT\",\"systems\":[\"$BUILDER_SYSTEM\"],\"max\":1,\"lease_secs\":$BUILDER_LEASE,\"pnames\":[\"$1\"]}"
	[[ $code == 200 ]] || { log "claim $1 -> $code $(<"$J/curl.err")"; return 0; }
	cp "$J/resp" "$J/claim.json"	# the token, should anything below die (0700 dir)
	jq -e '.jobs | length > 0' "$J/claim.json" > /dev/null || { log "claim $1 -> no job (another builder has it)"; return 0; }
	jq -r '.jobs[] | [.id, .claim_token, .pname, .target_version // .current_version] | @tsv' "$J/claim.json" |
	while IFS=$'\t' read -r id tok p v; do
		log "claimed $id $p $v"
		# never expected (the server filters on pnames): report what happened instead of completing a job we did not build
		[[ $p == "$1" && $v == "$3" ]] || { complete "$id" "$tok" "\"status\":\"failed\",\"error\":\"$BUILDER_AGENT claimed pnames=[$1] $3 and was given $p $v\""; continue; }
		api POST "/$id/heartbeat" "{\"agent_id\":\"$BUILDER_AGENT\",\"claim_token\":\"$tok\"}"; log "heartbeat $id -> $code"
		complete "$id" "$tok" "\"status\":\"done\",\"version\":\"$v\",\"nar_hash\":\"$4\",\"store_path\":\"$2\""; [[ $code == 200 ]] && : > "$J/worked"
	done
}
rows() {	# rows <out.json> <recipes.tsv>: this system's listing window (500 rows, mostly nixpkgs attrs with no recipe), plus
	# every row of each pname the served recipes have for this system (?pname=, 100 a call), so no job it could do is
	# past the window. A queried pname's rows come only from its own query: each row once, a real duplicate kept.
	typeset o=$1 f q i=0
	curl -sSf -m 30 -o "$o.w" "$BUILDER_API/rows?system=$BUILDER_SYSTEM" || return 1; f="$o.w"
	nawk -F'\t' -v s="$BUILDER_SYSTEM" 'NR > 1 && $8 == s && $1 ~ /^[A-Za-z0-9._+-]+$/ {print $1; if ($1 == "openssl") print "openssl3"}' "$2" | sort -u > "$o.q"
	while q=$(nawk -v i="$i" 'NR > i && NR <= i + 100' "$o.q" | sed 's/+/%2B/g' | paste -sd, -); [[ -n $q ]]; do
		curl -sSf -m 30 -o "$o.p$i" "$BUILDER_API/rows?system=$BUILDER_SYSTEM&pname=$q" || return 1; f="$f $o.p$i"; i=$((i + 100))
	done
	jq -s --rawfile q "$o.q" '($q | split("\n") | map(select(. != "") | {(.): true}) | add // {}) as $Q |
	    {rows: ((.[0].rows | map(select($Q[.pname] | not))) + ([.[1:][].rows] | add // []))}' $f > "$o"
}
job() {	# job <pname> <outs> <version>: one BUILD row, start to finish, in its own state dir. Runs in the background.
	JOBMAX=0	# inherited from the tick: at 1, bounded()'s own watchdog `&` would wait behind the command it guards
	J=$BUILDER_STATE/job/${1//[!A-Za-z0-9._+-]/_}; mkdir -p "$J" || return 1
	ready "$1" "$2" && claim "$1" "$out" "$3" "$nar"
}
tick() {	# rc 0 when a job rebuilt or completed something: the loop then re-ticks soon
	typeset rows=$BUILDER_STATE/rows.json rec=$BUILDER_STATE/recipes.tsv z k c b
	z=$(size); k=${z%% *} z=${z#* } c=${z%% *} b=${z#* }
	(( k > 0 )) || { log "not idle ($b of $BUILDER_NCPU CPUs busy; loadMax $BUILDER_LOAD_MAX, $c cores a job)"; return 1; }
	curl -sS -m 60 -o "$rec" "$BUILDER_RECIPES" && rows "$rows" "$rec" || { log "listing unavailable"; return 1; }
	plan "$rows" "$rec" > "$BUILDER_STATE/plan"; log "plan: $(cut -d' ' -f2 "$BUILDER_STATE/plan" | sort | uniq -c | tr -s ' \n' ' ')"
	[[ -s $BUILDER_BEARER_FILE ]] || log "dry run: no $BUILDER_BEARER_FILE, never claiming"
	grep ' BUILD ' "$BUILDER_STATE/plan" > "$BUILDER_STATE/builds" || return 1
	# every job evaluates the same commit, fetched once
	flake=$(bounded 300 nix flake metadata --json "$BUILDER_FLAKE" 2> /dev/null | jq -r '.url // empty'); : ${flake:=$BUILDER_FLAKE}
	log "up to $k jobs of $c cores ($b of $BUILDER_NCPU CPUs busy), $flake"
	C=$c; rm -f "$BUILDER_STATE"/job/*/worked; JOBMAX=$k
	while read -r bp bd bo bv; do
		# pnames filters by pname only: with two rows of one pname the server may hand out the other one
		[[ $(jq --arg p "$bp" --arg s "$BUILDER_SYSTEM" '[.rows[] | select(.pname == $p and .system == $s)] | length' "$rows") == 1 ]] ||
		    { log "decline $bp: more than one $BUILDER_SYSTEM row for it"; continue; }
		job "$bp" "$bo" "$bv" < /dev/null &
	done < "$BUILDER_STATE/builds"
	wait; JOBMAX=0
	ls "$BUILDER_STATE"/job/*/worked > /dev/null 2>&1
}
pause() {	# pause [busy]: seconds to the next tick
	typeset lo=$BUILDER_TICK_MIN hi=$BUILDER_TICK_MAX
	[[ $1 == busy ]] && lo=$BUILDER_BUSY_TICK_MIN hi=$BUILDER_BUSY_TICK_MAX
	print -r -- $(( lo + (RANDOM * 32768 + RANDOM) % (hi - lo + 1) ))
}
case $1 in
plan) plan "$2" "$3"; exit ;;
rows) rows "$2" "$3"; exit ;;
size) size; exit ;;
pause) pause "$2"; exit ;;
once) mkdir -p "$BUILDER_STATE" && tick; exit ;;
ready) mkdir -p "$BUILDER_STATE" && ready "$2" "$3"; exit ;;	# ready <pname> <outs>: prove one job by hand (never claims)
esac
mkdir -p "$BUILDER_STATE" || exit 1
while :; do if tick; then sleep "$(pause busy)"; else sleep "$(pause)"; fi; done
