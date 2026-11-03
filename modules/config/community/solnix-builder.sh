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
# First publish (fleet3, maintainer 2026-11-03): a served row whose out cache.solnix.io does not serve yet (narinfo 404) is
# built here and submitted with this host's own builder id and key, when BUILDER_PUBLISH=1 and BUILDER_PUBLISH_KEY is
# readable (and the bearer is there; BUILDER_PUBLISH=dry: every step up to the signed /begin, which is never sent):
# nix build of every output (the first build); every reference served, else it waits (deps first, never memo'd);
# nix-store --verify-path; pre-submit-check.sh --leaf (--check: the second build, SAME; drv-gate --leaf; publish-gate;
# store; closure; build log; the stamp); a one-path file:// stage; cache-submit.py --submit (one leaf, at most
# BUILDER_PUBLISH_SLOTS in flight). Promoted: the served NarHash is this host's, an 8UNr-only client fetches and verifies
# the NAR (a key that signs nothing must not), then the job is claimed and completed done like a rebuilt one. Tier 1
# (after 2026-11-13): proposed/approved wait in $BUILDER_STATE/pub/<out> and are polled on later ticks, a 429 backs off
# Retry-After seconds; neither is a failure. A failed gate, a differing --check or a rejection is memo'd (tried/<drv>.pub).
PATH=${BUILDER_PATH:-/usr/bin:/usr/sbin}
: ${BUILDER_API:=https://builders.solnix.io/api/v1/build-queue} ${BUILDER_RECIPES:=https://cache.solnix.io/registry/recipes.tsv}
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
# BUILDER_SHARE: the fraction (percent) of the CPUs other work leaves idle that this host may use (100 dedicated, 66 opportunistic).
: ${BUILDER_SHARE:=100}
: ${BUILDER_BUILD_SECS:=14400}
# first publish: off unless set (the module turns it on for dedicated hosts); the key is the host's enrolled ssh-ed25519 key
: ${BUILDER_PUBLISH:=0} ${BUILDER_PUBLISH_KEY:=/etc/ssh/ssh_host_ed25519_key} ${BUILDER_PUBLISH_ID:=$BUILDER_AGENT}
# BUILDER_GATES: the dir with scripts/cache-submit.py, pre-submit-check.sh and the gates; BUILDER_SUBMIT: a test hook (the submitter)
: ${BUILDER_GATES:=} ${BUILDER_PYTHON:=${GATE_PYTHON:-python3}} ${BUILDER_PUBLISH_POLL:=1800} ${BUILDER_PUBLISH_SLOTS:=4}
: ${BUILDER_CACHE_KEY:=cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8=}
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
#   BUILD <outs> <version> <commit>  a served recipe row matches (pname or pname-version, version, system) and the job is not
#                    met; <commit>: the row's `commit` (the solnix commit infra recorded for its batch), - when the listing has none
#                    (manpage-missing: only the outs cache.solnix.io does not serve yet)
#   MET <outs>       manpage-missing, and a served out already ships share/man/man* (nothing to do; tell infra)
#   MAN-GAP <outs>   manpage-missing, has_manpages=y, every out IS served and none has share/man: rebuilding the same
#                    out cannot add pages, so `done` would be false (a recipe fix)
#   NO-MAN <outs>    manpage-missing, but the recipe says has_manpages=n (a recipe change, not a rebuild)
#   NO-RECIPE        no served row at that (pname, version, system): not ours to guess
#   OTHER-SYSTEM     a system this host does not build
plan() {	# in claim order (priority ascending, then oldest): /build-queue/rows lists priority DESC, so deferred rows would come first
	# commit first: IFS=tab collapses empty fields, and it is never empty ("-" when the listing has none)
	jq -r '.rows | sort_by(.priority // 0, -(.age_secs // 0)) | .[] | [.commit // "-", .pname, .target // .current, .system, .reasons] | @tsv' "$1" |
	while IFS=$'\t' read -r rc p v s why; do
		[[ $rc == +([0-9a-f]) && ${#rc} == 40 ]] || rc=-	# a full git sha or nothing: it goes into a flake URL
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
		print -r -- "$p BUILD $outs $v $rc"
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
	k=$(nawk -v n="$BUILDER_NCPU" -v b="$b" -v c="$c" -v j="$BUILDER_JOBS" -v m="$BUILDER_LOAD_MAX" -v sh="$BUILDER_SHARE" 'BEGIN {
		k = int((n - b) * sh / 100 / c); if (j != "auto" && k > j + 0) k = j + 0
		if (m != "auto") k = (b >= m + 0) ? 0 : (k < 1 ? 1 : k)	# a numeric loadMax: the old gate, at least one job
		print (k < 0 ? 0 : k) }')
	print -r -- "$k $c $b"
}

complete() {	# complete <id> <token> <result-json>, with `commit` (infra v2b §5: 40 lowercase hex, else a 400) when the job's
	# evaluated commit is known ($crev, set by ready)
	typeset cb="\"agent_id\":\"$BUILDER_AGENT\",\"claim_token\":\"$2\",$3"
	[[ $crev == +([0-9a-f]) && ${#crev} == 40 ]] && cb="$cb,\"commit\":\"$crev\""
	api POST "/$1/complete" "{$cb}"
	log "complete $1 -> $code $(<"$J/resp") ($3)"
}
origins() {	# origins <recipes.tsv>: "<out>\t<commit>" for every served out: the first commit (any branch, oldest first) whose
	# docs/registry/recipes.tsv lists it, i.e. the commit that ADDED the row. Each batch's rows come from their own commit
	# (T1 540d65c, T2a b04d9ec, W0-W2 b080459 on wave5 ...), and one commit's tree may not evaluate another batch's outs, so a
	# row is evaluated at ITS commit, never at one pin for the whole file. Metadata + the recipes.tsv blobs only: a blobless
	# bare clone ($BUILDER_STATE/solnix.git, ~2 MB; 13 s to build the map once per served file, then read from <it>.origins.<blob>).
	# shortcut: the clone keeps the first BUILDER_FLAKE's URL; delete $BUILDER_STATE/solnix.git after changing the repo.
	typeset og=$BUILDER_STATE/solnix.git ou=${BUILDER_FLAKE#git+} ob oc	# o*: ksh93 name() functions share the caller's scope
	[[ $BUILDER_FLAKE == git+* ]] || return 1
	ob=$(git hash-object "$1") || return 1
	[[ -s $og.origins.$ob ]] && { cat "$og.origins.$ob"; return 0; }	# the same served file: the same map
	[[ -d $og ]] || bounded 300 git clone -q --bare --filter=blob:none "${ou%%\?*}" "$og" > /dev/null 2>&1 || return 1
	bounded 300 git -C "$og" fetch -q origin '+refs/heads/*:refs/heads/*' > /dev/null 2>&1
	for oc in $(git -C "$og" log --all --reverse --topo-order --format=%H -- docs/registry/recipes.tsv); do
		bounded 120 git -C "$og" show "$oc:docs/registry/recipes.tsv" 2> /dev/null | nawk -F'\t' -v c="$oc" 'NR > 1 && $9 ~ /^\/nix\/store\// {print $9 "\t" c}'
	done | nawk -F'\t' '!s[$1]++' > "$og.origins.new" && mv "$og.origins.new" "$og.origins.$ob" && cat "$og.origins.$ob"
}
revs() {	# revs <outs>: the commits a job's candidates come from, in the order tried: BUILDER_FLAKE's head (the commit whose
	# inputs are most likely served), then rows[].commit ($rowc) when the listing has it, else each out's origin commit,
	# newest first ($BUILDER_STATE/origins is in commit order, oldest first)
	typeset v=head k
	[[ $rowc == +([0-9a-f]) ]] && { print -r -- "$v $rowc"; return; }
	for k in $(nawk -F'\t' -v o=",$1," 'index(o, "," $1 ",") {c[++n] = $2} END {while (n) print c[n--]}' "$BUILDER_STATE/origins" 2> /dev/null); do
		[[ " $v " == *" $k "* ]] || v="$v $k"; done
	print -r -- "$v"
}
drv_for() {	# drv_for <pname> <outs> <rev|head>: "<out> <drv>^<output>" of the packages attr one of whose outputs is one of <outs>
	# (a row may name a non-default output: gcc's -lib, a wave6 -debug/-man), evaluated at <rev> of BUILDER_FLAKE (head: this
	# tick's locked head). The out must match, so a wrong commit only declines. An eval at a fixed rev never changes, so hits
	# are kept across ticks ($BUILDER_STATE/eval/<rev>.<system>.<attr>.outs, every output, a week) unless a GC took the hit's
	# .drv (the eval writes it again); misses only for the tick. (.outs: the one-line default-output caches before it are ignored)
	typeset n=${1%-[0-9]*} a r f=$3 c= w u s= k d e=$BUILDER_STATE/eval
	[[ $n == openssl3 ]] && n=openssl
	for w in ${n//-/ }; do if [[ -z $c ]]; then c=$w; else typeset -u u=${w:0:1}; c=$c$u${w:1}; fi; done	# gcc-wrapper -> gccWrapper
	[[ $f == head ]] && f=$flake || { [[ $BUILDER_FLAKE == *\?* ]] && f="$BUILDER_FLAKE&rev=$f" || f="$BUILDER_FLAKE?rev=$f"; }
	for a in "$n" "${n//-/_}" "$c"; do
		[[ " $s " == *" $a "* ]] && continue; s="$s $a"
		k=; [[ $f == *[?\&]rev=+([0-9a-f])* ]] && { k=${f##*[?&]rev=}; k=$e/${k%%&*}.$BUILDER_SYSTEM.$a.outs; }
		r=; if [[ -n $k && -s $k ]]; then r=$(<"$k"); d=${r%%$'\n'*}; d=${d#* }; [[ -e ${d%^*} ]] || r=; elif [[ -n $k && -e $k.miss ]]; then continue; fi
		if [[ -z $r ]]; then r=$(bounded 900 nix eval --raw "$f#packages.$BUILDER_SYSTEM.$a" --apply 'd: builtins.concatStringsSep "\n" (map (o: d.${o}.outPath + " " + d.drvPath + "^" + o) (d.outputs or ["out"]))' 2>/dev/null) ||
			{ [[ -n $k ]] && { mkdir -p "$e"; : > "$k.miss"; }; continue; }
			[[ -n $k ]] && { mkdir -p "$e"; print -r -- "$r" > "$k.${J##*/}" && mv "$k.${J##*/}" "$k"; }	# per job: jobs run in parallel
		fi
		# one line per output ("<out> <drv>^<output>"): the first that is one of <outs>
		r=$(print -r -- "$r" | nawk -v o=",$2," 'index(o, "," $1 ",") {print; exit}'); [[ -n $r ]] && { print -r -- "$r"; return 0; }
	done
	return 1
}
cand() {	# cand <out> <drv>^<output> <rev>, run in $(...): rc 0 and the served NarHash when this candidate can be rebuilt here
	# from served inputs alone (its drv then rooted in $J/root-drv), else rc 1 and why not. Never memo'd: its inputs may be
	# served by a later tick.
	typeset d=$2 m x f ins h y=$J/dry-${3:0:12}
	# hold the evaluated drv (and the drvs it references) until the job ends: an eval's temporary root dies with it
	nix-instantiate --add-root "$J/root-drv" --expr "import ${d%^*}" > /dev/null 2>&1 || { print -r -- "cannot root $d"; return 1; }
	h=$(served "$1") || { pubok || { print -r -- "$1 is not served (a first build is a submission: needs the submit key)"; return 1; }; h=first; }
	m=$BUILDER_STATE/tried/${d##*/}	# shortcut: a failed build is never retried for that drv; rm the file to retry
	[[ -f $m && $(<"$m") != ok ]] && { print -r -- "$(<"$m")"; return 1; }
	# submitted on an earlier tick (served by now or not): first() polls that submission instead of building again
	[[ -s $BUILDER_STATE/pub/${1##*/} ]] && pubok && { print first; return 0; }
	[[ $h == first && -f $m.pub ]] && { print -r -- "$1 is not served, and its first publish was refused here: $(<"$m.pub")"; return 1; }
	# the dry run covers the leaf AND its inputs: a dry run of a substitutable leaf alone lists nothing to build
	bounded 300 nix derivation show "${d%^*}" > "$J/drv.json" 2>&1 && ins=$(jq -r '.[].inputDrvs | to_entries[] |
	    .key + "^" + ((if (.value|type) == "array" then .value else .value.outputs end) | join(","))' "$J/drv.json") &&
	    bounded 600 nix build --dry-run --no-link "$d" $ins > "$y" 2>&1 || { print -r -- "dry run of $d failed ($y)"; return 1; }
	# fixed-output inputs (source tarballs, vendor dirs) may build here: their outputs are checked against the pinned
	# hash, so where they are fetched does not matter (NixOS fetches them on any builder). Any other input must substitute.
	x=0; for f in $(nawk -v d="${d%^*}" '/will be built/ {b=1; next} /will be fetched/ {b=0} b && $1 ~ /\.drv$/ && $1 != d {print $1}' "$y"); do
		# a builtin:unpack-channel drv (go.nix srcTree) only unpacks its one FOD input in the daemon: as fetchable as that FOD
		bounded 120 nix derivation show "$f" 2> /dev/null | jq -e '[.[] | ([.outputs[] | has("hash") or has("hashAlgo")] | all) or
		    (.builder == "builtin:unpack-channel" and (.inputDrvs | length) <= 1)] | all' > /dev/null || x=$((x + 1))
	done
	(( x == 0 )) || { print -r -- "the dry run would build $x non-fixed-output derivations here first ($y)"; return 1; }
	print -r -- "$h"
}
pubok() {	# may this host first-publish? BUILDER_PUBLISH=1 (with the bearer: it claims after) or dry; the key; the gates; never site-team
	[[ $BUILDER_PUBLISH == @(1|dry) && -r $BUILDER_PUBLISH_KEY && -f $BUILDER_GATES/scripts/cache-submit.py && $BUILDER_PUBLISH_ID != site-team ]] &&
	    [[ $BUILDER_PUBLISH == dry || -s $BUILDER_BEARER_FILE ]]
}
rowed() { nawk -F'\t' -v o="$1" 'NR > 1 && $9 == o {f = 1} END {exit !f}' "$BUILDER_STATE/recipes.tsv" 2> /dev/null; }	# a served row names <out>
fbuild() {	# fbuild <pname> <out> <drv>^<output>: the first build and every gate before a submission; rc 0 with the stage dir in $fst
	typeset fm=$BUILDER_STATE/tried/${3##*/} f x= w h k fr=
	ultimate() { [[ $(nix path-info --json "$1" 2> /dev/null | jq -r '.[].ultimate') == true ]]; }	# built by this host's daemon
	# a copy that came from elsewhere (not ultimate) is rebuilt here against itself: SAME makes it this host's build too
	nix-store --check-validity "$2" 2> /dev/null && ! ultimate "$2" && fr=--rebuild
	log "$1: first build of $3 ($C cores)${fr:+ (--rebuild: the copy here was not built here)}"
	bounded "$BUILDER_BUILD_SECS" nice -n "$BUILDER_NICE" nix build --option cores "$C" $fr --out-link "$J/root-pub" "${3%^*}^*" > "$fm.publog" 2>&1 ||
	    { egrep -q "No space left on device|is not valid|cannot remove '/var/tmp/[a-z]+-[0-9a-f]+'" "$fm.publog" ||
	          print -r -- "the first build of $3 failed${fr:+ or differs from the copy here} ($fm.publog)" > "$fm.pub"
	      log "decline $1: the first build of $3 failed${fr:+ or differs from the copy here} ($fm.publog)"; return 1; }
	[[ -n $fr ]] || ultimate "$2" || { log "decline $1: $2 was not built here (not ultimate)"; return 1; }
	# this store's copy intact (never repaired here: --repair-path on a shared host is forbidden)
	nix-store --verify-path "$2" > /dev/null 2>&1 || { print -r -- "nix-store --verify-path $2 failed: this store's copy is damaged" > "$fm.pub"; log "decline $1: $(<"$fm.pub")"; return 1; }
	# deps first: every reference already served, else wait (not memo'd: a later tick, or another publisher, serves them)
	for f in $(nix-store -q --references "$2"); do [[ $f == "$2" ]] || served "$f" > /dev/null || x="$x ${f#/nix/store/}"; done
	[[ -z $x ]] || { log "$1: $2 waits for its references to be served first:$x"; return 1; }
	# pre-submit-check.sh --leaf: the second build (--check SAME), drv-gate --leaf, publish-gate, store, closure, log, deps, the
	# stamp. A drv-leaf stamp for this out and NarHash from an earlier tick stands (a store path never changes): no third build.
	h=$(nix-store -q --hash "$2"); k=$BUILDER_STATE/stamps/${h#sha256:}.ok
	if [[ -s $k && $(cut -f1 "$k") == "$2" && $(cut -f5 "$k") == drv-leaf ]]; then log "$1: pre-submit-check --leaf passed on an earlier tick ($k)"
	else
		( export GATE_STAMP_DIR=$BUILDER_STATE/stamps GATE_PYTHON=$BUILDER_PYTHON; bounded "$BUILDER_BUILD_SECS" bash "$BUILDER_GATES/scripts/pre-submit-check.sh" --leaf "$2" ) > "$fm.presubmit" 2>&1; f=$?
		if (( f != 0 )) || ! grep -q "^PASS $2 " "$fm.presubmit"; then
			w=$(grep -E '^  [a-z]+: FAIL' "$fm.presubmit" | cut -d: -f1 | tr -d ' ' | paste -sd, -)
			# rc 2 = setup (no python, served file unreachable), a full disk, or only deps (served since our check): not the out's fault
			(( f == 1 )) && [[ ${w:-deps} != deps ]] && ! grep -q "No space left on device" "$fm.presubmit" && print -r -- "pre-submit-check.sh --leaf failed: ${w:-?} ($fm.presubmit)" > "$fm.pub"
			log "decline $1: pre-submit-check.sh --leaf $2 rc=$f (${w:-setup}; $fm.presubmit)"; return 1
		fi
	fi
	# the stage: a file:// cache holding the out's NAR and narinfo, with its references' served narinfos (nix copy needs them valid there)
	fst=$(mktemp -d "$BUILDER_STATE/pub/stage.XXXXXX") || return 1
	for f in $(nix-store -q --references "$2"); do [[ $f == "$2" ]] && continue; x=${f#/nix/store/}
		curl -sf -m 30 -o "$fst/${x%%-*}.narinfo" "$BUILDER_CACHE/${x%%-*}.narinfo" || { log "decline $1: cannot fetch the served narinfo of $f"; return 1; }; done
	print -r -- "$2" > "$fst.paths"; nix path-info --json "$2" > "$fst.pathinfo" 2> /dev/null &&
	    bounded 1800 nix copy --no-recursive --to "file://$fst?compression=xz" "$2" > "$fst.log" 2>&1 || { log "decline $1: cannot stage $2 ($fst.log)"; return 1; }
}
fsubmit() {	# fsubmit <out> <log> <cache-submit.py args>: the submitter (BUILDER_SUBMIT: a test hook); sets fres (its result) and fsid
	typeset o=$1 l=$2; shift 2	# a --poll in the args overrides the default (the last one wins)
	set -- --key "$BUILDER_PUBLISH_KEY" --builder "$BUILDER_PUBLISH_ID" --poll "$BUILDER_PUBLISH_POLL" "$@"
	if [[ -n ${BUILDER_SUBMIT:-} ]]; then set -- $BUILDER_SUBMIT "$@"; else set -- "$BUILDER_PYTHON" "$BUILDER_GATES/scripts/cache-submit.py" "$@"; fi
	bounded $(( BUILDER_PUBLISH_POLL + 900 )) "$@" > "$l" 2>&1
	fsid=$(sed -n 's/^  submission \([^ ]*\) .*/\1/p; s/^STATUS \([^ ]*\)$/\1/p' "$l" | tail -1)
	fres=$(sed -n 's/^  result: //p' "$l" | tail -1)
	[[ -n $fres ]] || fres="plan $(nawk -v p="$o" '$2 == p && $1 ~ /^[A-Z][A-Z-]+$/ && $1 !~ /^(SUBMIT|DRY-RUN|STATUS)$/ {print $1}' "$l")"	# its plan line
}
fverify() {	# fverify <out> <NarHash built here>: cache.solnix.io serves <out> with that NarHash, an 8UNr-only client fetches and
	# verifies the NAR, and a key that signs nothing is refused (a check that cannot fail proves nothing). The CDN may lag.
	typeset fh fx ft=0 fn fo=$2
	while :; do
		fx=$(mktemp -d "$BUILDER_STATE/pub/xdg.XXXXXX")	# an empty narinfo cache: a stale local answer cannot pass
		fh=$(served "$1") && [[ $fh != "$fo" ]] && { log "decline ${1#/nix/store/}: cache.solnix.io serves $fh, this host built $fo (another build was published)"; find "$fx" -depth -delete; return 1; }
		[[ -n $fh ]] && ( export XDG_CACHE_HOME=$fx; bounded 1800 nix store verify --store "$BUILDER_CACHE" --trusted-public-keys "$BUILDER_CACHE_KEY" "$1" ) > "$fx.ok" 2>&1 &&
		    ! ( export XDG_CACHE_HOME=$fx/n; bounded 300 nix store verify --no-contents --store "$BUILDER_CACHE" \
		          --trusted-public-keys bogus-1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= "$1" ) > "$fx.neg" 2>&1 &&
		    grep -q untrusted "$fx.neg" && { find "$fx" -depth -delete; rm -f "$fx".*; return 0; }
		fn="served ${fh:-nothing}; 8UNr: $(tail -1 "$fx.ok" 2> /dev/null | cut -c1-160); bogus key: $(tail -1 "$fx.neg" 2> /dev/null | cut -c1-120)"
		find "$fx" -depth -delete; rm -f "$fx".*
		(( (ft += 1) < 8 )) || { log "decline ${1#/nix/store/}: the client check failed: $fn"; return 1; }
		sleep "${BUILDER_VERIFY_WAIT:-20}"
	done
}
first() {	# first <pname> <out> <drv>^<output>: publish this host's first build of a served row's unserved out. rc 0 when it is
	# served with our NarHash and the client check passed ($nar: the served NarHash; the caller claims), else 1 (logged).
	typeset fm=$BUILDER_STATE/tried/${3##*/} fp=$BUILDER_STATE/pub/${2##*/} fb=$BUILDER_STATE/pub/backoff fl fst= fsid= fres= fz fn
	mkdir -p "$BUILDER_STATE/pub" "$BUILDER_STATE/stamps" "${fm%/*}"; fl=$fm.submit
	rowed "$2" || { log "decline $1: $2 is not an out of the served recipes.tsv: never published from here"; return 1; }
	if [[ -s $fp ]]; then fsubmit "$2" "$fl" --status "$(cut -f1 "$fp")" --poll 120	# a 429 is /begin's: polling goes on
	else
		fz=$(printf '%(%s)T' now); [[ -s $fb ]] && (( $(<"$fb") > fz )) && { log "$1: new submissions back off for $(( $(<"$fb") - fz )) s more (429)"; return 1; }
		fbuild "$1" "$2" "$3" || { [[ -n $fst ]] && { find "$fst" -depth -delete; rm -f "$fst".*; }; return 1; }
		fn=0; while (( (fn += 1) <= BUILDER_PUBLISH_SLOTS )); do mkdir "$BUILDER_STATE/pub/slot.$fn" 2> /dev/null && break; done
		(( fn <= BUILDER_PUBLISH_SLOTS )) || { find "$fst" -depth -delete; rm -f "$fst".*; log "$1: $BUILDER_PUBLISH_SLOTS submissions in flight; a later tick"; return 1; }
		set -- "$1" "$2" "$3" --cache-dir "$fst" --paths "$fst.paths" --pathinfo "$fst.pathinfo" --stamps "$BUILDER_STATE/stamps" --with-refs
		[[ $BUILDER_PUBLISH == 1 ]] && set -- "$@" --submit
		log "$1: submitting $2 as $BUILDER_PUBLISH_ID$([[ $BUILDER_PUBLISH == dry ]] && print ' (BUILDER_PUBLISH=dry: no /begin)')"
		fsubmit "$2" "$fl" "${@:4}"; rmdir "$BUILDER_STATE/pub/slot.$fn"; find "$fst" -depth -delete; rm -f "$fst".*
		# finalized but not resolved yet: later ticks poll its status (never a second submission of the same out)
		# shortcut: a submission that never resolves stays pending; rm $BUILDER_STATE/pub/<out> to submit again
		[[ -n $fsid && $fres == @(proposed|approved|finalized*) ]] && printf '%s\t%(%Y-%m-%dT%H:%M:%SZ)T\t%s\n' "$fsid" now "$(nix-store -q --hash "$2")" > "$fp"
	fi
	case $fres in
	promoted|'plan PUBLISHED')
		fverify "$2" "$([[ -s $fp ]] && cut -f3 "$fp" || nix-store -q --hash "$2")" || return 1
		rm -f "$fp"; print ok > "$fm"; nar=$(served "$2"); : > "$J/worked"	# tried/<drv> ok: the rebuild path never builds it again
		log "$1: published $2 ($fres${fsid:+ $fsid}), NarHash $nar: an 8UNr-only client verified it"; return 0 ;;
	proposed|approved) log "$1: $2 is $fres (${fsid:-?}): waiting for review (tier 1); polled on later ticks"; return 1 ;;
	rejected) print -r -- "rejected (${fsid:-?}): $(grep '^  status:' "$fl" | tail -1 | cut -c11-400)" > "$fm.pub"; rm -f "$fp"; log "decline $1: $(<"$fm.pub")"; return 1 ;;
	backoff\ +([0-9])) print $(( $(printf '%(%s)T' now) + ${fres#backoff } )) > "$fb"; log "$1: /begin answered 429: backing off ${fres#backoff } s"; return 1 ;;
	'plan READY') log "dry run: would submit $2 as $BUILDER_PUBLISH_ID ($fl)"; return 1 ;;
	'plan DRV-GATE-FAIL'|'plan BAD-LOCAL') print -r -- "cache-submit.py planned ${fres#plan } ($fl)" > "$fm.pub"; log "decline $1: $(<"$fm.pub")"; return 1 ;;
	*) log "$1: submission of $2 ${fsid:+$fsid }ended '${fres:-nothing}' ($fl); $([[ -s $fp ]] && print polled || print submitted again) on a later tick"; return 1 ;;
	esac
}
ready() {	# ready <pname> <outs>: 0 when the out ($out) was rebuilt here and is the NAR cache.solnix.io serves ($nar); else log why not.
	# A job lists every served out of its (pname, version), from several commits. Each commit (revs) that evaluates to one of
	# them is a candidate; the first whose out is served and whose dry run builds no non-FOD input here is the one rebuilt.
	# A served candidate (rebuild, vote) beats an unserved one (first publish, when this host may: cand says `first`).
	typeset d m nh r c why= seen= qd= qr=; nar= out= crev=
	for r in $(revs "$2"); do
		d=$(drv_for "$1" "$2" "$r") || { d=; continue; }
		[[ " $seen " == *" ${d#* } "* ]] && { d=; continue; }; seen="$seen ${d#* }"
		# a first candidate keeps its own root: the next candidate's cand() re-points root-drv
		c=$(cand "${d%% *}" "${d#* }" "$r") && { [[ $c == first ]] || { nar=$c; break; }
			[[ -n $qd ]] || { m=${d#* }; nix-instantiate --add-root "$J/root-first" --expr "import ${m%^*}" > /dev/null 2>&1 && qd=$d qr=$r; }; d=; continue; }
		why="$why${why:+; }$c [${r:0:12}]" d=
	done
	[[ -z $d && -n $qd ]] && d=$qd r=$qr nar=first
	[[ -n $d ]] || { log "decline $1: ${why:-no packages.$BUILDER_SYSTEM attr at its commit(s) or $flake evaluates to $2}"; return 1; }
	out=${d%% *} d=${d#* }; set -- "$1" "$out"
	# sent with the completion: rows[].commit, else the commit the candidate was evaluated at (head: this tick's locked rev)
	crev=${rowc:-}; [[ $crev == +([0-9a-f]) && ${#crev} == 40 ]] || { crev=$r; [[ $r == head ]] && { crev=${flake##*[?&]rev=}; crev=${crev%%&*}; }; }
	[[ $nar == first ]] && { log "$1: candidate ${r:0:12} $d (first publish: $2 is not served yet)${why:+ (skipped: $why)}"; first "$1" "$2" "$d"; return; }
	log "$1: candidate ${r:0:12} $d${why:+ (skipped: $why)}"
	m=$BUILDER_STATE/tried/${d##*/}
	[[ -s $BUILDER_BEARER_FILE ]] || { log "dry run: would fetch $2 and rebuild $d"; return 1; }	# no fetch or CPU for what it cannot claim
	# --rebuild compares the new build with the LOCAL copy, so that copy must be the served NAR (a copied-in one may not be).
	# Rooted for the job's life ($J/root-out) so a GC (min-free) cannot delete it before --rebuild compares against it.
	bounded 1800 nix-store --add-root "$J/root-out" -r "$2" > /dev/null 2>&1 && nh=$(nix-store -q --hash "$2") || { log "decline $1: cannot fetch the served $2"; return 1; }
	[[ $nh == "$nar" ]] || { log "decline $1: the local $2 has $nh, cache.solnix.io serves $nar"; return 1; }
	[[ -f $m ]] && { log "$1: rebuilt and matched on an earlier tick ($m)"; return 0; }
	mkdir -p "${m%/*}"; log "$1: rebuilding $d ($C cores)"
	bounded "$BUILDER_BUILD_SECS" nice -n "$BUILDER_NICE" nix build --option cores "$C" --no-link --rebuild "$d" > "$m.log" 2>&1 ||
	    { print -r -- "nix build --rebuild $d failed rc=$? ($m.log)" > "$m"
	      # a full disk or a store path GC'd mid-job says nothing about the recipe: no memo, so a later tick tries again
	      # (or a fixed W=/var/tmp/<kind>-<buildKey> left by a build killed in a reboot, owned by another nixbld: swept at start)
	      egrep -q "No space left on device|not valid, so checking is not possible|cannot remove '/var/tmp/[a-z]+-[0-9a-f]+'" "$m.log" &&
	          { rm -f "$m"; log "decline $1: the host, not the recipe, failed the rebuild ($m.log); will retry"; return 1; }
	      log "decline $1: $(<"$m")"; return 1; }
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
job() {	# job <pname> <outs> <version> <commit|->: one BUILD row, start to finish, in its own state dir. Runs in the background.
	JOBMAX=0	# inherited from the tick: at 1, bounded()'s own watchdog `&` would wait behind the command it guards
	typeset rowc=$4	# rows[].commit (drv_for evaluates it first)
	J=$BUILDER_STATE/job/${1//[!A-Za-z0-9._+-]/_}; mkdir -p "$J" || return 1
	ready "$1" "$2" && claim "$1" "$out" "$3" "$nar"
	rm -f "$J"/root-*	# the next GC may take them; a later tick re-fetches, re-evaluates or rebuilds
}
tick() {	# rc 0 when a job rebuilt or completed something: the loop then re-ticks soon
	typeset rows=$BUILDER_STATE/rows.json rec=$BUILDER_STATE/recipes.tsv z k c b p
	# a killed build leaves its fixed W (/var/tmp/<kind>-<buildKey>, the same path on every host) owned by its nixbld uid, and the next build
	# of that drv, as another uid, cannot replace it. Older than the longest build and no process of its owner in it: remove (wave4, chef uv).
	[[ -n ${BUILDER_WSWEEP:-} && $(/usr/bin/id -u) == 0 ]] && /usr/bin/ksh93 "$BUILDER_WSWEEP" $(( BUILDER_BUILD_SECS + 3600 )) | while read -r l; do log "$l"; done
	z=$(size); k=${z%% *} z=${z#* } c=${z%% *} b=${z#* }
	(( k > 0 )) || { log "not idle ($b of $BUILDER_NCPU CPUs busy; loadMax $BUILDER_LOAD_MAX, $c cores a job)"; return 1; }
	curl -sS -m 60 -o "$rec" "$BUILDER_RECIPES" && rows "$rows" "$rec" || { log "listing unavailable"; return 1; }
	plan "$rows" "$rec" > "$BUILDER_STATE/plan"; log "plan: $(cut -d' ' -f2 "$BUILDER_STATE/plan" | sort | uniq -c | tr -s ' \n' ' ')"
	[[ -s $BUILDER_BEARER_FILE ]] || log "dry run: no $BUILDER_BEARER_FILE, never claiming"
	grep ' BUILD ' "$BUILDER_STATE/plan" > "$BUILDER_STATE/builds" || return 1
	# every job evaluates the same commit, fetched once
	flake=$(bounded 300 nix flake metadata --json "$BUILDER_FLAKE" 2> /dev/null | jq -r '.url // empty'); : ${flake:=$BUILDER_FLAKE}
	# each served out's origin commit (the commit that added its row); a row's job evaluates there first
	origins "$rec" > "$BUILDER_STATE/origins" || : > "$BUILDER_STATE/origins"
	[[ -d $BUILDER_STATE/eval ]] && find "$BUILDER_STATE/eval" -type f \( -name '*.miss' -o -mtime +7 \) -exec rm -f {} +	# a miss may have been a timeout
	log "row origins: $(cut -f2 "$BUILDER_STATE/origins" | sort -u | wc -l | tr -d ' ') commits for $(wc -l < "$BUILDER_STATE/origins" | tr -d ' ') served outs"
	log "up to $k jobs of $c cores ($b of $BUILDER_NCPU CPUs busy), $flake"
	C=$c; rm -f "$BUILDER_STATE"/job/*/worked "$BUILDER_STATE"/job/*/root-*; JOBMAX=$k	# roots of a killed tick's jobs
	[[ -d $BUILDER_STATE/pub ]] && find "$BUILDER_STATE/pub" \( -name 'slot.*' -o -name 'stage.*' -o -name 'xdg.*' \) -prune -exec rm -r {} +	# a killed tick's
	while read -r bp bd bo bv br; do
		# pnames filters by pname only: with two rows of one pname the server may hand out the other one
		[[ $(jq --arg p "$bp" --arg s "$BUILDER_SYSTEM" '[.rows[] | select(.pname == $p and .system == $s)] | length' "$rows") == 1 ]] ||
		    { log "decline $bp: more than one $BUILDER_SYSTEM row for it"; continue; }
		job "$bp" "$bo" "$bv" "${br:--}" < /dev/null &
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
ready) mkdir -p "$BUILDER_STATE" && curl -sS -m 60 -o "$BUILDER_STATE/recipes.tsv" "$BUILDER_RECIPES" && ready "$2" "$3"; exit ;;	# by hand: never claims
esac
mkdir -p "$BUILDER_STATE" || exit 1
# at start (boot, restart), none of our builds runs yet: every fixed build dir whose owner has no process is from a killed build,
# whatever its age (dixi 2026-11-02 17:04Z: a reboot mid-tick left 7 cargo dirs, and their next builds as other uids failed)
[[ -n ${BUILDER_WSWEEP:-} && $(/usr/bin/id -u) == 0 ]] && /usr/bin/ksh93 "$BUILDER_WSWEEP" 0 | while read -r l; do log "$l"; done
# opportunistic: cap the project at BUILDER_CAP_SHARE% of the machine (it runs in it now, so the project is active), so builds
# that started while it was quiet stay within 2/3 of it when the user gets busy (prctl: replace, or add if none is set).
if [[ -n ${BUILDER_CAP_SHARE:-} ]]; then
	v=$(( BUILDER_NCPU * BUILDER_CAP_SHARE ))
	prctl -n project.cpu-cap -r -v "$v" -i project solnix-builder 2> /dev/null ||
	    prctl -n project.cpu-cap -t privileged -v "$v" -e deny -i project solnix-builder || log "cannot set project.cpu-cap $v"
	log "opportunistic: project.cpu-cap $v (${BUILDER_CAP_SHARE}% of $BUILDER_NCPU CPUs)"
fi
while :; do if tick; then sleep "$(pause busy)"; else sleep "$(pause)"; fi; done
