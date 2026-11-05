#!/usr/bin/ksh93
# solnix-builder -- the idle-time solnix.io queue drainer (modules/config/community/builder.nix, .kiro/steering/builder-queue.md).
# Build first, then claim only what was built. Each tick: if idle, read the public rows listing and plan every row against
# the SERVED recipes.tsv. For each BUILD row, in the listing's order, prove the job here before touching the queue:
# dry run (decline unless every input is a substitute), fetch the served out, rebuild it (`nix build --rebuild` fails
# unless the build is identical), and check the NarHash against the served narinfo's. Only then claim exactly that job
# (pnames=[pname], max 1) and complete it done. The queue spends an attempt AT CLAIM (registry.rebuild_claim), so a
# declined or failed job costs it nothing, and no job is ever completed failed because this host cannot do it.
# Without the bearer file (queueAuth sshsig: the readable key) it never claims (dry run).
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
# Retry-After seconds; neither is a failure. A failed gate, a differing --check or a rejection is memo'd (tried/<drv>.pub); a host
# failure (a full disk, a path GC'd mid-check, another nixbld uid's fixed build dir in the way) is not: a later tick retries.
# Multi-output (fleet5, infra 2026-11-04): a job lists every served out of its drv (gcc: out and -lib; wave6: out and -debug).
# Each unserved one is first-published as its own submission, deps first (firsts); the job is claimed once every listed out
# is served, and completed once, with the primary (the drv's first listed output: its default output when listed). A host
# that may not publish declines such a job. fbuild refuses an out whose served sibling is another build's NAR.
# Eval-anchored (protocol v2 (B), fleet4; BUILDER_EVAL=1, or dry: every step up to the signed /begin): a job that NO served row
# has at its (pname, target version) for this system (an older served version does not stop it: a version bump), but whose
# name (drv_for's rule: pname, _ or camelCase) is a packages.<system> attr at the head of an allowed branch
# (BUILDER_EVAL_BRANCHES: main then 26.11, wave6 if listed; no other) whose drv pname (attr pname, else the name minus its
# version) and version are the job's pname and target (gate is not illumos-gate-proto), is built here
# and submitted with {eval: attr, system, commit, branch, flake_nar_hash}. Before the build every non-fixed-output input of
# its drv closure must be served (else it waits: deps first); pre-submit-check.sh --eval (drv-gate --closure, the strict
# one: no reviewed row stands behind it, --check SAME, publish-gate, the log, the eval anchor) stamps it; it always ends a
# proposal, polled like tier 1 at the commit first submitted ($BUILDER_STATE/pub/eval.<pname>); only after `promoted` and
# the 8UNr client check is the job claimed and completed, with that commit.
#   solnix-builder vote <attr> <commit> <branch> <NarHash> [pname]   the second vote on someone's (or, same-host, our own)
#                    eval proposal: build that (attr, commit) here and complete the job with its NarHash and commit
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
# eval-anchored jobs: off unless set (module solnix.cache.build.evalAnchored); the branches whose heads are evaluated, in order
: ${BUILDER_EVAL:=0} ${BUILDER_EVAL_BRANCHES:=main 26.11}
# queue auth (infra 2026-11-04 R7): bearer (X-Solnix-Build), sshsig (X-Solnix-Sig by BUILDER_PUBLISH_KEY, the host's enrolled
# key) or both (until infra confirms sshsig per host); module solnix.cache.build.queueAuth. A transient failure (no answer,
# 502-504) is tried BUILDER_RETRIES times in all, BUILDER_RETRY_WAIT s more each time. BUILDER_SSH_KEYGEN: the store's.
: ${BUILDER_QUEUE_AUTH:=bearer} ${BUILDER_SSH_KEYGEN:=ssh-keygen} ${BUILDER_RETRIES:=3} ${BUILDER_RETRY_WAIT:=10}
# egress registration (infra s3): 1 on an identified builder (the module); at start, then every BUILDER_EGRESS_SECS (6 h)
: ${BUILDER_EGRESS:=0} ${BUILDER_EGRESS_SECS:=21600}
# sshsig: the key is the queue credential and the bearer is never read. Claiming is gated on -s $BUILDER_BEARER_FILE, so
# point that at the key's public half when the key is readable (a dry run when not): nothing secret, should anything read it.
# shortcut: an alias, so ready()/pubok()/claim() stay as they are while fleet5 changes ready(); a real authok() test after.
[[ $BUILDER_QUEUE_AUTH == sshsig ]] && { [[ -r $BUILDER_PUBLISH_KEY ]] && BUILDER_BEARER_FILE=$BUILDER_PUBLISH_KEY.pub || BUILDER_BEARER_FILE="$BUILDER_PUBLISH_KEY (not readable)"; }
J=$BUILDER_STATE C=0 flake=$BUILDER_FLAKE	# a job's state dir, its cores, the flake (locked once per tick)
EA= EB= EC= EN= cx=	# an eval job's attr, branch, commit, flake narHash (set only in its own job); extra completion fields
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
#   EVAL <attr> <version> <branch> <rev>  (BUILDER_EVAL on) no served row at that (pname, version, system), and the head <rev> of
#                    <branch> has packages.<system>.<attr> (drv_for's forms) whose drv pname and version ARE the job's
#   OTHER-SYSTEM     a system this host does not build
plan() {	# in claim order (priority ascending, then oldest): /build-queue/rows lists priority DESC, so deferred rows would come first
	# commit first: IFS=tab collapses empty fields, and it is never empty ("-" when the listing has none)
	jq -r '.rows | sort_by(.priority // 0, -(.age_secs // 0)) | .[] | [.commit // "-", .pname, .target // .current, .system, .reasons] | @tsv' "$1" |
	while IFS=$'\t' read -r rc p v s why; do
		[[ $rc == +([0-9a-f]) && ${#rc} == 40 ]] || rc=-	# a full git sha or nothing: it goes into a flake URL
		[[ $s == "$BUILDER_SYSTEM" ]] || { print -r -- "$p OTHER-SYSTEM $s"; continue; }
		n=${p%-"$v"}; [[ $n == openssl3 ]] && n=openssl	# the queue's pname for openssl-3 (recipes.tsv says openssl)
		row=$(nawk -F'\t' -v n="$n" -v v="$v" -v s="$s" '$1==n && $2==v && $8==s {if (!f) f=$7; o=o (o ? "," : "") $9} END {if (o) print f "\t" o}' "$2")
		[[ -z $row ]] && { print -r -- "$p $(eplan "$n" "$v" "$p")"; continue; }
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
eplan() {	# eplan <pname> <version> <row pname>, in $(...), for a job no served row has at (pname, version, system) (plan's
	# check; an older served version is a version bump, infra's rule too): "EVAL <attr> <version> <branch> <rev>" when an allowed
	# branch's head (eindex, in branch order) has an attr of drv_for's forms whose drv pname and version are exactly the job's
	# (pkg-config is not pkgconf, gate is not illumos-gate-proto); else NO-RECIPE, saying why
	typeset x=${1%-[0-9]*} c= w u
	[[ $BUILDER_EVAL != 0 && -s $BUILDER_STATE/eindex ]] || { print -r -- "NO-RECIPE $1 $2"; return; }
	# a proposal pending from an earlier tick is followed at its own commit, even once the head has moved on or lost the attr
	x=$BUILDER_STATE/pub/eval.${3//[!A-Za-z0-9._+-]/_}; [[ -s $x ]] && { read -r c w u < "$x"; print -r -- "EVAL $c $2 $w $u"; return; }
	x=${1%-[0-9]*} c=
	for w in ${x//-/ }; do if [[ -z $c ]]; then c=$w; else typeset -u u=${w:0:1}; c=$c$u${w:1}; fi; done
	nawk -F'\t' -v n="$1" -v v="$2" -v f=" $x ${x//-/_} $c " 'index(f, " " $3 " ") {
		if ($4 == n && $5 == v) { print "EVAL " $3 " " v " " $1 " " $2; ok = 1; exit }
		if (!m) m = "packages." $3 " at " $1 " is " $4 ($5 != "" ? " " $5 : "") }
	    END { if (!ok) print "NO-RECIPE " n " " v (m ? " (" m ": not this job)" : "") }' "$BUILDER_STATE/eindex"
}
eids() {	# eids <branch> <rev>: print $BUILDER_STATE/eval/<rev>.<system>.ids ("<attr>\t<pname>\t<version>" per packages.<system>
	# attr: the drv attr pname, else the name minus its version), evaluated once per rev and kept (an eval at a fixed rev never changes)
	typeset ik=$BUILDER_STATE/eval/$2.$BUILDER_SYSTEM.ids iu=${BUILDER_FLAKE%%\?*}
	mkdir -p "${ik%/*}"
	[[ -s $ik ]] || { bounded 900 nix eval --json "$iu?ref=$1&rev=$2#packages.$BUILDER_SYSTEM" --apply 'builtins.mapAttrs (n: d: let
	    t = builtins.tryEval (if builtins.isAttrs d then (let x = builtins.parseDrvName (d.name or "");
	      in "${toString (d.pname or x.name)}\t${toString (d.version or x.version)}") else "\t");
	    in if t.success then t.value else "\t")' 2> /dev/null | jq -r 'to_entries[] | "\(.key)\t\(.value)"' > "$ik.${J##*/}" &&
	    [[ -s $ik.${J##*/} ]] && mv "$ik.${J##*/}" "$ik"; rm -f "$ik.${J##*/}"; }
	[[ -s $ik ]] && print -r -- "$ik"
}
eindex() {	# eindex: $BUILDER_STATE/eindex = "<branch>\t<rev>\t<attr>\t<pname>\t<version>" for the heads of BUILDER_EVAL_BRANCHES (in
	# order; only main, 26.11 and wave6: the gates take no other), from the clone fetched here (onbranch() reads the same clone)
	typeset eb er ei eg=$BUILDER_STATE/solnix.git
	: > "$BUILDER_STATE/eindex"; [[ $BUILDER_EVAL != 0 && $BUILDER_FLAKE == git+* ]] || return 0; eclone
	for eb in $BUILDER_EVAL_BRANCHES; do
		[[ $eb == @(main|26.11|wave6) ]] || { log "eval: branch $eb is not main, 26.11 or wave6: never evaluated"; continue; }
		er=$(git -C "$eg" rev-parse -q --verify "refs/heads/$eb^{commit}" 2> /dev/null) && ei=$(eids "$eb" "$er") ||
		    { log "eval: no head or no packages.$BUILDER_SYSTEM eval for $eb"; continue; }
		nawk -v b="$eb" -v r="$er" '{print b "\t" r "\t" $0}' "$ei" >> "$BUILDER_STATE/eindex"
	done
	log "eval: $(wc -l < "$BUILDER_STATE/eindex" | tr -d ' ') attrs at the heads of $BUILDER_EVAL_BRANCHES"
}
eclone() {	# the bare clone of BUILDER_FLAKE's repo (origins() shares it), every head fetched now
	typeset eu=${BUILDER_FLAKE%%\?*} eg=$BUILDER_STATE/solnix.git
	[[ -d $eg ]] || bounded 300 git clone -q --bare --filter=blob:none "${eu#git+}" "$eg" > /dev/null 2>&1
	bounded 300 git -C "$eg" fetch -q origin '+refs/heads/*:refs/heads/*' > /dev/null 2>&1 || log "eval: cannot fetch ${eu#git+} (heads may be stale)"
}
onbranch() {	# onbranch <rev> <branch>: an allowed branch, and <rev> is its head or behind it in the clone eindex fetched (nix
	# evaluates ?ref=<b>&rev=<c> for ANY c it can fetch, measured with a wave6 commit: the ref proves nothing)
	[[ $2 == @(main|26.11|wave6) && " $BUILDER_EVAL_BRANCHES " == *" $2 "* && $1 == +([0-9a-f]) && ${#1} == 40 ]] &&
	    git -C "$BUILDER_STATE/solnix.git" merge-base --is-ancestor "$1" "refs/heads/$2" 2> /dev/null
}
has_man() { bounded 120 nix store ls --store "$BUILDER_CACHE" "$1/share/man" 2>/dev/null | grep -q '^\./man'; }
served() {	# served <out>: print the NarHash cache.solnix.io serves for <out> (sha256:<nix32>, the nix-store -q --hash form)
	typeset h=${1#/nix/store/}
	curl -sf -m 30 "$BUILDER_CACHE/${h%%-*}.narinfo" | nawk '/^NarHash: sha256:/ {print $2; f=1} END {exit !f}'
}

qhdr() {	# qhdr <method> <path> <body> <ts>: one attempt's auth headers, one a line. bearer: X-Solnix-Build. sshsig (infra
	# 2026-10-29, R7): X-Solnix-Sig = base64 (one line) of the armored `ssh-keygen -Y sign -n solnix-build-queue` by the
	# enrolled key over "<METHOD>\n<path>\n<sha256 hex of the body>\n<ts>\n" (the URL's path: /api/v1/build-queue/claim),
	# and X-Solnix-Timestamp: <ts>. both: all three. sshsig never reads the bearer file.
	typeset qp=${BUILDER_API#*://} qs
	[[ $BUILDER_QUEUE_AUTH == sshsig ]] || printf 'X-Solnix-Build: %s\n' "$(<"$BUILDER_BEARER_FILE")"
	[[ $BUILDER_QUEUE_AUTH == @(sshsig|both) ]] || return 0
	qp=/${qp#*/}$2
	qs=$(printf '%s\n%s\n%s\n%s\n' "$1" "$qp" "$(printf %s "$3" | digest -a sha256)" "$4" |
	    "$BUILDER_SSH_KEYGEN" -q -Y sign -n solnix-build-queue -f "$BUILDER_PUBLISH_KEY" 2> /dev/null | openssl base64 -A)
	[[ $qs == +([A-Za-z0-9+/=]) ]] || { log "queue $1 $2: cannot sign with $BUILDER_PUBLISH_KEY: sent without a signature" >&2; return 0; }
	printf 'X-Solnix-Sig: %s\nX-Solnix-Timestamp: %s\n' "$qs" "$4"
}
api() {	# api <method> <path> [json-body]: body in $J/resp (the job's own), HTTP code in $code (called directly, never in
	# $(...), so $code reaches the caller). The headers go to curl on stdin (-H @-), never in its arguments: psargs is
	# world-readable on illumos. Each attempt has its own headers: a signed request is single-use (infra R8: a resend is a
	# 403 replay) and ed25519 signs the same bytes the same way, so a retry signs anew at a later ts.
	typeset aqn=0 aqt=0 aqs
	while :; do
		while aqs=$(printf '%(%s)T' now); (( aqs <= aqt )); do sleep 1; done; aqt=$aqs
		code=$(qhdr "$1" "$2" "${3:-}" "$aqt" | curl -sS -m 60 -o "$J/resp" -w '%{http_code}' \
		    -X "$1" -H @- -H 'Content-Type: application/json' ${3:+--data-binary "$3"} "$BUILDER_API$2" 2>"$J/curl.err")
		[[ $code == @(000|502|503|504) ]] && (( (aqn += 1) < BUILDER_RETRIES )) || return 0
		log "queue $1 $2 -> $code: retry $aqn in $(( aqn * BUILDER_RETRY_WAIT )) s, signed anew"; sleep $(( aqn * BUILDER_RETRY_WAIT ))
	done
}
egress() {	# egress: register this host's egress address for its enrolled key (infra 2026-11-04 s3; logged by infra, not enforced
	# yet): POST <api>/builder/egress with exactly {version, kind, keyid, ip, ts, sig}, sig = the armored `ssh-keygen -Y sign
	# -n solnix-builder` over "solnix-builder-egress-v1\n<keyid>\n<ip>\n<ts>\n". The ip must be the one the request comes from,
	# which only the server sees: the last one registered ($BUILDER_STATE/egress), else 192.0.2.1 (TEST-NET-1), and after a 400
	# the reply's `seen`, signed anew, once. No third-party IP echo. Logged; never fails the builder.
	typeset egi egs egr egt egn=0 egf=$BUILDER_STATE/egress
	[[ $BUILDER_EGRESS == 1 ]] || return 0
	egi=$(cut -d' ' -f2 "$egf" 2> /dev/null); [[ $egi == +([0-9a-fA-F.:]) ]] || egi=192.0.2.1
	while :; do
		egt=$(printf '%(%s)T' now)
		egs=$(printf 'solnix-builder-egress-v1\n%s\n%s\n%s\n' "$BUILDER_PUBLISH_ID" "$egi" "$egt" |
		    "$BUILDER_SSH_KEYGEN" -q -Y sign -n solnix-builder -f "$BUILDER_PUBLISH_KEY" 2> /dev/null) && [[ $egs == -----BEGIN* ]] ||
		    { log "egress: cannot sign with $BUILDER_PUBLISH_KEY: not registered"; return 0; }
		egr=$(jq -nc --arg k "$BUILDER_PUBLISH_ID" --arg ip "$egi" --argjson ts "$egt" --arg sig "$egs"$'\n' \
		    '{version: 1, kind: "builder_egress", keyid: $k, ip: $ip, ts: $ts, sig: $sig}' |
		    curl -sS -m 30 -o "$egf.resp" -w '%{http_code}' -H 'Content-Type: application/json' --data-binary @- "${BUILDER_API%/build-queue}/builder/egress" 2> "$egf.err")
		log "egress: $BUILDER_PUBLISH_ID $egi -> $egr $(tr -d '\n' < "$egf.resp" 2> /dev/null | cut -c1-300)$([[ $egr == 000 ]] && cut -c1-200 "$egf.err")"
		[[ $egr == 200 ]] && { print -r -- "$egt $egi" > "$egf"; return 0; }
		egs=$(jq -r '.seen // empty' "$egf.resp" 2> /dev/null)
		[[ $egr == 400 && $egn == 0 && $egs == +([0-9a-fA-F.:]) && $egs != "$egi" ]] || return 0
		egi=$egs egn=1	# the address the server saw
	done
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
	[[ $crev == +([0-9a-f]) && ${#crev} == 40 ]] && cb="$cb,\"commit\":\"$crev\""; [[ -n $cx ]] && cb="$cb,$cx"
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
drv_for() {	# drv_for <pname> <outs> <rev|head>: one "<out> <drv>^<output>" line for EVERY output of the packages attr that is one of
	# <outs>, in the drv's output order (the default output first: the first line is the job's primary, what its completion
	# names). A row may name a non-default output (gcc's -lib, a wave6 -debug/-man). Evaluated at <rev> of BUILDER_FLAKE (head: this
	# tick's locked head; evattr keeps the answer per rev). The out must match, so a wrong commit only declines.
	typeset n=${1%-[0-9]*} a r f=$3 c= w u s=
	[[ $n == openssl3 ]] && n=openssl
	for w in ${n//-/ }; do if [[ -z $c ]]; then c=$w; else typeset -u u=${w:0:1}; c=$c$u${w:1}; fi; done	# gcc-wrapper -> gccWrapper
	[[ $f == head ]] && f=$flake || { [[ $BUILDER_FLAKE == *\?* ]] && f="$BUILDER_FLAKE&rev=$f" || f="$BUILDER_FLAKE?rev=$f"; }
	for a in "$n" "${n//-/_}" "$c"; do
		[[ " $s " == *" $a "* ]] && continue; s="$s $a"
		r=$(evattr "$f" "$a") || continue
		# one line per output ("<out> <drv>^<output>"): every one that is one of <outs>
		r=$(print -r -- "$r" | nawk -v o=",$2," 'index(o, "," $1 ",")'); [[ -n $r ]] && { print -r -- "$r"; return 0; }
	done
	return 1
}
evattr() {	# evattr <flake URL> <attr>, in $(...): one "<out> <drv>^<output>" line per output of packages.<system>.<attr> there, the
	# default output (outPath) first. With a rev in the URL the answer is kept ($BUILDER_STATE/eval/<rev>.<system>.<attr>.outs, a
	# week) unless a GC took its .drv; a miss only for the tick. (.outs: the one-line default-output caches before it are ignored)
	typeset k= r d e=$BUILDER_STATE/eval
	[[ $1 == *[?\&]rev=+([0-9a-f])* ]] && { k=${1##*[?&]rev=}; k=$e/${k%%&*}.$BUILDER_SYSTEM.$2.outs; }
	if [[ -n $k && -s $k ]]; then r=$(<"$k"); d=${r%%$'\n'*}; d=${d#* }; [[ -e ${d%^*} ]] && { print -r -- "$r"; return 0; }; elif [[ -n $k && -e $k.miss ]]; then return 1; fi
	r=$(bounded 900 nix eval --raw "$1#packages.$BUILDER_SYSTEM.$2" --apply 'd: builtins.concatStringsSep "\n" (map (o: d.${o}.outPath + " " + d.drvPath + "^" + o) (d.outputs or ["out"]))' 2>/dev/null) ||
	    { [[ -n $k ]] && { mkdir -p "$e"; : > "$k.miss"; }; return 1; }
	[[ -n $k ]] && { mkdir -p "$e"; print -r -- "$r" > "$k.${J##*/}" && mv "$k.${J##*/}" "$k"; }	# per job: jobs run in parallel
	print -r -- "$r"
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
ultimate() { [[ $(nix path-info --json "$1" 2> /dev/null | jq -r '.[].ultimate') == true ]]; }	# built by this host's daemon
unserved() { [[ -s $BUILDER_STATE/pub/${1##*/} ]] || ! served "$1" > /dev/null; }	# not served, or our submission of it is pending
fbuild() {	# fbuild <pname> <out> <drv>^<output>: the first build and every gate before a submission; rc 0 with the stage dir in $fst.
	# fwait=1 when it only waits for references to be served (firsts() retries it after a sibling publishes)
	typeset fm=$BUILDER_STATE/tried/${3##*/} f x= w h k fr= fy=
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
	# every served sibling output of the drv is the NAR built here: one NOT valid here was just built by drv^*, and --check below
	# compares only this host's two builds, so it cannot see an out of this build next to a -lib/-debug of another (measured)
	for f in $(nix-store -q --outputs "${3%^*}"); do [[ $f == "$2" ]] && continue; h=$(served "$f") || continue
		k=$(nix-store -q --hash "$f" 2> /dev/null) || { log "decline $1: its served sibling $f is not valid here (a later tick)"; return 1; }
		[[ $h == "$k" ]] && continue
		print -r -- "cache.solnix.io serves its sibling $f with $h, this host built $k: $2 would be from another build" > "$fm.pub"; log "decline $1: $(<"$fm.pub")"; return 1
	done
	# deps first: every reference already served, else wait (not memo'd: a later tick, or another publisher, serves them)
	for f in $(nix-store -q --references "$2"); do [[ $f == "$2" ]] || served "$f" > /dev/null || x="$x ${f#/nix/store/}"; done
	[[ -z $x ]] || { fwait=1; log "$1: $2 waits for its references to be served first:$x"; return 1; }
	# pre-submit-check.sh --leaf: the second build (--check SAME), drv-gate --leaf, publish-gate, store, closure, log, deps, the
	# stamp. A drv-leaf stamp for this out and NarHash from an earlier tick stands (a store path never changes): no third build.
	typeset fk=drv-leaf fa=--leaf; [[ -n ${EA:-} ]] && fk="drv-closure"$'\t'"eval:$EA:$BUILDER_SYSTEM:$EC:$EB" fa="--eval $EA $BUILDER_SYSTEM $EC $EB"
	h=$(nix-store -q --hash "$2"); k=$BUILDER_STATE/stamps/${h#sha256:}.ok
	if [[ -s $k && $(cut -f1 "$k") == "$2" && $(cut -f5- "$k") == "$fk" ]]; then log "$1: pre-submit-check ${fa%% *} passed on an earlier tick ($k)"
	else
		# the --check builds in this drv's fixed W (/var/tmp/<kind>-<buildKey>) again, maybe as another nixbld uid, which cannot remove
		# a W the first build left (dixa a64t openssl, 2026-11-04: 13 h memo'd). NixOS's sandbox gives each build its own /build; here
		# that W goes first, unless its owner runs any process (a live build). The tick-start sweep cannot: this tick's first build made it.
		x=$(bounded 120 nix derivation show "${3%^*}" 2> /dev/null | jq -r '.[].env.buildKey // empty'); [[ $x == +([0-9a-f]) ]] || x=
		[[ -n $x && -n ${BUILDER_WSWEEP:-} && $(/usr/bin/id -u) == 0 ]] && /usr/bin/ksh93 "$BUILDER_WSWEEP" 0 "$x" | while read -r l; do log "$1: $l"; done
		( export GATE_STAMP_DIR=$BUILDER_STATE/stamps GATE_PYTHON=$BUILDER_PYTHON GATE_FLAKE=$BUILDER_FLAKE; bounded "$BUILDER_BUILD_SECS" bash "$BUILDER_GATES/scripts/pre-submit-check.sh" $fa "$2" ) > "$fm.presubmit" 2>&1; f=$?
		if (( f != 0 )) || ! grep -q "^PASS $2 " "$fm.presubmit"; then
			w=$(grep -E '^  [a-z]+: FAIL' "$fm.presubmit" | cut -d: -f1 | tr -d ' ' | paste -sd, -)
			# the host, not the out: a full disk, a path GC'd mid-check, or a W of another uid in the way. pre-submit keeps one line of
			# a failed --check, so the check's log (nix log: the last build's, measured on chef2) is read for this drv's OWN W only,
			# which fails a build at its first line (rm; mkdir: GNU or illumos wording): a check that prints another key's W and then
			# DIFFERS is still memo'd. A host failure is not memo'd: a later tick retries.
			fy=$(grep -E "No space left on device|is not valid" "$fm.presubmit" | head -1)
			[[ -z $fy && -n $x && ,$w, == *,check,* ]] && fy=$(bounded 120 nix log "${3%^*}" 2> /dev/null | grep -E "/var/tmp/[a-z]+-${x}['\"]?[:;] (Permission denied|File exists)" | head -1)
			[[ -n $fy ]] && { log "decline $1: the host, not the out, failed pre-submit-check.sh ${fa%% *} $2 (${fy:0:200}; $fm.presubmit): not memo'd, a later tick retries"; return 1; }
			# rc 2 = setup (no python, served file unreachable), or only deps (served since our check): not the out's fault
			(( f == 1 )) && [[ ${w:-deps} != @(deps|inputs|deps,inputs) ]] && print -r -- "pre-submit-check.sh ${fa%% *} failed: ${w:-?} ($fm.presubmit)" > "$fm.pub"
			log "decline $1: pre-submit-check.sh ${fa%% *} $2 rc=$f (${w:-setup}; $fm.presubmit)"; return 1
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
	if [[ -n ${EA:-} ]]; then rowed "$2" && { log "decline $1: a served row names $2: it is published the row way, never --eval"; return 1; }
	else rowed "$2" || { log "decline $1: $2 is not an out of the served recipes.tsv: never published from here"; return 1; }; fi
	if [[ -s $fp ]]; then fsubmit "$2" "$fl" --status "$(cut -f1 "$fp")" --poll 120	# a 429 is /begin's: polling goes on
	else
		fz=$(printf '%(%s)T' now); [[ -s $fb ]] && (( $(<"$fb") > fz )) && { log "$1: new submissions back off for $(( $(<"$fb") - fz )) s more (429)"; return 1; }
		fbuild "$1" "$2" "$3" || { [[ -n $fst ]] && { find "$fst" -depth -delete; rm -f "$fst".*; }; return 1; }
		fn=0; while (( (fn += 1) <= BUILDER_PUBLISH_SLOTS )); do mkdir "$BUILDER_STATE/pub/slot.$fn" 2> /dev/null && break; done
		(( fn <= BUILDER_PUBLISH_SLOTS )) || { find "$fst" -depth -delete; rm -f "$fst".*; log "$1: $BUILDER_PUBLISH_SLOTS submissions in flight; a later tick"; return 1; }
		set -- "$1" "$2" "$3" --cache-dir "$fst" --paths "$fst.paths" --pathinfo "$fst.pathinfo" --stamps "$BUILDER_STATE/stamps" --with-refs
		[[ -n ${EA:-} ]] && set -- "$@" --eval "$EA" "$BUILDER_SYSTEM" "$EC" "$EB" ${EN:+--flake-nar-hash "$EN"}
		[[ $BUILDER_PUBLISH == 1 ]] && set -- "$@" --submit
		log "$1: submitting $2 as $BUILDER_PUBLISH_ID$([[ $BUILDER_PUBLISH == dry ]] && print ' (BUILDER_PUBLISH=dry: no /begin)')"
		fsubmit "$2" "$fl" "${@:4}"; rmdir "$BUILDER_STATE/pub/slot.$fn"; find "$fst" -depth -delete; rm -f "$fst".*
		# finalized but not resolved yet: later ticks poll its status (never a second submission of the same out)
		# shortcut: a submission that never resolves stays pending; rm $BUILDER_STATE/pub/<out> to submit again
		[[ -n $fsid && $fres == @(proposed|approved|finalized*) ]] && printf '%s\t%(%Y-%m-%dT%H:%M:%SZ)T\t%s\n' "$fsid" now "$(nix-store -q --hash "$2")" > "$fp" &&
		    [[ -n ${EA:-} ]] && printf '%s\t%s\t%s\n' "$EA" "$EB" "$EC" > "$BUILDER_STATE/pub/eval.${1//[!A-Za-z0-9._+-]/_}"	# later ticks: this commit
	fi
	case $fres in
	promoted|'plan PUBLISHED')
		fverify "$2" "$([[ -s $fp ]] && cut -f3 "$fp" || nix-store -q --hash "$2")" || return 1
		rm -f "$fp" "$BUILDER_STATE/pub/eval.${1//[!A-Za-z0-9._+-]/_}"; print ok > "$fm"; nar=$(served "$2"); : > "$J/worked"	# tried/<drv> ok: the rebuild path never builds it again
		log "$1: published $2 ($fres${fsid:+ $fsid}), NarHash $nar: an 8UNr-only client verified it"; return 0 ;;
	proposed|approved) log "$1: $2 is $fres (${fsid:-?}): waiting for review (tier 1); polled on later ticks"; return 1 ;;
	rejected) print -r -- "rejected (${fsid:-?}): $(grep '^  status:' "$fl" | tail -1 | cut -c11-400)" > "$fm.pub"; rm -f "$fp" "$BUILDER_STATE/pub/eval.${1//[!A-Za-z0-9._+-]/_}"; log "decline $1: $(<"$fm.pub")"; return 1 ;;
	backoff\ +([0-9])) print $(( $(printf '%(%s)T' now) + ${fres#backoff } )) > "$fb"; log "$1: /begin answered 429: backing off ${fres#backoff } s"; return 1 ;;
	'plan READY') log "dry run: would submit $2 as $BUILDER_PUBLISH_ID ($fl)"; return 1 ;;
	'plan DRV-GATE-FAIL'|'plan BAD-LOCAL') print -r -- "cache-submit.py planned ${fres#plan } ($fl)" > "$fm.pub"; log "decline $1: $(<"$fm.pub")"; return 1 ;;
	*) log "$1: submission of $2 ${fsid:+$fsid }ended '${fres:-nothing}' ($fl); $([[ -s $fp ]] && print polled || print submitted again) on a later tick"; return 1 ;;
	esac
}
firsts() {	# firsts <pname> <drv_for lines>: first-publish every unserved listed output of one drv, one submission each (first()), the
	# primary (line 1) last, so a sibling refused here stops the job before the primary is offered; in passes until one makes no
	# progress: an out that references an unserved sibling waits (fbuild sets fwait) and goes in a later pass, after it (deps first).
	# rc 0: every listed out is served and the primary was published now ($nar: claim it); 2: every listed out is served and the
	# primary was served before (the rebuild path proves it; no build when this host's own build is the served NAR); 1: not yet
	typeset g gx gt= gz gk= gw gn=1 gy= gl=${2%%$'\n'*} gp gd; gp=${gl%% *} gd=${gl#* }
	for g in $(print -r -- "$2" | nawk '{l[NR] = $1 "=" $2} END {for (i = NR; i > 0; i--) print l[i]}'); do gx=${g%=*}
		unserved "$gx" || continue
		# refused here before (rejected, a failed gate): this host cannot complete the job; decline before any build
		[[ ! -s $BUILDER_STATE/pub/${gx##*/} && -f $BUILDER_STATE/tried/${g##*/}.pub ]] &&
		    { log "decline $1: $gx is not served, and its first publish was refused here: $(<"$BUILDER_STATE/tried/${g##*/}.pub")"; return 1; }
		gt="$gt $g"
	done; gz=$gt
	while (( gn )) && [[ -n $gt ]]; do gn=0 gw=
		for g in $gt; do fwait=
			if first "$1" "${g%=*}" "${g#*=}"; then gn=1 gk="$gk ${g%=*}"; [[ ${g%=*} == "$gp" ]] && gy=$nar
			elif [[ -f $BUILDER_STATE/tried/${g##*/}.pub ]]; then return 1	# refused now (first() logged why)
			elif [[ -n $fwait ]]; then gw="$gw $g"; fi	# waits for a sibling: retried after this pass
		done; gt=$gw	# a proposal, a 429, no slot: polled on a later tick
	done
	# each out unserved at the start published AND client-verified now (a promoted out that fails the 8UNr check is served too)
	for g in $gz; do [[ " $gk " == *" ${g%=*} "* ]] || { [[ $2 == *$'\n'* ]] && log "$1: ${g%=*} is not published yet: the job is claimed once every listed out is"; return 1; }; done
	[[ -n $gy ]] && { nar=$gy; return 0; }
	nar=$(served "$gp") || return 1
	ultimate "$gp" && [[ ! -f $BUILDER_STATE/tried/${gd##*/} && $(nix-store -q --hash "$gp" 2> /dev/null) == "$nar" ]] &&
	    { print ok > "$BUILDER_STATE/tried/${gd##*/}"; log "$1: $gp was built here and is the served NAR $nar"; }
	return 2
}
ready() {	# ready <pname> <outs>: 0 when the out ($out) was rebuilt here and is the NAR cache.solnix.io serves ($nar); else log why not.
	# A job lists every served out of its (pname, version), from several commits. Each commit (revs) that evaluates to one of
	# them is a candidate; the first whose out is served and whose dry run builds no non-FOD input here is the one rebuilt.
	# A served candidate (rebuild, vote) beats an unserved one (first publish, when this host may: cand says `first`).
	typeset d ds m nh r c why= seen= qd= qr= qs= qu qx; nar= out= crev=
	for r in $(revs "$2"); do
		ds=$(drv_for "$1" "$2" "$r") || { d=; continue; }
		d=${ds%%$'\n'*}	# the primary: the drv's first listed output (its default output when the job lists it)
		[[ " $seen " == *" ${d#* } "* ]] && { d=; continue; }; seen="$seen ${d#* }"
		# a first candidate keeps its own root: the next candidate's cand() re-points root-drv
		c=$(cand "${d%% *}" "${d#* }" "$r") && { [[ $c == first ]] || { nar=$c; break; }
			[[ -n $qd ]] || { m=${d#* }; nix-instantiate --add-root "$J/root-first" --expr "import ${m%^*}" > /dev/null 2>&1 && qd=$d qr=$r qs=$ds; }; d=; continue; }
		why="$why${why:+; }$c [${r:0:12}]" d=
	done
	[[ -z $d && -n $qd ]] && d=$qd r=$qr nar=first ds=$qs
	[[ -n $d ]] || { log "decline $1: ${why:-no packages.$BUILDER_SYSTEM attr at its commit(s) or $flake evaluates to $2}"; return 1; }
	out=${d%% *} d=${d#* }; set -- "$1" "$out"
	# sent with the completion: rows[].commit, else the commit the candidate was evaluated at (head: this tick's locked rev)
	crev=${rowc:-}; [[ $crev == +([0-9a-f]) && ${#crev} == 40 ]] || { crev=$r; [[ $r == head ]] && { crev=${flake##*[?&]rev=}; crev=${crev%%&*}; }; }
	# the job lists every served out of its drv (gcc's out and -lib, wave6's out and -debug): one completion, with the primary,
	# once every one is served (infra 2026-11-04). A host that may publish first-publishes the unserved ones; any other declines.
	qu=; for qx in $(print -r -- "$ds" | nawk 'NR > 1 {print $1}'); do unserved "$qx" && qu="$qu ${qx#/nix/store/}"; done
	if [[ $nar == first || -n $qu ]]; then
		[[ $nar == first ]] || pubok || { log "decline $1: $2 is served, its sibling output(s)$qu not: the job is claimed once every listed out is (a first publish needs the submit key)"; return 1; }
		if [[ -z $qu ]]; then qx="$2 is not served yet"; elif [[ $nar == first ]]; then qx="$2 and its sibling(s)$qu are not served yet"
		else qx="its sibling(s)$qu are not served yet, $2 is"; fi
		log "$1: candidate ${r:0:12} $d (first publish: $qx)${why:+ (skipped: $why)}"
		firsts "$1" "$ds"; c=$?; (( c == 2 )) || return $c
	fi
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
eready() {	# eready <pname> <attr> <version> <branch> <rev>: 0 when packages.<system>.<attr> at <rev> of <branch> was built here,
	# gated, promoted as an eval proposal and verified ($out, $nar, $crev = the commit); else log why not. A proposal pending
	# from an earlier tick is followed at the commit it was submitted with (pub/eval.<pname>), never the moving head.
	typeset ep=$BUILDER_STATE/pub/eval.${1//[!A-Za-z0-9._+-]/_} en=${1%-"$3"} r d m f x i; nar= out= crev=
	EA=$2 EB=$4 EC=$5; [[ -s $ep ]] && { read -r EA EB EC < "$ep"; log "$1: eval proposal pending: $EA at $EB ${EC:0:12}"; }
	pubok || { log "decline $1: eval-anchored needs this host's publish key and gates (BUILDER_PUBLISH 1|dry)"; return 1; }
	onbranch "$EC" "$EB" || { log "decline $1: $EC is not on $EB here (allowed: $BUILDER_EVAL_BRANCHES): never an eval anchor"; return 1; }
	f="${BUILDER_FLAKE%%\?*}?ref=$EB&rev=$EC"
	# the job's identity at THIS commit: drv pname = the job's pname, version = its target (gate is not illumos-gate-proto)
	x=$(eids "$EB" "$EC") && i=$(nawk -F'\t' -v a="$EA" '$1 == a {print $2 " " $3; exit}' "$x") && [[ $i == "$en $3" ]] ||
	    { log "decline $1: packages.$BUILDER_SYSTEM.$EA at ${EC:0:12} is '${i:-nothing}', not $en $3"; return 1; }
	r=$(evattr "$f" "$EA") || { log "decline $1: packages.$BUILDER_SYSTEM.$EA does not evaluate at $EB ${EC:0:12}"; return 1; }
	r=${r%%$'\n'*}	# the default output: what packages.<system>.<attr>.outPath is, and what infra's evaluator anchors
	out=${r%% *} d=${r#* } crev=$EC m=$BUILDER_STATE/tried/${d##*/}
	nix-instantiate --add-root "$J/root-first" --expr "import ${d%^*}" > /dev/null 2>&1 || { log "decline $1: cannot root $d"; return 1; }
	if [[ ! -s $BUILDER_STATE/pub/${out##*/} ]]; then	# not submitted yet
		served "$out" > /dev/null && { log "decline $1: $out is served already (another publish): a row, then a rebuild vote, later"; return 1; }
		[[ -f $m.pub ]] && { log "decline $1: its first publish was refused here: $(<"$m.pub")"; return 1; }
		# the strict gate on the drv graph first (no build needed): an eval out has no reviewed row behind it. Not memo'd.
		( export GATE_PYTHON=$BUILDER_PYTHON; bounded 600 bash "$BUILDER_GATES/scripts/drv-gate.sh" --closure "${d%^*}" ) > "$J/eval-closure" 2>&1 ||
		    { log "decline $1: drv-gate --closure FAILs ${d%^*} ($(grep -c '^FAIL A' "$J/eval-closure") findings, first: $(nawk '/^FAIL A/ {print; exit}' "$J/eval-closure" | cut -c1-200))"; return 1; }
		# deps first on the drv graph: every non-fixed-output input out is published (or waits for a later tick)
		i=$("$BUILDER_PYTHON" "$BUILDER_GATES/scripts/gate-checks.py" inputs "${d%^*}" 2> /dev/null) || { log "decline $1: cannot read the inputs of $d"; return 1; }
		x=; for r in $i; do served "$r" > /dev/null || x="$x ${r#/nix/store/}"; done
		[[ -z $x ]] || { log "$1: eval $EA waits for non-FOD inputs to be published first:$x"; return 1; }
		EN=$(bounded 300 nix flake metadata --json "${BUILDER_FLAKE%%\?*}?rev=$EC" 2> /dev/null | jq -r '.locked.narHash // empty')
		[[ -n $EN ]] || { log "decline $1: no flake narHash for $EC"; return 1; }
	fi
	log "$1: eval candidate packages.$BUILDER_SYSTEM.$EA at $EB ${EC:0:12} = $out ($d)"
	nar=first; first "$1" "$out" "$d"
}
ejob() {	# ejob <pname> <attr> <version> <branch> <rev>: one EVAL row, in its own state dir, in the background (as job)
	JOBMAX=0; typeset rowc=-
	J=$BUILDER_STATE/job/${1//[!A-Za-z0-9._+-]/_}; mkdir -p "$J" || return 1
	[[ $BUILDER_EVAL == dry ]] && BUILDER_PUBLISH=dry	# this job only (a subshell): every step up to /begin
	eready "$@" && claim "$1" "$out" "$3" "$nar"
	rm -f "$J"/root-*
}
vote() {	# vote <attr> <commit> <branch> <NarHash> [pname]: the second vote on an eval proposal (condition 4): build packages.<system>.
	# <attr> at <commit> here (a fresh build, or --rebuild of a copy already here: a second build dir), and only if its NarHash
	# is the proposal's, claim the job and complete it done with that NarHash and commit. If this host built or proposed the out
	# itself, the vote says "independence":"same-host" (dixa, the only aarch64 host). Claims only with BUILDER_EVAL=1.
	typeset va=$1 vc=$2 vb=$3 vh=$4 vn=${5:-} vi vr vd vo vm vs=; J=$BUILDER_STATE/job/vote.${1//[!A-Za-z0-9._+-]/_}; mkdir -p "$J" "$BUILDER_STATE/tried"
	eclone; onbranch "$vc" "$vb" || { log "vote $va: $vc is not on $vb (allowed: $BUILDER_EVAL_BRANCHES): no vote"; return 1; }
	vi=$(eids "$vb" "$vc") && vi=$(nawk -F'\t' -v a="$va" '$1 == a {print $2 " " $3; exit}' "$vi") && [[ -n ${vi%% *} && -n ${vi#* } ]] ||
	    { log "vote $va: no packages.$BUILDER_SYSTEM.$va with a pname and version at ${vc:0:12}"; return 1; }
	[[ -z $vn || $vn == "${vi%% *}" ]] || { log "vote $va: at ${vc:0:12} it is ${vi%% *}, not $vn: no vote"; return 1; }
	vr=$(evattr "${BUILDER_FLAKE%%\?*}?ref=$vb&rev=$vc" "$va") || { log "vote $va: does not evaluate at ${vc:0:12}"; return 1; }
	vr=${vr%%$'\n'*}	# the default output (the proposal's out)
	vo=${vr%% *} vd=${vr#* } vm=$BUILDER_STATE/tried/${vd##*/}.vote
	[[ -s $BUILDER_STATE/pub/${vo##*/} ]] && vs=1; grep -qs "^$vo"$'\t' "$BUILDER_STATE"/stamps/*.ok && vs=1
	if nix-store --check-validity "$vo" 2> /dev/null; then
		[[ $(nix path-info --json "$vo" 2> /dev/null | jq -r '.[].ultimate') == true ]] && vs=1	# built here before: same-host
		log "vote $va: rebuilding $vd (a second build dir: --rebuild of the copy here)"
		bounded "$BUILDER_BUILD_SECS" nice -n "$BUILDER_NICE" nix build --no-link --rebuild "$vd" > "$vm.log" 2>&1 || { log "vote $va: --rebuild failed or differs ($vm.log): no vote"; return 1; }
	else log "vote $va: building $vd"
		bounded "$BUILDER_BUILD_SECS" nice -n "$BUILDER_NICE" nix build --out-link "$J/root-vote" "$vd" > "$vm.log" 2>&1 || { log "vote $va: the build failed ($vm.log): no vote"; return 1; }
	fi
	nar=$(nix-store -q --hash "$vo"); out=$vo crev=$vc
	[[ $nar == "$vh" ]] || { log "vote $va: $vo has $nar here, the proposal says $vh: no vote (tell infra: not reproducible)"; return 1; }
	[[ -n $vs ]] && cx='"independence":"same-host"'
	log "vote $va: $vo reproduced here, NarHash $nar ($([[ -n $vs ]] && print 'same-host: this host built or proposed it' || print 'a different builder'))"
	[[ $BUILDER_EVAL == 1 ]] || { log "dry run: BUILDER_EVAL=$BUILDER_EVAL: would claim ${vi%% *} ${vi#* } and complete it with commit $vc${cx:+ and $cx}"; return 0; }
	claim "${vi%% *}" "$vo" "${vi#* }" "$nar"
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
	{ nawk -F'\t' -v s="$BUILDER_SYSTEM" 'NR > 1 && $8 == s && $1 ~ /^[A-Za-z0-9._+-]+$/ {print $1; if ($1 == "openssl") print "openssl3"}' "$2"
	  [[ $BUILDER_EVAL != 0 ]] && nawk -F'\t' '$4 ~ /^[A-Za-z0-9._+-]+$/ {print $4}' "$BUILDER_STATE/eindex" 2> /dev/null; } | sort -u > "$o.q"
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
	eindex	# BUILDER_EVAL off: empty (plan then says NO-RECIPE, as before)
	curl -sS -m 60 -o "$rec" "$BUILDER_RECIPES" && rows "$rows" "$rec" || { log "listing unavailable"; return 1; }
	plan "$rows" "$rec" > "$BUILDER_STATE/plan"; log "plan: $(cut -d' ' -f2 "$BUILDER_STATE/plan" | sort | uniq -c | tr -s ' \n' ' ')"
	[[ -s $BUILDER_BEARER_FILE ]] || log "dry run: no $BUILDER_BEARER_FILE, never claiming"
	egrep ' (BUILD|EVAL) ' "$BUILDER_STATE/plan" > "$BUILDER_STATE/builds" || return 1
	# every job evaluates the same commit, fetched once
	flake=$(bounded 300 nix flake metadata --json "$BUILDER_FLAKE" 2> /dev/null | jq -r '.url // empty'); : ${flake:=$BUILDER_FLAKE}
	# each served out's origin commit (the commit that added its row); a row's job evaluates there first
	origins "$rec" > "$BUILDER_STATE/origins" || : > "$BUILDER_STATE/origins"
	[[ -d $BUILDER_STATE/eval ]] && find "$BUILDER_STATE/eval" -type f \( -name '*.miss' -o -mtime +7 \) -exec rm -f {} +	# a miss may have been a timeout
	log "row origins: $(cut -f2 "$BUILDER_STATE/origins" | sort -u | wc -l | tr -d ' ') commits for $(wc -l < "$BUILDER_STATE/origins" | tr -d ' ') served outs"
	log "up to $k jobs of $c cores ($b of $BUILDER_NCPU CPUs busy), $flake"
	C=$c; rm -f "$BUILDER_STATE"/job/*/worked "$BUILDER_STATE"/job/*/root-*; JOBMAX=$k	# roots of a killed tick's jobs
	[[ -d $BUILDER_STATE/pub ]] && find "$BUILDER_STATE/pub" \( -name 'slot.*' -o -name 'stage.*' -o -name 'xdg.*' \) -prune -exec rm -r {} +	# a killed tick's
	while read -r bp bd bo bv br bx; do
		# pnames filters by pname only: with two rows of one pname the server may hand out the other one
		[[ $(jq --arg p "$bp" --arg s "$BUILDER_SYSTEM" '[.rows[] | select(.pname == $p and .system == $s)] | length' "$rows") == 1 ]] ||
		    { log "decline $bp: more than one $BUILDER_SYSTEM row for it"; continue; }
		if [[ $bd == EVAL ]]; then ejob "$bp" "$bo" "$bv" "$br" "$bx" < /dev/null &
		else job "$bp" "$bo" "$bv" "${br:--}" < /dev/null & fi
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
eindex) mkdir -p "$BUILDER_STATE" && eindex; exit ;;
egress) mkdir -p "$BUILDER_STATE" && egress; exit ;;	# by hand: register now
vote) mkdir -p "$BUILDER_STATE" && vote "$2" "$3" "$4" "$5" "${6:-}"; exit ;;	# by hand (until infra lists eval proposals)
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
egl=0	# the last egress try: at start, then at the first tick boundary BUILDER_EGRESS_SECS later (a registration lasts 24 h)
while :; do (( $(printf '%(%s)T' now) - egl >= BUILDER_EGRESS_SECS )) && { egress; egl=$(printf '%(%s)T' now); }
	if tick; then sleep "$(pause busy)"; else sleep "$(pause)"; fi; done
