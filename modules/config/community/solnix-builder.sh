#!/usr/bin/ksh93
# solnix-builder -- the idle-time solnix.io queue drainer (modules/config/community/builder.nix, .kiro/steering/builder-queue.md).
# Each tick: if idle, read the public rows listing, plan every row against the SERVED recipes.tsv, and claim (max 1)
# only when some row is buildable here. The claimed job is built with `nix build` of the recipe row's out path (its
# deriver), checked, and completed done {version,nar_hash,store_path}; anything else is completed failed with the
# reason (the queue's own retry/backoff/park). Without the bearer file it never claims (dry run).
#   solnix-builder plan <rows.json> <recipes.tsv>   print one decision per row (the unit test drives this)
#   solnix-builder once                             one tick;  solnix-builder (no args): the SMF loop
PATH=${BUILDER_PATH:-/usr/bin:/usr/sbin}
: ${BUILDER_API:=https://telemetry.solnix.io/api/v1/build-queue} ${BUILDER_RECIPES:=https://cache.solnix.io/registry/recipes.tsv}
: ${BUILDER_STATE:=/var/lib/solnix/builder} ${BUILDER_BEARER_FILE:=/var/lib/solnix/build-queue-bearer}
: ${BUILDER_FLAKE:=solnix} ${BUILDER_SYSTEM:=x86_64-solaris} ${BUILDER_AGENT:=$(uname -n)} ${BUILDER_LOAD_MAX:=2} ${BUILDER_TICK:=900} ${BUILDER_LEASE:=7200}
log() { printf '%(%Y-%m-%dT%H:%M:%SZ)T builder: %s\n' now "$*"; }

# plan: rows (the listing's JSON) x served recipes -> "<pname> <decision> <detail>" per row. Decisions:
#   BUILD <out>      a served recipe row matches (pname or pname-version, version, system) and the job is not already met
#   MET <out>        manpage-missing, and the served out already ships share/man/man* (nothing to do; tell infra)
#   NO-MAN <out>     manpage-missing, but the recipe says has_manpages=n (a recipe change, not a rebuild)
#   NO-RECIPE        no served row at that (pname, version, system): not ours to guess
#   OTHER-SYSTEM     a system this host does not build
plan() {
	jq -r '.rows[] | [.pname, .target // .current, .system, .reasons] | @tsv' "$1" | while IFS=$'\t' read -r p v s why; do
		[[ $s == "$BUILDER_SYSTEM" ]] || { print -r -- "$p OTHER-SYSTEM $s"; continue; }
		n=${p%-"$v"}; [[ $n == openssl3 ]] && n=openssl	# the queue's pname for openssl-3 (recipes.tsv says openssl)
		row=$(nawk -F'\t' -v n="$n" -v v="$v" -v s="$s" '$1==n && $2==v && $8==s {print $7 "\t" $9; exit}' "$2")
		[[ -z $row ]] && { print -r -- "$p NO-RECIPE $n $v"; continue; }
		out=${row#*$'\t'} flags=${row%%$'\t'*}
		if [[ $why == *manpage-missing* ]]; then
			[[ $flags == *has_manpages=n* ]] && { print -r -- "$p NO-MAN $out"; continue; }
			has_man "$out" && { print -r -- "$p MET $out"; continue; }
		fi
		print -r -- "$p BUILD $out"
	done
}
has_man() { nix store ls --store https://cache.solnix.io "$1/share/man" 2>/dev/null | grep -q '^\./man'; }

api() {	# api <method> <path> [json-body]: body in $BUILDER_STATE/resp, HTTP code in $code (called directly, never in
	# $(...), so $code reaches the caller). The bearer goes to curl on stdin (-H @-), never in its arguments: psargs is
	# world-readable on illumos.
	code=$(printf 'X-Solnix-Build: %s\n' "$(<"$BUILDER_BEARER_FILE")" | curl -sS -m 60 -o "$BUILDER_STATE/resp" -w '%{http_code}' \
	    -X "$1" -H @- -H 'Content-Type: application/json' ${3:+--data-binary "$3"} "$BUILDER_API$2" 2>"$BUILDER_STATE/curl.err")
}
idle() {	# 1-minute load below the threshold (per CPU count is the operator's choice of threshold)
	typeset l=$(kstat -p unix:0:system_misc:avenrun_1min | nawk '{print $2/256}')
	nawk -v l="$l" -v m="$BUILDER_LOAD_MAX" 'BEGIN{exit !(l < m)}'
}

complete() {	# complete <id> <token> <result-json>
	api POST "/$1/complete" "{\"agent_id\":\"$BUILDER_AGENT\",\"claim_token\":\"$2\",$3}"
	log "complete $1 -> $code $(<"$BUILDER_STATE/resp") ($3)"
}
attr_for() {	# attr_for <pname> <out>: the attr of BUILDER_FLAKE (default: the registry's `solnix`) whose outPath is <out>
	typeset n=${1%-[0-9]*} a
	[[ $n == openssl3 ]] && n=openssl
	for a in "$n" "${n//-/_}"; do
		[[ $(nix eval --raw "$BUILDER_FLAKE#legacyPackages.$BUILDER_SYSTEM.$a.outPath" 2>/dev/null) == "$2" ]] && { print -r -- "$a"; return 0; }
	done
	return 1
}
build_job() {	# build_job <id> <token> <pname> <out> <version>: rebuild <out> from source, check it is byte-identical
	typeset a nh sh
	a=$(attr_for "$3" "$4") || { complete "$1" "$2" "\"status\":\"failed\",\"error\":\"no attr of $BUILDER_FLAKE evaluates to $4\""; return; }
	( BUILDER_STATE=$BUILDER_STATE/hb; mkdir -p "$BUILDER_STATE"
	  while sleep $((BUILDER_LEASE / 3)); do api POST "/$1/heartbeat" "{\"agent_id\":\"$BUILDER_AGENT\",\"claim_token\":\"$2\"}"; done ) &
	typeset hb=$!
	# --rebuild: build it here even though the path is valid (substituted), and fail unless the output is identical
	nice -n 19 nix build --no-link --rebuild "$BUILDER_FLAKE#legacyPackages.$BUILDER_SYSTEM.$a" > "$BUILDER_STATE/build-$1.log" 2>&1
	typeset rc=$?; kill $hb 2>/dev/null
	[[ $rc == 0 ]] || { complete "$1" "$2" "\"status\":\"failed\",\"error\":\"nix build --rebuild .#$a rc=$rc (log $BUILDER_STATE/build-$1.log)\""; return; }
	nh=$(nix-store -q --hash "$4")	# sha256:<nix32>, the narinfo form; the rebuild passed --rebuild, so it equals the local one
	sh=$(nix path-info --store https://cache.solnix.io --json "$4" 2>/dev/null | jq -r '.[].narHash')
	[[ $sh == sha256-* ]] && sh=sha256:$(nix hash convert --hash-algo sha256 --to nix32 "$sh")
	[[ -z $sh || $sh == "$nh" ]] || { complete "$1" "$2" "\"status\":\"failed\",\"error\":\"rebuilt $4 with $nh, cache.solnix.io serves $sh\""; return; }
	complete "$1" "$2" "\"status\":\"done\",\"version\":\"$5\",\"nar_hash\":\"$nh\",\"store_path\":\"$4\""
}
tick() {
	idle || { log "not idle (load >= $BUILDER_LOAD_MAX)"; return 0; }
	typeset rows=$BUILDER_STATE/rows.json rec=$BUILDER_STATE/recipes.tsv
	curl -sS -m 30 -o "$rows" "$BUILDER_API/rows" && curl -sS -m 60 -o "$rec" "$BUILDER_RECIPES" || { log "listing unavailable"; return 0; }
	plan "$rows" "$rec" > "$BUILDER_STATE/plan"; log "plan: $(cut -d' ' -f2 "$BUILDER_STATE/plan" | sort | uniq -c | tr -s ' \n' ' ')"
	# claim is not selective (the server hands out its next job), so claim only when a job here is worth taking:
	# a BUILD, or with BUILDER_REPORT=1 a MET (completed failed "retire", which parks it with that reason)
	egrep -q " BUILD ${BUILDER_REPORT:+| MET }" "$BUILDER_STATE/plan" || return 0
	[[ -s $BUILDER_BEARER_FILE ]] || { log "dry run: no $BUILDER_BEARER_FILE, not claiming"; return 0; }
	api POST /claim "{\"agent_id\":\"$BUILDER_AGENT\",\"systems\":[\"$BUILDER_SYSTEM\"],\"max\":1,\"lease_secs\":$BUILDER_LEASE}"
	[[ $code == 200 ]] || { log "claim -> $code $(<"$BUILDER_STATE/curl.err")"; return 0; }
	cp "$BUILDER_STATE/resp" "$BUILDER_STATE/claim.json"	# the token, should anything below die (0700 dir)
	jq -r '.jobs[] | [.id, .claim_token, .pname, .target_version // .current_version] | @tsv' "$BUILDER_STATE/claim.json" |
	while IFS=$'\t' read -r id tok p v; do
		d=$(nawk -v p="$p" '$1==p {print $2, $3; exit}' "$BUILDER_STATE/plan")
		log "claimed $id $p $v: ${d:-not in plan}"
		api POST "/$id/heartbeat" "{\"agent_id\":\"$BUILDER_AGENT\",\"claim_token\":\"$tok\"}"; log "heartbeat $id -> $code"
		case $d in
		BUILD\ *) build_job "$id" "$tok" "$p" "${d#BUILD }" "$v" ;;
		MET\ *) complete "$id" "$tok" "\"status\":\"failed\",\"error\":\"not rebuilt: the served out ${d#MET } already has share/man; retire this manpage-missing job\"" ;;
		*) complete "$id" "$tok" "\"status\":\"failed\",\"error\":\"$BUILDER_AGENT cannot serve this job: ${d:-not in the rows listing}\"" ;;
		esac
	done
}
case $1 in
plan) plan "$2" "$3"; exit ;;
once) mkdir -p "$BUILDER_STATE" && tick; exit ;;
esac
mkdir -p "$BUILDER_STATE" || exit 1
while :; do tick; sleep "$BUILDER_TICK"; done
