#!/usr/bin/ksh93
# solnix-builder -- the idle-time solnix.io queue drainer (modules/config/community/builder.nix, .kiro/steering/builder-queue.md).
# Build first, then claim only what was built. Each tick: if idle, read the public rows listing and plan every row against
# the SERVED recipes.tsv. For each BUILD row, in the listing's order, prove the job here before touching the queue:
# dry run (decline unless every input is a substitute), fetch the served out, rebuild it (`nix build --rebuild` fails
# unless the build is identical), and check the NarHash against the served narinfo's. Only then claim exactly that job
# (pnames=[pname], max 1) and complete it done. The queue spends an attempt AT CLAIM (registry.rebuild_claim), so a
# declined or failed job costs it nothing, and no job is ever completed failed because this host cannot do it.
# Without the bearer file it never claims (dry run).
#   solnix-builder plan <rows.json> <recipes.tsv>   print one decision per row (the unit test drives this)
#   solnix-builder once                             one tick;  solnix-builder (no args): the SMF loop
#   solnix-builder ready <pname> <outs>             prove one job here (dry run, fetch, rebuild, NarHash), never claim
PATH=${BUILDER_PATH:-/usr/bin:/usr/sbin}
: ${BUILDER_API:=https://telemetry.solnix.io/api/v1/build-queue} ${BUILDER_RECIPES:=https://cache.solnix.io/registry/recipes.tsv}
: ${BUILDER_CACHE:=https://cache.solnix.io}
: ${BUILDER_STATE:=/var/lib/solnix/builder} ${BUILDER_BEARER_FILE:=/var/lib/solnix/build-queue-bearer}
# The recipes' outs come from solnix main, not from the system registry's `solnix` (= the 26.11 edition: other outs).
: ${BUILDER_FLAKE:=git+https://git.solnix.io/solnix.git?ref=main}
: ${BUILDER_SYSTEM:=x86_64-solaris} ${BUILDER_AGENT:=$(uname -n)} ${BUILDER_LOAD_MAX:=2} ${BUILDER_LEASE:=600}
# between ticks: a random BUILDER_TICK_MIN..BUILDER_TICK_MAX s (10-30 min), so a fleet doesn't poll solnix.io in step
: ${BUILDER_TICK_MIN:=600} ${BUILDER_TICK_MAX:=1800}
: ${BUILDER_BUILD_SECS:=14400}
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

api() {	# api <method> <path> [json-body]: body in $BUILDER_STATE/resp, HTTP code in $code (called directly, never in
	# $(...), so $code reaches the caller). The bearer goes to curl on stdin (-H @-), never in its arguments: psargs is
	# world-readable on illumos.
	code=$(printf 'X-Solnix-Build: %s\n' "$(<"$BUILDER_BEARER_FILE")" | curl -sS -m 60 -o "$BUILDER_STATE/resp" -w '%{http_code}' \
	    -X "$1" -H @- -H 'Content-Type: application/json' ${3:+--data-binary "$3"} "$BUILDER_API$2" 2>"$BUILDER_STATE/curl.err")
}
idle() {	# 1-minute load below the threshold (per CPU count is the operator's choice of threshold)
	typeset l
	if [[ ${BUILDER_IDLE:-load} == cpu ]]; then
		# in a zone avenrun counts only the zone's own threads (kstat_fr.c), but the per-CPU tick kstats are the
		# machine's (pools off): busy CPUs over a 5 s sample stand in for the load average
		l=$(vmstat 5 2 | nawk -v n="$(psrinfo | wc -l)" 'END {print (100 - $NF) * n / 100}')
	else
		l=$(kstat -p unix:0:system_misc:avenrun_1min | nawk '{print $2/256}')
	fi
	nawk -v l="$l" -v m="$BUILDER_LOAD_MAX" 'BEGIN{exit !(l < m)}'
}

complete() {	# complete <id> <token> <result-json>
	api POST "/$1/complete" "{\"agent_id\":\"$BUILDER_AGENT\",\"claim_token\":\"$2\",$3}"
	log "complete $1 -> $code $(<"$BUILDER_STATE/resp") ($3)"
}
drv_for() {	# drv_for <pname> <outs>: "<out> <drv>^<output>" of the BUILDER_FLAKE packages attr whose outPath is one of <outs>
	typeset n=${1%-[0-9]*} a r
	[[ $n == openssl3 ]] && n=openssl
	for a in "$n" "${n//-/_}"; do
		r=$(bounded 900 nix eval --raw "$BUILDER_FLAKE#packages.$BUILDER_SYSTEM.$a" --apply 'd: d.outPath + " " + d.drvPath + "^" + (d.outputName or "out")' 2>/dev/null) &&
		    [[ ,$2, == *,"${r%% *}",* ]] && { print -r -- "$r"; return 0; }
	done
	return 1
}
ready() {	# ready <pname> <outs>: 0 when the out ($out) was rebuilt here and is the NAR cache.solnix.io serves ($nar); else log why not
	typeset d m x ins nh; nar= out=
	d=$(drv_for "$1" "$2") || { log "decline $1: no packages.$BUILDER_SYSTEM attr of $BUILDER_FLAKE evaluates to $2"; return 1; }
	out=${d%% *} d=${d#* }; set -- "$1" "$out"
	nar=$(served "$2") || { log "decline $1: $2 is not served (a first build is a submission: needs the submit key)"; return 1; }
	m=$BUILDER_STATE/tried/${d##*/}	# shortcut: a failed build is never retried for that drv; rm the file to retry
	[[ -f $m && $(<"$m") != ok ]] && { log "decline $1: $(<"$m")"; return 1; }
	# the dry run covers the leaf AND its inputs: a dry run of a substitutable leaf alone lists nothing to build
	bounded 300 nix derivation show "${d%^*}" > "$BUILDER_STATE/drv.json" 2>&1 && ins=$(jq -r '.[].inputDrvs | to_entries[] |
	    .key + "^" + ((if (.value|type) == "array" then .value else .value.outputs end) | join(","))' "$BUILDER_STATE/drv.json") &&
	    bounded 600 nix build --dry-run --no-link "$d" $ins > "$BUILDER_STATE/dry" 2>&1 || { log "decline $1: dry run of $d failed ($BUILDER_STATE/dry)"; return 1; }
	# fixed-output inputs (source tarballs, vendor dirs) may build here: their outputs are checked against the pinned
	# hash, so where they are fetched does not matter (NixOS fetches them on any builder). Any other input must substitute.
	x=0; for f in $(nawk -v d="${d%^*}" '/will be built/ {b=1; next} /will be fetched/ {b=0} b && $1 ~ /\.drv$/ && $1 != d {print $1}' "$BUILDER_STATE/dry"); do
		bounded 120 nix derivation show "$f" 2> /dev/null | jq -e '[.[].outputs[] | has("hash") or has("hashAlgo")] | all' > /dev/null || x=$((x + 1))
	done
	(( x == 0 )) || { log "decline $1: the dry run would build $x non-fixed-output derivations here first ($BUILDER_STATE/dry)"; return 1; }
	[[ -s $BUILDER_BEARER_FILE ]] || { log "dry run: would fetch $2 and rebuild $d"; return 1; }	# no fetch or CPU for what it cannot claim
	# --rebuild compares the new build with the LOCAL copy, so that copy must be the served NAR (a copied-in one may not be)
	bounded 1800 nix-store -r "$2" > /dev/null 2>&1 && nh=$(nix-store -q --hash "$2") || { log "decline $1: cannot fetch the served $2"; return 1; }
	[[ $nh == "$nar" ]] || { log "decline $1: the local $2 has $nh, cache.solnix.io serves $nar"; return 1; }
	[[ -f $m ]] && { log "$1: rebuilt and matched on an earlier tick ($m)"; return 0; }
	mkdir -p "${m%/*}"
	bounded "$BUILDER_BUILD_SECS" nice -n 19 nix build --no-link --rebuild "$d" > "$m.log" 2>&1 ||
	    { print -r -- "nix build --rebuild $d failed rc=$? ($m.log)" > "$m"; log "decline $1: $(<"$m")"; return 1; }
	print ok > "$m"; log "$1: rebuilt $2 here, identical to the served NAR $nar"
}
claim() {	# claim <pname> <out> <version> <nar_hash>: claim exactly that job, then complete it done
	[[ -s $BUILDER_BEARER_FILE ]] || { log "dry run: no $BUILDER_BEARER_FILE, not claiming $1"; return 0; }
	api POST /claim "{\"agent_id\":\"$BUILDER_AGENT\",\"systems\":[\"$BUILDER_SYSTEM\"],\"max\":1,\"lease_secs\":$BUILDER_LEASE,\"pnames\":[\"$1\"]}"
	[[ $code == 200 ]] || { log "claim $1 -> $code $(<"$BUILDER_STATE/curl.err")"; return 0; }
	cp "$BUILDER_STATE/resp" "$BUILDER_STATE/claim.json"	# the token, should anything below die (0700 dir)
	jq -e '.jobs | length > 0' "$BUILDER_STATE/claim.json" > /dev/null || { log "claim $1 -> no job (another builder has it)"; return 0; }
	jq -r '.jobs[] | [.id, .claim_token, .pname, .target_version // .current_version] | @tsv' "$BUILDER_STATE/claim.json" |
	while IFS=$'\t' read -r id tok p v; do
		log "claimed $id $p $v"
		# never expected (the server filters on pnames): report what happened instead of completing a job we did not build
		[[ $p == "$1" && $v == "$3" ]] || { complete "$id" "$tok" "\"status\":\"failed\",\"error\":\"$BUILDER_AGENT claimed pnames=[$1] $3 and was given $p $v\""; continue; }
		api POST "/$id/heartbeat" "{\"agent_id\":\"$BUILDER_AGENT\",\"claim_token\":\"$tok\"}"; log "heartbeat $id -> $code"
		complete "$id" "$tok" "\"status\":\"done\",\"version\":\"$v\",\"nar_hash\":\"$4\",\"store_path\":\"$2\""
	done
}
tick() {
	idle || { log "not idle (load >= $BUILDER_LOAD_MAX)"; return 0; }
	typeset rows=$BUILDER_STATE/rows.json rec=$BUILDER_STATE/recipes.tsv
	curl -sS -m 30 -o "$rows" "$BUILDER_API/rows" && curl -sS -m 60 -o "$rec" "$BUILDER_RECIPES" || { log "listing unavailable"; return 0; }
	plan "$rows" "$rec" > "$BUILDER_STATE/plan"; log "plan: $(cut -d' ' -f2 "$BUILDER_STATE/plan" | sort | uniq -c | tr -s ' \n' ' ')"
	[[ -s $BUILDER_BEARER_FILE ]] || log "dry run: no $BUILDER_BEARER_FILE, never claiming"
	grep ' BUILD ' "$BUILDER_STATE/plan" > "$BUILDER_STATE/builds"
	# b*: POSIX-style ksh functions share one scope, and ready/claim set p, v, d, m, ...
	while read -r bp bd bo bv; do {
		# pnames filters by pname only: with two rows of one pname the server may hand out the other one
		[[ $(jq --arg p "$bp" --arg s "$BUILDER_SYSTEM" '[.rows[] | select(.pname == $p and .system == $s)] | length' "$rows") == 1 ]] ||
		    { log "decline $bp: more than one $BUILDER_SYSTEM row for it"; continue; }
		ready "$bp" "$bo" && claim "$bp" "$out" "$bv" "$nar"; } < /dev/null
	done < "$BUILDER_STATE/builds"
}
pause() { print -r -- $(( BUILDER_TICK_MIN + (RANDOM * 32768 + RANDOM) % (BUILDER_TICK_MAX - BUILDER_TICK_MIN + 1) )); }
case $1 in
plan) plan "$2" "$3"; exit ;;
pause) pause; exit ;;
once) mkdir -p "$BUILDER_STATE" && tick; exit ;;
ready) mkdir -p "$BUILDER_STATE" && ready "$2" "$3"; exit ;;	# ready <pname> <outs>: prove one job by hand (never claims)
esac
mkdir -p "$BUILDER_STATE" || exit 1
while :; do tick; sleep "$(pause)"; done
