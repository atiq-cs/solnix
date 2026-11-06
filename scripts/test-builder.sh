#!/usr/bin/ksh93
# test-builder.sh -- solnix-builder on illumos (ksh93, nix, curl; jq from the store as the module has it). Run as a user
# nix-daemon accepts, e.g. on dixi: PATH=/usr/bin ksh93 scripts/test-builder.sh [builder.sh]   (last line: RESULT:)
# 1. the planner against fixed rows + a fixed recipes file (the real cache answers has_man/served), and the live listing;
# 2. the build-first gate with REAL nix: a fixture flake (deterministic, nondeterministic, mismatched, needs-a-local-dep,
#    unserved, duplicated, no attr) served from a file:// cache, against a fake queue (curl on PATH answers only
#    http://queue.invalid and logs every request). Only a job rebuilt here identical to the served NAR is claimed, by pname;
# 3. live: jq at the real solnix main through the real gate (no bearer).
# 4. parallel (qbuild4): the listing as ?system= + ?pname= queries, per-tick sizing, N jobs at once with their own state,
#    --option cores, the N=1 rebuild bound, the busy re-tick.
# 5. fleet1: a git fixture whose head moved past the served outs, with two batches from two commits on two branches: each row
#    is built at the commit that added it (one pin for the file fails one batch: negative control); rows[].commit first;
#    pname-with-dashes -> camelCase attr; a GC between fetch and --rebuild; a full disk is not memo'd.
# 6. fleet2: a job's candidates (head, then each out's origin commit, newest first): the first that builds from served inputs wins.
# 7. fleet3: first publish (BUILDER_PUBLISH) of a served row's unserved out with the host's key, against a fixture cache and a
#    submitter hook running the real cache-submit.py planner; the tier-1 states (proposed, 429), and the negative controls.
#    OLD_BUILDER=<a builder before fleet3 (26105b0^)>: it must never submit (else that control is SKIPped, not passed).
# 8. fleet4: eval-anchored jobs (BUILDER_EVAL, protocol v2 (B)) against a git fixture with main, 26.11, wave6 (fleet7: only
#    when BUILDER_EVAL_BRANCHES lists it) and an unpublished branch (wave5): an attr-only job takes the eval path (dry, then
#    a proposal followed at its commit after main moves, claimed with it); the identity rule (gate is not illumos-gate-proto,
#    pkg-config is not pkgconf); the negative controls (off-branch, --closure, an unpublished input, eval off, a mutant
#    without the identity rule, a mutant without wave6); the second vote.
#    MAIN_BUILDER=<origin/main's solnix-builder.sh, before fleet4>: it must never take an eval job (else SKIPped, not passed).
#    A version bump (fleet7): an older served version of the pname does not stop the eval path, a served row at the target does.
#    EV7_BUILDER=<c49a27f's solnix-builder.sh (any served row of the pname refused the eval)>: NO-RECIPE there (else SKIPped).
# 9. fleet5: a job listing several outputs of one drv (gcc's out and -lib, wave6's out and -debug): each unserved one first-
#    published as its own submission, deps first; one claim once every listed out is served, completed with the primary.
#    F5_BUILDER=<origin/main's solnix-builder.sh, before fleet5 (2c13182)>: it must loop on the gcc shape (else SKIPped).
# 10. fleet6: queue requests signed with sshsig (infra R7), a retry signed anew (R8), the egress registration (s3).
#    PRESIG_BUILDER=<a builder before fleet6>: in sshsig mode it must fail the signature check (else SKIPped, not passed).
# 11. fleet8 (root): a fixed build dir (W=/var/tmp/srcpkg-<buildKey>) left 0700 by another build uid fails pre-submit's --check:
#    the host's failure, never memo'd as the out's refusal (read from the check's nix log); the per-drv sweep right before the
#    --check removes it (also one left inside the same tick), never one whose owner runs a process; a genuine DIFFERS still memos.
#    F8_BUILDER=<origin/main's solnix-builder.sh, before fleet8 (e4aea94)>: it must memo the stale-W failure (else SKIPped).
#    WSWEEP=<solnix-wsweep.ksh> (default: this tree's).
# 12. fleet9: newest row first. A job's outs from two batches (b1 on main, b2 on a later commit): the newest row's out is first-
#    published when unserved (and this host may), voted on when served; an older row is voted on only when no newer out is
#    unserved (a non-publishing host declines: it waits), and a newer out refused here holds the job (`held: newest ...`); the
#    completion's commit is the candidate's own; deps first (A2: pcre2 -> zlib's newest row, whose job voted the older one);
#    the per-out lock; BUILDER_SKIP (seed rows); UTC log stamps; nap's deadline across a suspend.
#    F9_BUILDER=<origin/main's solnix-builder.sh, before fleet9 (773733a)>: it votes the older rows (else SKIPped, not passed).
S=${1:-$(dirname "$0")/../modules/config/community/solnix-builder.sh}
W=$(mktemp -d /tmp/bld.XXXXXX); trap 'find "$W" -depth -delete' EXIT
bad=0; ok() { print "ok: $1"; }; no() { print "FAIL: $1"; bad=1; }
# jq, as the module gives it (builder.nix BUILDER_PATH = pkgs.solnix.jq): a host's PATH has none. Override with JQ_BIN.
J=${JQ_BIN:-/nix/store/1fjqlkii7xmvhqrbryx59n7gbv46c3j5-jq-1.7.1/bin}
[[ -x $J/jq ]] || nix-store -r "${J%/bin}" >/dev/null 2>&1 || { print "FAIL: no jq at $J (nix-store -r ${J%/bin})"; exit 1; }
RC=$(whence -p curl) || { print "FAIL: no curl"; exit 1; }
PATH=$J:$PATH; export PATH
export BUILDER_STATE=$W/st BUILDER_BEARER_FILE=$W/bearer BUILDER_PATH=$PATH; mkdir -p "$W/st"
# a builder without the `rows`/`size` subcommands would fall into its SMF loop when asked for them: refuse it up front
for c in rows size; do grep -q "^$c) $c" "$S" || { print "FAIL: $S has no '$c' subcommand (an old builder)"; print "RESULT: FAIL"; exit 1; }; done
T=$'\t'; H="pname${T}version${T}url${T}sha256${T}buildsys${T}deps${T}flags${T}system${T}out${T}debug"
rec() { print -r -- "$1${T}$2${T}u${T}s${T}a${T}d${T}has_manpages=$3${T}x86_64-solaris${T}$4${T}"; }
{ print -r -- "$H"
  rec wget 1.24.5 y /nix/store/wd17vpnhxxj4p6jp2nq6qylrp6gm63dh-wget-1.24.5
  rec openssl 3.4.0 n /nix/store/arszvzha3cavkifl7qhhnqq67rqy8nhf-openssl-3.4.0
  rec jq 1.7.1 y /nix/store/n9aq9aa2bmg6jf7544r69p2zmipfqkaw-jq-1.7.1
  rec jq 1.7.1 y /nix/store/1fjqlkii7xmvhqrbryx59n7gbv46c3j5-jq-1.7.1
  rec zlib 1.3.2 y /nix/store/lkhrzj1xyvkg92z0d8j0din7lfqngk4s-zlib-1.3.2
  rec libc ac45d71fc2 y /nix/store/86qg1hqv9nk9s5s2g1bwdkp9fg7nhfyj-libc
  rec ghost 1 y /nix/store/00000000000000000000000000000000-ghost-1
} > "$W/r.tsv"
row() { print -n "{\"pname\":\"$1\",\"target\":\"$2\",\"current\":\"$2\",\"system\":\"${4:-x86_64-solaris}\",\"reasons\":\"$3\",\"attempts\":0}"; }
print "{\"count\":8,\"rows\":[$(row wget-1.24.5 1.24.5 manpage-missing),$(row openssl3 3.4.0 manpage-missing),$(row jq 1.7.1 outdated),$(row zlib 1.3.1 manpage-missing),$(row ninja 1.12.1 manpage-missing),$(row jq 1.7.1 outdated aarch64-solaris),$(row libc ac45d71fc2 manpage-missing),$(row ghost 1 manpage-missing)]}" > "$W/rows.json"
P=$(ksh93 "$S" plan "$W/rows.json" "$W/r.tsv"); print -r -- "$P" | sed 's/^/   /'
want() { print -r -- "$P" | egrep -q "$2" && ok "$1" || no "$1"; }
want "wget-1.24.5 (pname carries the version): served out already ships man1 -> MET" '^wget-1\.24\.5 MET /nix/store/wd17vpnh'
want "openssl3 -> openssl row, has_manpages=n -> NO-MAN" '^openssl3 NO-MAN /nix/store/arszvzha'
want "jq outdated, two served rows (one per solnix commit) -> BUILD <both outs> <version> - (no row commit)" '^jq BUILD /nix/store/n9aq9aa2[^ ]*,/nix/store/1fjqlkii[^ ]* 1\.7\.1 -$'
want "zlib 1.3.1 (only 1.3.2 served) -> NO-RECIPE" '^zlib NO-RECIPE zlib 1\.3\.1'
want "ninja (no row) -> NO-RECIPE" '^ninja NO-RECIPE'
want "aarch64 row on x86_64 -> OTHER-SYSTEM" '^jq OTHER-SYSTEM aarch64-solaris'
want "libc manpage-missing, served without share/man -> MAN-GAP (a rebuild of that out cannot add pages)" '^libc MAN-GAP /nix/store/86qg1hqv'
want "ghost manpage-missing, out not served -> BUILD (the gate decides)" '^ghost BUILD /nix/store/0{32}-ghost-1 1 -$'
[[ $(print -r -- "$P" | wc -l | tr -d ' ') == 8 ]] && ok "one decision per row" || no "rows: $(print -r -- "$P" | wc -l)"
# live: the real listing (this system's window + every served recipe pname, cache-api v44) + the served recipes.tsv must
# plan without error, every row decided
curl -sS -m 60 -o "$W/live.tsv" https://cache.solnix.io/registry/recipes.tsv && ksh93 "$S" rows "$W/live.json" "$W/live.tsv" || no "live rows"
L=$(ksh93 "$S" plan "$W/live.json" "$W/live.tsv"); n=$(jq '.rows|length' "$W/live.json")
(( n > 0 )) && [[ $(print -r -- "$L" | egrep -c ' (BUILD|MET|MAN-GAP|NO-MAN|NO-RECIPE|OTHER-SYSTEM|SKIP) ') == "$n" ]] && ok "live listing: $n rows, all decided: $(print -r -- "$L" | cut -d' ' -f2 | sort | uniq -c | tr -s ' \n' ' ')" || no "live: $n: $L"
print -r -- "$L" > "${LIVE_PLAN_OUT:-/dev/null}"

# --- the gate, with real nix. The fixture flake: one derivation per case; `needs` depends on a derivation nobody has.
mkdir -p "$W/flake" "$W/fk"; cat > "$W/flake/flake.nix" <<EOF
{ outputs = { self }: let
    mk = name: script: derivation { inherit name; system = "x86_64-solaris"; builder = "/bin/sh"; args = [ "-c" script ]; };
  in { packages.x86_64-solaris = {
    good = mk "qb-good-1" "echo good > \$out";
    flaky = mk "qb-flaky-1" "echo \$\$ > \$out";
    mism = mk "qb-mism-1" "echo mism > \$out";
    needs = mk "qb-needs-1" "cat \${mk "qb-dep-${W##*/}" "echo dep > \$out"} > \$out";
    unserved = mk "qb-unserved-${W##*/}" "echo unserved > \$out";
    dup = mk "qb-dup-1" "echo dup > \$out";
    # an input that is a FIXED-OUTPUT derivation nobody has (a source tarball): it may build here, the leaf is reproducible
    fodin = mk "qb-fodin-1" "read x < \${derivation { name = "qb-fod-${W##*/}"; system = "x86_64-solaris"; builder = "/bin/sh";
      args = [ "-c" "printf fod > \$out" ]; outputHashMode = "flat"; outputHashAlgo = "sha256";
      outputHash = "40c8c5469f953906025db90f6621bd41d33944e585aa4f39a487ebe7a5c69f5f"; }}; echo \$x > \$out";
    # parallel: four 4-second builds, and one whose out is the build's NIX_BUILD_CORES (served as built with cores = 3)
    p1 = mk "qb-par1-1" "sleep 4; echo p1 > \$out"; p2 = mk "qb-par2-1" "sleep 4; echo p2 > \$out";
    p3 = mk "qb-par3-1" "sleep 4; echo p3 > \$out"; p4 = mk "qb-par4-1" "sleep 4; echo p4 > \$out";
    cores3 = mk "qb-cores-1" "echo \$NIX_BUILD_CORES > \$out";
  }; }; }
EOF
F=path:$W/flake; o() { jq -r --arg a "$1" '.[$a]' "$W/outs.json"; }
nix eval --json "$F#packages.x86_64-solaris" --apply 'builtins.mapAttrs (n: d: d.outPath)' > "$W/outs.json" 2>"$W/eval.err" &&
  nix build --no-link "$F#packages.x86_64-solaris."{good,flaky,mism,dup,p1,p2,p3,p4} > "$W/fixture.log" 2>&1 &&
  nix build --no-link --option cores 3 "$F#packages.x86_64-solaris.cores3" >> "$W/fixture.log" 2>&1 && [[ $(<$(o cores3)) == 3 ]] &&
  nix copy --to "file://$W/cache" $(o good) $(o flaky) $(o mism) $(o dup) $(o p1) $(o p2) $(o p3) $(o p4) $(o cores3) >> "$W/fixture.log" 2>&1 ||
  { no "fixture: $(tail -3 "$W/eval.err" "$W/fixture.log")"; print "RESULT: FAIL"; exit 1; }
hp() { h=${1#/nix/store/}; print -r -- "$W/cache/${h%%-*}.narinfo"; }
GH=$(nawk '/^NarHash:/ {print $2}' "$(hp $(o good))")
# mism: the cache serves another NarHash than the local copy has (the qbuild2 hazard: a copied-in local out is not the served one)
sed "s|^NarHash: .*|NarHash: sha256:0000000000000000000000000000000000000000000000000000|" "$(hp $(o mism))" > "$W/x" && mv "$W/x" "$(hp $(o mism))"
# needs: served (a narinfo), but building it here first needs qb-dep, which is neither valid nor served
printf 'StorePath: %s\nNarHash: %s\n' "$(o needs)" "$GH" > "$(hp $(o needs))"
# fodin: served and valid here, but its only input, a fixed-output drv with a per-run name, is not. The out is what a build
# gives (the file "fod\n"), imported from a hand-made NAR, so the gate's dry run lists exactly that FOD to build.
print fod > "$W/fod.txt"; chmod 444 "$W/fod.txt"; nix-store --dump "$W/fod.txt" > "$W/cache/fodin.nar"
fh=$(nix-hash --type sha256 --flat --base32 "$W/cache/fodin.nar"); fs=$(wc -c < "$W/cache/fodin.nar" | tr -d ' ')
printf 'StorePath: %s\nURL: fodin.nar\nCompression: none\nFileHash: sha256:%s\nFileSize: %s\nNarHash: sha256:%s\nNarSize: %s\nReferences: \n' \
  "$(o fodin)" "$fh" "$fs" "$fh" "$fs" > "$(hp $(o fodin))"
nix copy --no-check-sigs --from "file://$W/cache" $(o fodin) >> "$W/fixture.log" 2>&1 && [[ -e $(o fodin) ]] ||
  { no "fodin fixture: $(tail -3 "$W/fixture.log")"; print "RESULT: FAIL"; exit 1; }
{ print -r -- "$H"; rec good 1 y /nix/store/11111111111111111111111111111111-qb-good-1	# a stale row: the gate builds the evaluated out
  for a in good flaky mism needs unserved dup fodin p1 p2 p3 p4 cores3; do rec $a 1 y "$(o $a)"; done; rec noattr 1 y "$(o good)"; } > "$W/g.tsv"
print "{\"rows\":[$(row flaky 1 outdated),$(row good 1 outdated),$(row mism 1 outdated),$(row needs 1 outdated),$(row unserved 1 outdated),$(row noattr 1 outdated),$(row dup 1 outdated),$(row dup 1 outdated),$(row fodin 1 outdated)]}" > "$W/g.json"
# the fake queue: rows from $FKROWS, as cache-api v44 serves them: /rows?system=<s> is the window ($FKWIN, else $FKROWS),
# &pname=a,b narrows $FKROWS to those pnames, and a bare /rows is refused (curl -f: rc 22). claim grants pnames[0] (no
# pnames: $FKNEXT, as the server hands out its next job), FKEMPTY=1: no job (someone else has it); FKIDS=1: an id and token
# per pname; FKSLOW=<s>: the claim reply is written, then curl takes <s> more (two jobs sharing one reply file collide).
# Every request is logged, body included; everything else goes to the real curl.
cat > "$W/fk/curl" <<'FK'
#!/bin/sh
q=; for a; do case $a in http://queue.invalid*) q=1;; esac; done; [ -n "$q" ] || exec "$FKREAL" "$@"
o=; u=; d=; w=; while [ $# -gt 0 ]; do case $1 in -o) o=$2; shift;; --data-binary) d=$2; shift;; -w) w=1; shift;; -m|-X|-H) shift;; -*) ;; *) u=$1;; esac; shift; done
# FKREQ=<dir>: each request kept as <dir>/<n>/{url,hdr,body} (hdr: the -H @- lines; an egress POST's body is its stdin)
kp() { [ -n "$FKREQ" ] || { cat > /dev/null; return; }; n=$(( $(cat "$FKREQ/n" 2> /dev/null || echo 0) + 1 )); echo $n > "$FKREQ/n"
  mkdir -p "$FKREQ/$n"; echo "$u" > "$FKREQ/$n/url"; if [ "$1" = body ]; then cat > "$FKREQ/$n/body"; else cat > "$FKREQ/$n/hdr"; printf %s "$d" > "$FKREQ/$n/body"; fi; }
case $u in */rows*) ;; */builder/egress) kp body;; *) kp;; esac; echo "$u $d" >> "$FKLOG"
qs() { echo "$u" | sed -n "s/.*[?\&]$1=\([^&]*\).*/\1/p" | sed 's/%2B/+/g'; }
case $u in
*/rows) exit 22;;
*/rows\?*pname=*) jq --arg s "$(qs system)" --arg p ",$(qs pname)," '{rows: [.rows[] | select(.system == $s and (.pname as $n | $p | contains("," + $n + ",")))]}' "$FKROWS" > "$o";;
*/rows\?system=*) jq --arg s "$(qs system)" '{rows: [.rows[] | select(.system == $s)]}' "${FKWIN:-$FKROWS}" > "$o";;
*/claim) p=$(echo "$d" | sed -n 's/.*"pnames":\["\([^"]*\)".*/\1/p'); [ -n "$p" ] || p=$FKNEXT; [ -z "$FKGIVE" ] || p=$FKGIVE
  i=42 t=00000000-0000-4000-8000-000000000042; [ -z "$FKIDS" ] || { i=$(printf %s "$p" | cksum | cut -d' ' -f1); t=tok-$p; }
  if [ -n "$FKEMPTY" ]; then echo '{"jobs":[]}'; else echo '{"jobs":[{"id":'$i',"claim_token":"'$t'","pname":"'$p'","current_version":"1","target_version":"1"}]}'; fi > "$o"
  [ -z "$FKSLOW" ] || sleep "$FKSLOW";;
*/complete) echo '{"id":42,"attempt":1,"state":"done","publication_verified":false,"attestation_recorded":false}' > "$o";;
# egress: 400 with "seen" unless ip is $FKSEEN (198.51.100.7); FKE500=1: a 500
*/builder/egress) i=$(jq -r .ip "$FKREQ/$n/body"); sn=${FKSEEN:-198.51.100.7}
  if [ -n "$FKE500" ]; then echo '{"error":"x"}' > "$o"; c=500; elif [ "$i" != "$sn" ]; then echo '{"error":"ip must be the address this request comes from","seen":"'$sn'"}' > "$o"; c=400
  else echo '{"status":"registered","keyid":"qbhost","ip":"'$sn'","addresses":1,"expires_in":86400}' > "$o"; fi;;
# FKFAIL=<file>: while it exists, the next heartbeat answers 503 (and removes it)
*) echo '{"claim_expires_at":"x"}' > "$o"; case $u in */heartbeat) [ -z "$FKFAIL" ] || [ ! -e "$FKFAIL" ] || { rm -f "$FKFAIL"; c=503; };; esac;;
esac; [ -z "$w" ] || printf %s "${c:-200}"
FK
chmod +x "$W/fk/curl"
tk() { env BUILDER_PATH="$W/fk:$PATH" FKREAL=$RC FKLOG=$W/fk/log FKROWS=${FKROWS:-$W/g.json} FKNEXT=flaky BUILDER_API=http://queue.invalid/q \
  BUILDER_RECIPES=file://$W/g.tsv BUILDER_CACHE=file://$W/cache BUILDER_FLAKE=$F BUILDER_LOAD_MAX=1000 "$@" ksh93 "$S" once 2>&1; }
has() { print -r -- "$out" | egrep -q -- "$1"; }
claims() { grep -c '/claim ' "$W/fk/log" 2>/dev/null; }
# NEG dry run: no bearer -> the gate runs up to the fetch, nothing is rebuilt, nothing claimed
rm -f "$W/bearer"; : > "$W/fk/log"; out=$(tk BUILDER_STATE=$W/st0); print -r -- "$out" | sed 's/^/   0 /'
has 'dry run: would fetch .*qb-good-1 and rebuild' && ! has 'rebuilt |claimed |claim [a-z]+ ->' && [[ $(claims) == 0 && ! -d $W/st0/tried ]] &&
  ok "NEG no bearer: gate runs, would rebuild good, no rebuild, no claim" || no "no-bearer tick"
print x > "$W/bearer"; : > "$W/fk/log"; out=$(tk); print -r -- "$out" | sed 's/^/   1 /'; c=$(<"$W/fk/log"); print -r -- "$c" | sed 's/^/   q /'
nc() { print -r -- "$c" | grep '/claim ' | grep -c "\"pnames\":\[\"$1\"\]"; }
[[ $(claims) -ge 1 && $(print -r -- "$c" | grep '/claim ' | grep -vc '"pnames":\["') == 0 ]] && ok "every claim carries pnames ($(claims) claims)" || no "a claim without pnames"
has 'decline flaky: nix build --rebuild .* failed' && [[ $(nc flaky) == 0 ]] && ! print -r -- "$c" | grep -q '"pnames":\[\]' &&
  ! print -r -- "$c" | grep '/claim ' | grep -vEq '"pnames":\["(good|fodin)"\]' && ok "NEG a failed (nondeterministic) rebuild: declined, no claim" || no "flaky was claimed or not rebuilt"
has 'decline mism: the local .*qb-mism-1 has sha256:.*, cache.solnix.io serves sha256:0000' && [[ $(nc mism) == 0 ]] && ok "NEG local NarHash != served NarHash: declined before any build, no claim" || no "mism"
has 'decline needs: the dry run would build 1 non-fixed-output derivations' && [[ $(nc needs) == 0 ]] && ok "NEG the dry run lists a local build of a non-FOD input: declined, no claim" || no "needs"
has 'fodin: rebuilt .* identical' && [[ $(nc fodin) == 1 ]] && ok "a leaf whose only local input is a fixed-output derivation (a tarball): built and claimed" || no "fodin: $(print -r -- "$out" | grep fodin | tail -2)"
has 'decline unserved: .* is not served' && [[ $(nc unserved) == 0 ]] && ok "NEG out not served: declined (a first build needs the submit key), no claim" || no "unserved"
has 'decline noattr: no packages.x86_64-solaris attr' && [[ $(nc noattr) == 0 ]] && ok "NEG no attr evaluates to the out: declined" || no "noattr"
has 'decline dup: more than one' && [[ $(nc dup) == 0 ]] && ok "NEG two rows of one pname: declined (pnames cannot choose)" || no "dup"
has 'good: rebuilt .*qb-good-1 here, identical' && [[ $(nc good) == 1 ]] && print -r -- "$c" | grep -q '/42/heartbeat' &&
  print -r -- "$c" | grep '/42/complete' | grep -q "\"claim_token\":\"00000000-0000-4000-8000-000000000042\",\"status\":\"done\",\"version\":\"1\",\"nar_hash\":\"$GH\",\"store_path\":\"$(o good)\"" &&
  ok "good: rebuilt identical, then claimed pnames=[good] max 1, heartbeat, complete done with the served NarHash" || no "good"
: > "$W/fk/log"; out=$(tk FKEMPTY=1); print -r -- "$out" | sed 's/^/   2 /'; c=$(<"$W/fk/log")
has 'good: rebuilt and matched on an earlier tick' && has 'claim good -> no job' && ! print -r -- "$c" | grep -q 'complete' &&
  has 'decline flaky: nix build --rebuild' && ! has 'identical to the served' && ok "tick 2: no rebuild repeated (memo), empty claim -> nothing completed" || no "tick 2"
# a job the server should never hand out (not the pname asked for) is reported failed with the reason, never done
print "{\"rows\":[$(row good 1 outdated)]}" > "$W/g1.json"; : > "$W/fk/log"; out=$(tk FKROWS=$W/g1.json FKGIVE=flaky); c=$(<"$W/fk/log")
print -r -- "$c" | grep '/42/complete' | grep -q '"status":"failed","error":"[^"]*claimed pnames=\[good\] 1 and was given flaky 1"' &&
  ! print -r -- "$c" | grep -q '"status":"done"' && ok "a job other than the one asked for: completed failed with the reason, never done" || no "wrong job: $out"
# a hung `nix store ls` (seen on dixi 2026-10-29: > 8 min) must not wedge the plan: has_man gives up after 120 s
mkdir -p "$W/hang"; printf '#!/bin/sh\ncase $1 in store) exec sleep 100000;; esac\nexec %s "$@"\n' "$(whence -p nix)" > "$W/hang/nix"; chmod +x "$W/hang/nix"
print "{\"rows\":[$(row wget 1.24.5 manpage-missing)]}" > "$W/h.json"; SECONDS=0
env BUILDER_PATH="$W/hang:$PATH" ksh93 "$S" plan "$W/h.json" "$W/r.tsv" > "$W/h.out" 2>&1 & hp=$!
{ sleep 400; kill $hp; } > /dev/null 2>&1 & hw=$!; wait $hp; kill $hw 2> /dev/null; t=${SECONDS%.*}
grep -q '^wget MAN-GAP' "$W/h.out" && (( t < 300 )) && ok "a hung nix store ls: plan still decides in ${t}s ($(<"$W/h.out"))" || no "hung nix store ls: ${t}s: $(<"$W/h.out")"
out=$(env BUILDER_LOAD_MAX=0 ksh93 "$S" once 2>&1); print -r -- "$out" | grep -q 'not idle' && ok "NEG busy (load >= 0): does nothing" || no "busy: $out"
# live: jq through the real gate: the real served recipes (two jq rows), solnix main (BUILDER_FLAKE's default) and
# cache.solnix.io, bearer present so the gate goes as far as it can (claims go to the fake queue).
print x > "$W/bearer"; print "{\"rows\":[$(row jq 1.7.1 outdated)]}" > "$W/l.json"; : > "$W/fk/log"
out=$(env BUILDER_PATH="$W/fk:$PATH" FKREAL=$RC FKLOG=$W/fk/log FKROWS=$W/l.json BUILDER_API=http://queue.invalid/q BUILDER_STATE=$W/stl BUILDER_LOAD_MAX=1000 ksh93 "$S" once 2>&1)
print -r -- "$out" | sed 's/^/   L /'
if has 'decline jq: the dry run would build [0-9]+ (non-fixed-output )?derivations'; then [[ $(claims) == 0 ]] && ok "live jq: the real dry run needs local builds of its inputs -> declined, no claim" || no "live jq claimed"
elif has 'decline jq: nix build --rebuild .* failed'; then [[ $(claims) == 0 ]] && ok "live jq: served, but its rebuild can't run here (an input such as gcc is not substitutable yet) -> declined, no claim" || no "live jq claimed after a failed rebuild"
elif has 'decline jq: no packages.x86_64-solaris attr of .* evaluates to'; then [[ $(claims) == 0 ]] && ok "live jq: main has moved past every served jq out (a rebuild wave not yet served) -> declined, no claim" || no "live jq claimed with no attr"
elif has 'decline jq: .* is not served'; then [[ $(claims) == 0 ]] && ok "live jq: main's jq out is not served yet (a wave not yet published) -> declined, no claim" || no "live jq claimed an unserved out"
elif has 'jq: rebuilt .* identical'; then [[ $(claims) == 1 ]] && ok "live jq: rebuilt identical to the served NAR -> one claim (a solnix host builds now)" || no "live jq"
else no "live jq"; fi
# plan order = claim order: priority ascending, oldest first (the public listing is priority DESC)
print '{"rows":[{"pname":"zz","target":"1","current":"1","system":"x86_64-solaris","reasons":"user-request","priority":100,"age_secs":5},{"pname":"aa","target":"1","current":"1","system":"x86_64-solaris","reasons":"outdated","priority":0,"age_secs":9},{"pname":"mm","target":"1","current":"1","system":"x86_64-solaris","reasons":"outdated","priority":0,"age_secs":99}]}' > "$W/o.json"
o=$(ksh93 "$S" plan "$W/o.json" "$W/r.tsv" 2>/dev/null < /dev/null | cut -d' ' -f1 | tr '\n' ' ')
[[ $o == "mm aa zz " ]] && ok "plan order: priority asc, oldest first ($o)" || no "plan order: $o"
# the pause between ticks: random, inside 10..30 min, so a fleet doesn't poll solnix.io in step (a script without
# `pause` falls into its loop: refuse it up front)
grep -q '^pause) pause' "$S" || no "no pause: the tick interval is fixed"
grep -q '^pause) pause' "$S" && { lo=99999; hi=0; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do p=$(ksh93 "$S" pause < /dev/null); (( p < lo )) && lo=$p; (( p > hi )) && hi=$p; done
(( lo >= 600 && hi <= 1800 && hi > lo )) && ok "pause between ticks random in [600,1800] (saw $lo..$hi)" || no "pause: $lo..$hi"; }
# --- 4. parallel (qbuild4). The listing: ?system= window + ?pname= for every served recipe pname (100 a query).
print "{\"rows\":[$(row zzz 9 nixpkgs),$(row good 1 outdated aarch64-solaris)]}" > "$W/win.json"
print "{\"rows\":[$(row zzz 9 nixpkgs),$(row good 1 outdated),$(row openssl3 3.4.0 manpage-missing),$(row good 1 outdated aarch64-solaris)]}" > "$W/all.json"
{ cat "$W/g.tsv"; tail -n +2 "$W/r.tsv"; i=0; while (( (i += 1) <= 230 )); do rec x$i 1 y /nix/store/x; done; } > "$W/big.tsv"
: > "$W/fk/log"; env BUILDER_PATH="$W/fk:$PATH" FKREAL=$RC FKLOG=$W/fk/log FKROWS=$W/all.json FKWIN=$W/win.json BUILDER_API=http://queue.invalid/q \
  ksh93 "$S" rows "$W/m.json" "$W/big.tsv" > "$W/m.err" 2>&1; c=$(<"$W/fk/log")
[[ $(jq -c '[.rows[] | .pname + "@" + .system] | sort' "$W/m.json") == '["good@x86_64-solaris","openssl3@x86_64-solaris","zzz@x86_64-solaris"]' ]] &&
  print -r -- "$c" | grep -q '^http://queue.invalid/q/rows?system=x86_64-solaris $' && [[ $(print -r -- "$c" | grep -c 'rows?system=x86_64-solaris&pname=') == 3 ]] &&
  print -r -- "$c" | grep 'pname=' | grep -q '[=,]openssl3[,& ]' && print -r -- "$c" | grep 'pname=' | grep -q '[=,]x230[,& ]' &&
  ! print -r -- "$c" | grep -q '/rows ' && ok "rows: ?system= window + ?pname= (3 queries for 250 pnames, openssl3 too): good past the window seen once, no other system" ||
  no "rows: $(jq -c . "$W/m.json" 2>&1) $(<"$W/m.err") $c"
# size: jobs = floor((CPUs - busy) / cores), capped by BUILDER_JOBS; a numeric loadMax keeps the old gate (0 or >= 1 job)
sz() { env BUILDER_NCPU=$1 BUILDER_BUSY=$2 BUILDER_JOBS=$3 BUILDER_CORES=$4 BUILDER_LOAD_MAX=$5 ksh93 "$S" size; }
z="$(sz 32 0 auto 4 auto)|$(sz 32 10 auto 4 auto)|$(sz 32 30 auto 4 auto)|$(sz 32 0 4 0 auto)|$(sz 20 10 4 4 auto)|$(sz 32 1.5 1 0 2)|$(sz 32 2.5 1 0 2)|$(sz 32 0 1 0 2)"
[[ $z == "8 4 0|5 4 10|0 4 30|4 8 0|2 4 10|1 32 1.5|0 32 2.5|1 32 0" ]] && ok "size: dedicated 8 jobs idle, 5 with 10 CPUs busy, 0 with 30; lixi 2 of 4 with 10 busy; loadMax 2 gate as before" || no "size: $z"
# opportunistic: 2/3 (BUILDER_SHARE 66) of the CPUs other work leaves idle; it stops when the user is busy. A builder that ignores
# BUILDER_SHARE gives 10/6/1 here and fails.
so() { env BUILDER_NCPU=20 BUILDER_BUSY=$1 BUILDER_JOBS=auto BUILDER_CORES=2 BUILDER_LOAD_MAX=auto BUILDER_SHARE=66 ksh93 "$S" size; }
z="$(so 0)|$(so 8)|$(so 18)"
[[ $z == "6 2 0|3 2 8|0 2 18" ]] && ok "size: opportunistic lixi 6 jobs idle, 3 with 8 CPUs busy, 0 with 18 (2/3 of the idle CPUs)" || no "size opportunistic: $z"
z=$(ksh93 "$S" size); [[ $z == +([0-9])\ +([0-9])\ +([0-9.]) ]] && ok "size from a real vmstat sample: $z" || no "size (vmstat): $z"
# N=4: four 4 s builds at once, each its own state dir, its own claim (FKIDS: an id and token per pname), the claim reply
# slow (FKSLOW) so jobs sharing one reply file would read each other's; cores3's out is the build's NIX_BUILD_CORES (3)
print "{\"rows\":[$(row p1 1 outdated),$(row p2 1 outdated),$(row p3 1 outdated),$(row p4 1 outdated),$(row cores3 1 outdated)]}" > "$W/p.json"
win() { typeset a b; a=$(print -r -- "$out" | grep " builder: $1: rebuilding " | cut -d' ' -f1); b=$(print -r -- "$out" | grep " builder: $1: rebuilt " | cut -d' ' -f1)
  [[ -n $a && -n $b ]] && print $(printf '%(%s)T' "$a") $(printf '%(%s)T' "$b"); }
ovl() { typeset hs=0 le=9999999999 x a b; for x in p1 p2 p3 p4; do set -- $(win $x); [[ -n $2 ]] || return 2; (( $1 > hs )) && hs=$1; (( $2 < le )) && le=$2; done; (( hs < le )); }
pt() { : > "$W/fk/log"; SECONDS=0; out=$(tk FKROWS=$W/p.json FKIDS=1 FKSLOW=2 BUILDER_LOAD_MAX=auto BUILDER_BUSY=0 BUILDER_NCPU=12 BUILDER_CORES=3 "$@"); prc=$?; pd=${SECONDS%.*}; c=$(<"$W/fk/log"); }
pt BUILDER_JOBS=4 BUILDER_STATE=$W/stp; print -r -- "$out" | sed 's/^/   P /'
has 'up to 4 jobs of 3 cores' && ovl && ok "N=4: p1..p4 rebuilt at the same time (every build window overlaps the others; tick ${pd}s)" || no "N=4 overlap: $(for x in p1 p2 p3 p4; do print -n "$x=$(win $x) "; done)"
pc=0; for x in p1 p2 p3 p4 cores3; do id=$(printf %s "$x" | cksum | cut -d' ' -f1); nh=$(nawk '/^NarHash:/ {print $2}' "$(hp $(o $x))")
  [[ $(print -r -- "$c" | grep -c "/$id/complete .*\"claim_token\":\"tok-$x\",\"status\":\"done\",\"version\":\"1\",\"nar_hash\":\"$nh\",\"store_path\":\"$(o $x)\"") == 1 ]] && pc=$((pc + 1)); done
(( pc == 5 )) && ! print -r -- "$c" | grep -q '"status":"failed"' && [[ -s $W/stp/job/p3/claim.json && $(jq -r '.jobs[0].pname' "$W/stp/job/p3/claim.json") == p3 ]] &&
  ok "N=4: five jobs, five claims, each completed done with its own id, token, out and NarHash (no shared state)" || no "N=4 claims: $pc of 5 right: $(print -r -- "$c" | grep -E 'complete|claim ')"
has 'cores3: rebuilt .* identical' && ok "--option cores reaches the build: cores3 (out = NIX_BUILD_CORES = 3) rebuilt identical" || no "cores3: $(print -r -- "$out" | grep cores3)"
(( prc == 0 )) && ok "a tick that rebuilt and claimed returns 0 (the loop re-ticks soon)" || no "N=4 tick rc $prc"
# N=1, the same rows: one at a time, exactly as before qbuild4 (the overlap check can fail)
pt BUILDER_JOBS=1 BUILDER_STATE=$W/stp1; ovl; r=$?
has 'up to 1 jobs of 3 cores' && (( r == 1 && pd >= 16 )) && [[ $(print -r -- "$out" | grep -c ': rebuilt .* identical') == 5 ]] &&
  ok "N=1: the same five rebuilt one after another (no overlap, ${pd}s), all claimed" || no "N=1 serial: r=$r ${pd}s"
# N=1 (JOBMAX=1): a job's own rebuild bound must still fire. nice that hangs 30 s, BUILDER_BUILD_SECS=3
mkdir -p "$W/nice"; printf '#!/bin/sh\nexec sleep 30\n' > "$W/nice/nice"; chmod +x "$W/nice/nice"; print "{\"rows\":[$(row good 1 outdated)]}" > "$W/g1.json"
SECONDS=0; out=$(env BUILDER_PATH="$W/nice:$W/fk:$PATH" FKREAL=$RC FKLOG=$W/fk/log FKROWS=$W/g1.json BUILDER_API=http://queue.invalid/q BUILDER_RECIPES=file://$W/g.tsv \
  BUILDER_CACHE=file://$W/cache BUILDER_FLAKE=$F BUILDER_LOAD_MAX=1000 BUILDER_STATE=$W/stn BUILDER_BUILD_SECS=3 ksh93 "$S" once 2>&1); t=${SECONDS%.*}
has 'decline good: nix build --rebuild .* failed rc=' && (( t < 25 )) && ok "N=1: a hung rebuild is killed at BUILDER_BUILD_SECS (${t}s)" || no "N=1 bound: ${t}s $out"
# a tick with nothing to build returns non-zero: the loop backs off to the long pause
print "{\"rows\":[$(row ninja 1.12.1 outdated)]}" > "$W/n.json"; tk FKROWS=$W/n.json BUILDER_STATE=$W/stz > /dev/null; r=$?
lo=99999; hi=0; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do p=$(BUILDER_BUSY_TICK_MIN=60 BUILDER_BUSY_TICK_MAX=300 ksh93 "$S" pause busy); (( p < lo )) && lo=$p; (( p > hi )) && hi=$p; done
(( r != 0 && lo >= 60 && hi <= 300 && hi > lo )) && [[ $(ksh93 "$S" pause busy) == +([0-9]) ]] && (( $(ksh93 "$S" pause busy) >= 600 )) &&
  ok "nothing to build: tick rc $r (long pause); busy pause random in the busy range ($lo..$hi), defaults to the long range" || no "pause: rc $r busy $lo..$hi"
# --- 5. fleet1: each row is evaluated at the commit that ADDED it (head has moved on), GC-safe rebuilds. A git fixture shaped like
# the real served file (2026-11-02: T1 from 540d65c on main, W0-W2 from b080459 on wave5, where gcc moved and T1's outs differ):
#   main: A adds pin1 (out A1), gcd, pin-camel; then B moves pin1 to B1 (head; never served).
#   side (from A): W moves "gcc", so pin1 there is W1 != A1; it adds wrow (out WW). The served file = side's: A's rows + wrow.
#   pin1 must build at A, wrow at W: one pin for the whole file (A or W) gets one of the two wrong, and head (B) has neither.
R=$W/repo; mkdir -p "$R/docs/registry"; gt() { git -C "$R" -c user.name=t -c user.email=t@t "$@" > /dev/null 2>&1; }
pf() { print -r -- "{ outputs = { self }: let mk = name: script: derivation { inherit name; system = \"x86_64-solaris\"; builder = \"/bin/sh\"; args = [ \"-c\" script ]; };
  in { packages.x86_64-solaris = { pin1 = mk \"qb-pin1-$1-${W##*/}\" \"echo $1 > \$out\"; gcd = mk \"qb-gcd-${W##*/}\" \"echo gcd > \$out\";
    pinCamel = mk \"qb-camel-${W##*/}\" \"echo c > \$out\"; ${2:-} }; }; }" > "$R/flake.nix"; gt add -A; }
po() { nix eval --raw "git+file://$R?rev=$(git -C "$R" rev-parse HEAD)#packages.x86_64-solaris.$1.outPath" 2> /dev/null; }
gt init -b main; pf A; gt commit -m A; A1=$(po pin1); AG=$(po gcd); AC=$(po pinCamel)
{ print -r -- "$H"; rec pin1 1 y "$A1"; rec gcd 1 y "$AG"; rec pin-camel 1 y "$AC"; } > "$R/docs/registry/recipes.tsv"; gt add -A; gt commit -m rowsA; RA=$(git -C "$R" rev-parse HEAD)
gt checkout -b side; pf W "wrow = mk \"qb-wrow-W-${W##*/}\" \"echo w > \$out\";"; gt commit -m W; W1=$(po pin1); WW=$(po wrow)
rec wrow 1 y "$WW" >> "$R/docs/registry/recipes.tsv"; gt add -A; gt commit -m rowsW; RW=$(git -C "$R" rev-parse HEAD)
gt checkout main; pf B; gt commit -m B; B1=$(po pin1); sed "s|$A1|$B1|" "$R/docs/registry/recipes.tsv" > "$W/x" && mv "$W/x" "$R/docs/registry/recipes.tsv"; gt add -A; gt commit -m rowsB
git -C "$R" show "$RA:docs/registry/recipes.tsv" > "$W/served.tsv"; git -C "$R" show "$RW:docs/registry/recipes.tsv" > "$W/servedW.tsv"
nix build --no-link "git+file://$R?rev=$RA#packages.x86_64-solaris."{pin1,gcd,pinCamel} "git+file://$R?rev=$RW#packages.x86_64-solaris.wrow" >> "$W/fixture.log" 2>&1 &&
  nix copy --to "file://$W/cache" "$A1" "$AG" "$AC" "$WW" >> "$W/fixture.log" 2>&1 &&
  [[ -n $A1 && -n $B1 && -n $W1 && -n $WW && $A1 != "$B1" && $A1 != "$W1" ]] || no "fixture: A=$A1 B=$B1 W=$W1 WW=$WW $(tail -2 "$W/fixture.log")"
print "{\"rows\":[$(row pin1 1 outdated),$(row gcd 1 outdated),$(row pin-camel 1 outdated)]}" > "$W/pin.json"
# nice, as the builder calls it before `nix build --rebuild`: for gcd it first deletes gcd's out AND its drv, as a min-free GC on a
# busy host would (nix-store --delete counts paths outside its set as alive, and keep-outputs keeps an out alive through its drv,
# so deleting the out alone is always refused); NOSPACE=1: the rebuild fails as a full disk does.
mkdir -p "$W/gcn"; printf '#!/bin/sh\ncase " $* " in *qb-gcd-*) nix-store --delete "$GCDEL" "$(nix-store -q --deriver "$GCDEL")" >> "$GCLOG" 2>&1;; esac\n[ -z "$NOSPACE" ] || { echo "error: writing to file: No space left on device" >&2; exit 1; }\n[ -z "$STALEW" ] || { echo "> rm: cannot remove '"'"'/var/tmp/cargo-597fba60e295d4fa'"'"': Permission denied" >&2; exit 1; }\nexec /usr/bin/nice "$@"\n' > "$W/gcn/nice"; chmod +x "$W/gcn/nice"
pk() { : > "$W/fk/log"; : > "$W/gc.log"; out=$(env BUILDER_PATH="$W/gcn:$W/fk:$PATH" FKREAL=$RC FKLOG=$W/fk/log FKROWS=$W/pin.json BUILDER_API=http://queue.invalid/q \
  BUILDER_CACHE=file://$W/cache BUILDER_FLAKE="git+file://$R?ref=main" BUILDER_LOAD_MAX=1000 GCDEL=$AG GCLOG=$W/gc.log "$@" ksh93 "$S" once 2>&1); c=$(<"$W/fk/log"); }
pk BUILDER_RECIPES=file://$W/served.tsv BUILDER_STATE=$W/stpin; print -r -- "$out" | sed 's/^/   N /'
has 'pin1: rebuilt .*qb-pin1-A-.* identical' && [[ $(nc pin1) == 1 ]] && print -r -- "$c" | grep '/complete' | grep -q "\"store_path\":\"$A1\"" &&
  ok "head moved past the served out: the builder evaluates pin1 at the commit that added its row ($RA), rebuilds out A, claims it" || no "origin: $(print -r -- "$out" | grep -E 'origins|pin1')"
has 'pin-camel: rebuilt .* identical' && ok "pname pin-camel -> attr pinCamel (gcc-wrapper -> gccWrapper)" || no "camel: $(print -r -- "$out" | grep camel)"
has 'gcd: rebuilt .* identical' && grep -q 'still alive' "$W/gc.log" && [[ -e $AG && -e $(nix-store -q --deriver "$AG") ]] &&
  ok "a GC between fetch and --rebuild cannot take the fetched served out or its drv (job roots): rebuilt identical" || no "gc root: $(<"$W/gc.log") $(print -r -- "$out" | grep gcd)"
[[ ! -e $W/stpin/job/gcd/root-out && ! -e $W/stpin/job/gcd/root-drv ]] && ok "the job's roots are dropped when the job ends" || no "job roots left behind"
# the served file mixes two batches from two commits on two branches (T1-like pin1 from A on main, W-like wrow from W on side):
# each row is built at its own commit, in the same tick
print "{\"rows\":[$(row pin1 1 outdated),$(row wrow 1 outdated)]}" > "$W/mix.json"
pk BUILDER_RECIPES=file://$W/servedW.tsv BUILDER_STATE=$W/stmix FKROWS=$W/mix.json; print -r -- "$out" | sed 's/^/   M /'
# the tick's sizing survives the origin map (ksh93 name() functions share the caller's scope: a helper's b/c once overwrote
# busy/cores with a commit sha, live on dixi 2026-11-02)
has 'up to [0-9]+ jobs of [0-9]+ cores \([0-9.]+ of [0-9]+ CPUs busy\)' && ! has 'jobs of [0-9]+ cores \([0-9a-f]{40} of' && ! has 'rebuilding .*\([0-9a-f]{12,} cores\)' &&
  ok "the origin map leaves the tick's busy and cores alone" || no "sizing clobbered: $(print -r -- "$out" | grep -E 'up to|cores\)' | head -2)"
has 'pin1: rebuilt .*qb-pin1-A-.* identical' && has 'wrow: rebuilt .*qb-wrow-W-.* identical' && [[ $(nc pin1) == 1 && $(nc wrow) == 1 ]] &&
  ok "two batches from two commits (main A, side W) in one served file: pin1 built at A, wrow at W, both claimed" || no "mixed: $(print -r -- "$out" | grep -E 'origins|pin1|wrow')"
# NEG: one pin for the whole file, either commit: the origin map says every out came from that commit (what a single blob pin does)
for x in A W; do eval "rv=\$R$x"; sed "s|\t[0-9a-f]\{40\}\$|\t$rv|" "$W/stmix/origins" > "$W/one.$x"; done
for x in A W; do  # a builder whose origins() is replaced by "every out came from $x": the single-pin behaviour
  sed "s|^origins() {|origins() { cat \"$W/one.$x\"; return 0; }; origins_unused() {|" "$S" > "$W/single-$x.sh"
  : > "$W/fk/log"; out=$(env BUILDER_PATH="$W/gcn:$W/fk:$PATH" FKREAL=$RC FKLOG=$W/fk/log FKROWS=$W/mix.json BUILDER_API=http://queue.invalid/q \
    BUILDER_CACHE=file://$W/cache BUILDER_FLAKE="git+file://$R?ref=main" BUILDER_LOAD_MAX=1000 BUILDER_RECIPES=file://$W/servedW.tsv BUILDER_STATE=$W/stone$x ksh93 "$W/single-$x.sh" once 2>&1); c=$(<"$W/fk/log")
  eval "n$x=\"\$(nc pin1) \$(nc wrow)\""
done
[[ $nA == "1 0" && $nW == "0 1" ]] && ok "NEG one pin for the whole file gets one batch wrong: at A wrow declines (1 0), at W pin1 declines (W moved it: 0 1)" || no "single pin: A=$nA W=$nW"
# NEG: no origin for a row (its out is in no commit's recipes.tsv) and head has moved on: declined, no claim
{ cat "$W/served.tsv"; } | sed "s|$A1|/nix/store/00000000000000000000000000000000-qb-pin1-A|" > "$W/served2.tsv"; pk BUILDER_RECIPES=file://$W/served2.tsv BUILDER_STATE=$W/stpin2
has 'decline pin1: no packages.x86_64-solaris attr at its commit' && [[ $(nc pin1) == 0 ]] &&
  ok "NEG a row whose out no commit added and head does not evaluate: declined, no claim" || no "neg origin: $(print -r -- "$out" | grep -E 'origins|pin1')"
# rows[].commit (infra 2026-11-02 §7): evaluated first. The origin map is emptied (BUILDER_FLAKE points at a repo that is not a
# git repo for origins), so only rows[].commit can bring pin1's out A; NEG: a commit that is not a full sha is ignored
rc() { print -n "{\"pname\":\"$1\",\"target\":\"1\",\"current\":\"1\",\"system\":\"x86_64-solaris\",\"reasons\":\"outdated\",\"attempts\":0,\"commit\":\"$2\"}"; }
print "{\"rows\":[$(rc pin1 "$RA")]}" > "$W/pinc.json"; print "{\"rows\":[$(rc pin1 "${RA:0:12}\$(id)")]}" > "$W/pinb.json"
mkdir -p "$W/nogit"; printf '#!/bin/sh\ncase "$*" in *hash-object*) exec %s "$@";; esac\nexit 1\n' "$(whence -p git)" > "$W/nogit/git"; chmod +x "$W/nogit/git"
pc() { : > "$W/fk/log"; out=$(env BUILDER_PATH="$W/nogit:$W/gcn:$W/fk:$PATH" FKREAL=$RC FKLOG=$W/fk/log BUILDER_API=http://queue.invalid/q BUILDER_CACHE=file://$W/cache \
  BUILDER_FLAKE="git+file://$R?ref=main" BUILDER_LOAD_MAX=1000 BUILDER_RECIPES=file://$W/served.tsv "$@" ksh93 "$S" once 2>&1); c=$(<"$W/fk/log"); }
pc BUILDER_STATE=$W/stpc FKROWS=$W/pinc.json
has 'row origins: 0 commits' && has 'pin1: rebuilt .*qb-pin1-A-.* identical' && [[ $(nc pin1) == 1 ]] &&
  ok "rows[].commit: with no origin map, the row's commit alone brings out A: rebuilt, claimed" || no "row commit: $(print -r -- "$out" | grep -E 'origins|pin1')"
P2=$(ksh93 "$S" plan "$W/pinc.json" "$W/served.tsv" 2> /dev/null); P3=$(ksh93 "$S" plan "$W/pinb.json" "$W/served.tsv" 2> /dev/null)
[[ $P2 == "pin1 BUILD $A1 1 $RA" && $P3 == "pin1 BUILD $A1 1 -" ]] && ok "plan carries a full-sha row commit, drops anything else ($P3)" || no "plan commit: $P2 | $P3"
pc BUILDER_STATE=$W/stpb FKROWS=$W/pinb.json
has 'decline pin1: no packages.x86_64-solaris attr' && [[ $(nc pin1) == 0 ]] && ok "NEG a row commit that is not a full sha is ignored: declined, no claim" || no "bad commit: $(print -r -- "$out" | grep pin1)"
# a cached eval at a fixed rev is reused on the next tick (no nix eval): the second tick of stmix finds both in $BUILDER_STATE/eval
ls "$W/stmix/eval" 2> /dev/null | grep -q "^$RA\.x86_64-solaris\.pin1\.outs$" && ls "$W/stmix/eval" | grep -q "^$RW\.x86_64-solaris\.wrow\.outs$" &&
  ok "evals cached per (commit, system, attr): $(ls "$W/stmix/eval" | grep -vc miss) hits kept" || no "eval cache: $(ls "$W/stmix/eval" 2>&1)"
# a full disk during the rebuild is not the recipe's fault: no memo, the next tick tries again (a nondeterministic build IS memo'd, flaky above)
pk BUILDER_RECIPES=file://$W/served.tsv BUILDER_STATE=$W/stns NOSPACE=1
has 'decline pin1: the host, not the recipe, failed the rebuild' && [[ $(ls "$W/stns/tried" | grep -c 'pin1.*out$') == 0 && $(nc pin1) == 0 ]] &&
  ok "no space during the rebuild: declined, not memo'd, no claim" || no "nospace: $(print -r -- "$out" | grep pin1) $(ls "$W/stns/tried")"
# a fixed W dir left by a build killed in a reboot (another nixbld's, 0700): the rebuild fails on rm, which is the host's state, not the recipe
pk BUILDER_RECIPES=file://$W/served.tsv BUILDER_STATE=$W/stsw STALEW=1
has 'decline pin1: the host, not the recipe, failed the rebuild' && [[ $(ls "$W/stsw/tried" | grep -c 'pin1.*out$') == 0 ]] &&
  ok "a stale fixed build dir (rm Permission denied): declined, not memo'd" || no "stale W: $(print -r -- "$out" | grep pin1) $(ls "$W/stsw/tried")"
# at start (the SMF loop, before its first tick) the sweep runs with age 0. Checked on the script, since the loop never exits.
grep -q 'ksh93 "$BUILDER_WSWEEP" 0 |' "$S" && ok "the builder sweeps stale fixed build dirs at start, whatever their age" || no "no start sweep"
# --- 5b. a row may name a NON-DEFAULT output (gcc's -lib; every wave6 mk-src-pkg drv has out + debug, some man/info/doc):
# drv_for evaluates every output and returns <drv>^<that output>; the rebuild and its claim use that output. A builder that
# compares only .outPath (OLD_BUILDER, the pre-fleet3 one) MISSes the -debug row: negative control.
R5=$W/repo5; mkdir -p "$R5"; g5() { git -C "$R5" -c user.name=t -c user.email=t@t "$@" > /dev/null 2>&1; }
print -r -- "{ outputs = { self }: { packages.x86_64-solaris.mo = derivation { name = \"qb-mo-1\"; pname = \"mo\"; version = \"1\";
  system = \"x86_64-solaris\"; outputs = [ \"out\" \"debug\" ]; builder = \"/bin/sh\";
  args = [ \"-c\" \"echo mo-${W##*/} > \$out; echo dbg-${W##*/} > \$debug\" ]; }; }; }" > "$R5/flake.nix"
g5 init -b main; g5 add -A; g5 commit -m mo; R5H=$(git -C "$R5" rev-parse HEAD)
MO=$(nix eval --raw "git+file://$R5?rev=$R5H#packages.x86_64-solaris.mo.out.outPath" 2> /dev/null)
MD=$(nix eval --raw "git+file://$R5?rev=$R5H#packages.x86_64-solaris.mo.debug.outPath" 2> /dev/null)
MV=$(nix eval --raw "git+file://$R5?rev=$R5H#packages.x86_64-solaris.mo.drvPath" 2> /dev/null)
nix build --no-link "git+file://$R5?rev=$R5H#packages.x86_64-solaris.mo^*" >> "$W/fixture.log" 2>&1 && nix copy --to "file://$W/cache" "$MO" "$MD" >> "$W/fixture.log" 2>&1 &&
  [[ $MD == *-qb-mo-1-debug && -e $MD ]] || no "fixture 5b: MO=$MO MD=$MD $(tail -2 "$W/fixture.log")"
df5() { ( eval "$(sed -n '/^bounded() {/,/^}/p; /^evattr() {/,/^}/p; /^drv_for() {/,/^}/p' "${2:-$S}")"
  BUILDER_SYSTEM=x86_64-solaris BUILDER_STATE=$W/st5b BUILDER_FLAKE="git+file://$R5?ref=main" J=x; drv_for mo "$1" "$R5H" ); }
r=$(df5 "$MD") && [[ $r == "$MD $MV^debug" ]] && ok "drv_for: a -debug row (out + debug outputs): FOUND $MV^debug" || no "drv_for debug: '$r'"
r=$(df5 "/nix/store/00000000000000000000000000000000-qb-mo-1-debug,$MO") && [[ $r == "$MO $MV^out" ]] && ok "drv_for: the default out still FOUND ^out" || no "drv_for out: '$r'"
r=$(df5 "$MD,$MO") && [[ $r == "$MO $MV^out"$'\n'"$MD $MV^debug" ]] && ok "drv_for: a job listing both outputs gets both lines, the default output (the primary) first" || no "drv_for both: '$r'"
ls "$W/st5b/eval/$R5H.x86_64-solaris.mo"* 2> /dev/null | grep -q '\.outs$' && (( $(wc -l < "$W/st5b/eval/$R5H.x86_64-solaris.mo.outs") == 2 )) &&
  r=$(df5 "$MD") && [[ $r == "$MD $MV^debug" ]] && ok "the eval cache keeps every output per (rev, system, attr) (.outs, 2 lines), and a cache hit finds -debug" || no "cache: $(ls "$W/st5b/eval" 2>&1)"
! df5 /nix/store/00000000000000000000000000000000-qb-mo-2-debug > /dev/null && ok "NEG drv_for: an out no output of the attr has (another version): MISS" || no "drv_for wrong out FOUND"
if [[ -n ${OLD_BUILDER:-} ]]; then ! df5 "$MD" "$OLD_BUILDER" > /dev/null && ok "NEG a builder before this change ($OLD_BUILDER) MISSes the -debug row (the bug this fixes)" || no "old builder found -debug: the control cannot fail"
else print "SKIP drv_for negative control: OLD_BUILDER unset (not counted as a pass)"; fi
# a tick: the -debug row is rebuilt as <drv>^debug and claimed with the debug out and its served NarHash
{ print -r -- "$H"; rec mo 1 y "$MD"; } > "$W/mo.tsv"; print "{\"rows\":[$(row mo 1 outdated)]}" > "$W/mo.json"; print x > "$W/bearer"; : > "$W/fk/log"
out=$(env BUILDER_PATH="$W/fk:$PATH" FKREAL=$RC FKLOG=$W/fk/log FKROWS=$W/mo.json BUILDER_API=http://queue.invalid/q BUILDER_CACHE=file://$W/cache \
  BUILDER_FLAKE="git+file://$R5?ref=main" BUILDER_LOAD_MAX=1000 BUILDER_RECIPES=file://$W/mo.tsv BUILDER_STATE=$W/st5t ksh93 "$S" once 2>&1); c=$(<"$W/fk/log")
MH=$(nawk '/^NarHash:/ {print $2}' "$(hp "$MD")")
has "mo: rebuilding $MV\^debug" && has "mo: rebuilt $MD here, identical" && print -r -- "$c" | grep '/complete' | grep -q "\"nar_hash\":\"$MH\",\"store_path\":\"$MD\"" &&
  ok "a tick: the -debug row is rebuilt as drv^debug, identical, and the job completed with the debug out's NarHash" || no "tick 5b: $(print -r -- "$out" | grep ' mo')"
# --- 6. fleet2: a job lists outs from several commits; the builder rebuilds the first CANDIDATE (head, then origins newest first)
# whose out is served and whose dry run builds no non-FOD input here. Repo2: O adds rows, N adds more, head H moves on.
#   tw: O's out needs a dep nobody has, N's is clean -> N (origin/main tried O alone and declined: dixi gnupatch/libffi 2026-11-02)
#   tv: N's needs the dep, O's is clean -> O (the fallback goes both ways);  th: head evaluates O's served out -> head, first
#   tb: both need a dep -> declined with both reasons, nothing memo'd;  tg: an eval cached at N whose .drv a GC took -> re-evaluated
R2=$W/repo2; mkdir -p "$R2/docs/registry"; g2() { git -C "$R2" -c user.name=t -c user.email=t@t "$@" > /dev/null 2>&1; }
pf2() {	# pf2 <tw> <tv> <th> <tb> <tg>: each c<tag> (a clean build) or d<tag> (needs a per-run dep nobody has)
  typeset a n t s= i=0; set -A nm tw tv th tb tg
  for a; do n=${nm[i]} t=${a#?}; i=$((i + 1))
    if [[ $a == c* ]]; then s="$s $n = mk \"qb-$n-$t-${W##*/}\" \"echo $t > \$out\";"
    else s="$s $n = mk \"qb-$n-$t-${W##*/}\" \"cat \${mk \"qb-${n}dep-$t-${W##*/}\" \"echo dep > \$out\"} > \$out\";"; fi; done
  print -r -- "{ outputs = { self }: let mk = name: script: derivation { inherit name; system = \"x86_64-solaris\"; builder = \"/bin/sh\"; args = [ \"-c\" script ]; };
  in { packages.x86_64-solaris = {$s }; }; }" > "$R2/flake.nix"; g2 add -A; }
p2() { nix eval --raw "git+file://$R2?rev=$(git -C "$R2" rev-parse HEAD)#packages.x86_64-solaris.$1.outPath" 2> /dev/null; }
g2 init -b main; pf2 dO cO cO dO cO; g2 commit -m O; TO=$(p2 tw) VO=$(p2 tv) HO=$(p2 th) BO=$(p2 tb)
{ print -r -- "$H"; rec tw 1 y "$TO"; rec tv 1 y "$VO"; rec th 1 y "$HO"; rec tb 1 y "$BO"; } > "$R2/docs/registry/recipes.tsv"; g2 add -A; g2 commit -m rowsO; RO=$(git -C "$R2" rev-parse HEAD)
pf2 cN dN cN dN cN; g2 commit -m N; TN=$(p2 tw) VN=$(p2 tv) HN=$(p2 th) BN=$(p2 tb) GN=$(p2 tg)
{ rec tw 1 y "$TN"; rec tv 1 y "$VN"; rec th 1 y "$HN"; rec tb 1 y "$BN"; rec tg 1 y "$GN"; } >> "$R2/docs/registry/recipes.tsv"; g2 add -A; g2 commit -m rowsN; RN=$(git -C "$R2" rev-parse HEAD)
pf2 cH cH cO dH cH; g2 commit -m head; git -C "$R2" show "$RN:docs/registry/recipes.tsv" > "$W/served6.tsv"
nix build --no-link "git+file://$R2?rev=$RN#packages.x86_64-solaris."{tw,tg} "git+file://$R2?rev=$RO#packages.x86_64-solaris."{tv,th} >> "$W/fixture.log" 2>&1 &&
  nix copy --to "file://$W/cache" "$TN" "$GN" "$VO" "$HO" >> "$W/fixture.log" 2>&1 && [[ -n $TO && -n $TN && -n $VN && -n $BN && $TO != "$TN" && $HN != "$HO" ]] ||
  no "fixture 6: TO=$TO TN=$TN VN=$VN BN=$BN $(tail -2 "$W/fixture.log")"
for x in "$TO" "$VN" "$BO" "$BN"; do printf 'StorePath: %s\nNarHash: %s\n' "$x" "$GH" > "$(hp "$x")"; done	# served, as needs above
print "{\"rows\":[$(row tw 1 outdated),$(row tv 1 outdated),$(row th 1 outdated),$(row tb 1 outdated),$(row tg 1 outdated)]}" > "$W/six.json"
mkdir -p "$W/st6/eval"; print -r -- "$GN /nix/store/00000000000000000000000000000000-qb-tg-gone.drv^out" > "$W/st6/eval/$RN.x86_64-solaris.tg.outs"
six() { : > "$W/fk/log"; out=$(env BUILDER_PATH="$W/fk:$PATH" FKREAL=$RC FKLOG=$W/fk/log FKROWS=$W/six.json BUILDER_API=http://queue.invalid/q BUILDER_CACHE=file://$W/cache \
  BUILDER_FLAKE="git+file://$R2?ref=main" BUILDER_LOAD_MAX=1000 BUILDER_RECIPES=file://$W/served6.tsv BUILDER_STATE=$W/st6 ksh93 "${1:-$S}" once 2>&1); c=$(<"$W/fk/log"); }
six; print -r -- "$out" | sed 's/^/   6 /'
done6() { print -r -- "$c" | grep '/complete' | grep -q "\"status\":\"done\".*\"store_path\":\"$1\""; }
has "tw: candidate ${RN:0:12} .*qb-tw-N-" && has 'tw: rebuilt .*qb-tw-N-.* identical' && [[ $(nc tw) == 1 ]] && done6 "$TN" &&
  ok "two candidates, the older needs an unserved input: the newer ($RN) is rebuilt and claimed" || no "tw: $(print -r -- "$out" | grep ' tw')"
has "tv: candidate ${RO:0:12} .*qb-tv-O-.*skipped: the dry run would build 1 .*\[${RN:0:12}\]" && has 'tv: rebuilt .*qb-tv-O-.* identical' && [[ $(nc tv) == 1 ]] && done6 "$VO" &&
  ok "the newest candidate needs an unserved input: the older one is rebuilt, the skip logged" || no "tv: $(print -r -- "$out" | grep ' tv')"
# fleet9: th's newest row (N, unserved: nobody built it) waits; head's served O out (an older row) is not voted while it does
has "decline th: .*qb-th-N-.* is not served \(a first build .*\[${RN:0:12}\]: the job waits for it \(no vote on an older row\)" && [[ $(nc th) == 0 ]] && ! done6 "$HO" &&
  ok "NEG th: the newest row's out (N) is unserved and this host may not publish: declined, waits; head's older served out is never voted (fleet9)" || no "th: $(print -r -- "$out" | grep ' th')"
cm6() { print -r -- "$c" | grep '/complete' | grep "\"store_path\":\"$1\"" | grep -q "\"commit\":\"$2\""; }
cm6 "$TN" "$RN" && cm6 "$VO" "$RO" && ok "completions carry commit: the candidate's evaluated rev (tw: $RN; tv: $RO)" || no "commit: $(print -r -- "$c" | grep complete)"
has "decline tb: the dry run would build 1 .*\[${RN:0:12}\]; the dry run would build 1 .*\[${RO:0:12}\]" && [[ $(nc tb) == 0 ]] &&
  ! ls "$W/st6/tried" 2> /dev/null | egrep -q 'qb-(tb|tw-O|tv-N)-' && ok "NEG every candidate needs an unserved input: declined with each reason, no claim, no candidate memo'd" ||
  no "tb: $(print -r -- "$out" | grep ' tb') $(ls "$W/st6/tried" 2>&1)"
has 'tg: rebuilt .*qb-tg-N-.* identical' && [[ $(nc tg) == 1 ]] && ! grep -q 00000000000000000000000000000000 "$W/st6/eval/$RN.x86_64-solaris.tg.outs" &&
  ok "an eval cache hit whose .drv was GC'd is re-evaluated, not declined 'cannot root' (dixi nss, solnix-cputemp 2026-11-02)" || no "tg: $(print -r -- "$out" | grep ' tg')"
# --- 7. fleet3: first publish of a served row's unserved out with this host's own key (BUILDER_PUBLISH). The fixture cache
# is a python http.server over a file:// cache signed with a test key (it stands in for cache.solnix.io + 8UNr); the
# submitter hook runs the REAL cache-submit.py planner pointed at that cache (stage, pathinfo, stamp, drv-gate --leaf, refs),
# then answers as the server would, by name: promoted (it publishes + signs), proposed, rejected, 429, a forged signature.
# pre-submit-check.sh --leaf runs for real (GATE_CACHE = the fixture cache). Nothing here talks to builders.solnix.io.
GP=${GATE_PYTHON:-/nix/store/nwmx779ahmnyl692n6ibdlhifwaa8dwm-python3-3.13.9/bin/python3}
GG=${GATE_GREP_DIR:-/nix/store/hd2f25vypgb47i0p88m2k5v38c4j4bxw-gnugrep-3.11/bin}
OS=${OPENSSL_BIN:-/nix/store/gppisr3kxnrnnw73vw1pi49b9m2x8w7z-openssl-3.4.0/bin}
for x in "${GP%/bin/*}" "${GG%/bin}" "${OS%/bin}"; do [[ -e $x ]] || nix-store -r "$x" > /dev/null 2>&1; done
G=$(cd "$(dirname "$0")/.." && pwd); mkdir -p "$W/gates/scripts" "$W/gates/pkgs/illumos" "$W/hc" "$W/fkst" "$W/vp"
for f in cache-submit.py pre-submit-check.sh drv-gate.sh publish-gate.sh gate-checks.py not-for-cache.tsv gate2-exemptions.tsv; do cp "$G/scripts/$f" "$W/gates/scripts/"; done
cp "$G/pkgs/illumos/bootstrap-exempt.tsv" "$W/gates/pkgs/illumos/"
nix key generate-secret --key-name qb-test-1 > "$W/sk"; nix key convert-secret-to-public < "$W/sk" > "$W/pk"
nix key generate-secret --key-name qb-test-1 > "$W/sk2"	# the same key name, another key: a forged signature
ssh-keygen -q -t ed25519 -N '' -C qb-host -f "$W/hostkey" < /dev/null	# the host's builder key (0600)
print 'StoreDir: /nix/store' > "$W/hc/nix-cache-info"
PORT=$(( 20000 + RANDOM % 20000 )); HC=http://127.0.0.1:$PORT
"$GP" -m http.server --bind 127.0.0.1 "$PORT" --directory "$W/hc" > "$W/http.log" 2>&1 & HP=$!
trap 'kill $HP 2> /dev/null; find "$W" -depth -delete' EXIT
i=0; while (( (i += 1) < 30 )) && ! curl -sf -o /dev/null "$HC/nix-cache-info"; do sleep 1; done
# the fixture planner: cache-submit.py with the fixture cache, recipes and key in place of cache.solnix.io's (never --submit)
sed -e "s|^CACHE = .*|CACHE = \"$HC\"|" -e "s|^RECIPES = .*|RECIPES = \"$W/p.tsv\"|" -e "s|^KEY8UNR = .*|KEY8UNR = \"$(<"$W/pk")\"|" \
  -e 's|^API = .*|API = "http://127.0.0.1:9"|' "$W/gates/scripts/cache-submit.py" > "$W/gates/scripts/cs-fixture.py"
# a store copy that fails nix-store --verify-path (pubcorrupt): a wrapper, since a real one would need root to damage
{ print '#!/bin/sh'; print 'case "$1 $2" in "--verify-path "*pubcorrupt*) echo "path $2 was modified! expected hash sha256:0, got sha256:1" >&2; exit 1;; esac'
  print "exec $(whence -p nix-store) \"\$@\""; } > "$W/vp/nix-store"; chmod +x "$W/vp/nix-store"
mkdir -p "$W/pflake"; cat > "$W/pflake/flake.nix" <<PF
{ outputs = { self }: let
    mk = name: script: derivation { inherit name; system = "x86_64-solaris"; builder = "/usr/bin/bash"; args = [ "-c" script ]; };
    t = n: mk "qb-\${n}-${W##*/}" "echo building \${n}; echo \${n}-${W##*/} > \$out";
    dep = t "pubdep";
  in { packages.x86_64-solaris = {
    pubok = t "pubok"; pubok2 = t "pubok2"; pubok3 = t "pubok3"; pubprop = t "pubprop"; pubrej = t "pubrej"; pub429 = t "pub429";
    pubforge = t "pubforge"; pubcorrupt = t "pubcorrupt"; pubx = t "pubx"; pubmut = t "pubmut"; pubdep = dep;
    pubneeds = mk "qb-pubneeds-${W##*/}" "echo building; echo \${dep} > \$out";
    pubflaky = mk "qb-pubflaky-${W##*/}" "echo building; echo \$RANDOM\$\$ > \$out";
    # the pre-wave6 legacy env PATH without the builder's PATH= first statement: drv-gate --leaf FAILs A1 (no ALLOW)
    pubgate = derivation { name = "qb-pubgate-${W##*/}"; system = "x86_64-solaris"; builder = "/usr/bin/bash";
      PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin"; args = [ "-c" "echo building; echo g > \$out" ]; };
  }; }; }
PF
# the submitter hook (python: argument lists): the REAL planner (cs-fixture.py, dry), then the server's answer by out name
{ print "#!$GP"; cat <<'PY'
import os, sys, subprocess, shutil, tempfile
W, a = os.environ["FKW"], sys.argv[1:]
opt = lambda n: a[a.index(n) + 1] if n in a else None
b, sid, sub = opt("--builder"), opt("--status"), "--submit" in a
paths = open(opt("--paths")).read().split() if opt("--paths") else []
log = open(W + "/fk/sublog", "a")
log.write(f"CALL builder={b} key={opt('--key')} submit={int(sub)} status={sid} paths={' '.join(paths)}\n"); log.flush()
def promote(stage, p, key):
    h = os.path.basename(p)[:32]; os.makedirs(W + "/hc/nar", exist_ok=True)
    ni = open(f"{stage}/{h}.narinfo").read(); url = [l[5:] for l in ni.splitlines() if l.startswith("URL: ")][0]
    shutil.copy(f"{stage}/{url}", f"{W}/hc/{url}"); open(f"{W}/hc/{h}.narinfo", "w").write(ni)
    env = dict(os.environ, XDG_CACHE_HOME=tempfile.mkdtemp(dir=W + "/fkst"))
    subprocess.run(["nix", "store", "sign", "--store", "file://" + W + "/hc", "--key-file", key, p], env=env, check=True, capture_output=True)
if sid:
    f = f"{W}/fkst/{sid}"; st, p = open(f).read().split()
    if st == "proposed" and os.path.exists(W + "/fk/approve"):
        promote(f + ".stage", p, W + "/sk"); st = "promoted"; open(f, "w").write(f"{st} {p}\n")
    print(f"STATUS {sid}\n  status: {st}\n  result: {st}"); sys.exit(0)
r = subprocess.run([os.environ["FKGP"], W + "/gates/scripts/cs-fixture.py"] + [x for x in a if x != "--submit"], capture_output=True, text=True)
print(r.stdout + r.stderr, end="")
p = paths[0] if paths else ""
if not sub or not any(l.split()[:2] == ["READY", p] for l in r.stdout.splitlines()):
    sys.exit(0)
log.write(f"BEGIN {p} builder={b}\n"); log.flush()
nm = os.path.basename(p)[33:].split("-"); n = nm[1]; sid = "-".join(["sid", n] + nm[3:]); stage = opt("--cache-dir")  # sid-mprop-lib: one per output
if n == "pub429":
    print('  begin: HTTP 429 {"error":"proposal backlog","proposed_bytes":2202009600,"cap":2147483648}\n  result: backoff 900'); sys.exit(0)
print(f"  submission {sid} staging http://staging.invalid")
for l in r.stdout.splitlines():
    if l.startswith("  begin body "): log.write("BODY " + l[13:] + "\n"); log.flush()
if "--eval" in a:
    shutil.copytree(stage, f"{W}/fkst/{sid}.stage"); open(f"{W}/fkst/{sid}", "w").write(f"proposed {p}\n")
    print("  status: proposed\n  result: proposed"); sys.exit(0)
if n == "pubrej":
    print("  status: rejected content gate REJECTED: FAIL build-host: /x: contains 'ip-10-0-1-23.ec2.internal'\n  result: rejected"); sys.exit(0)
if n == "pubprop" or (n == "mprop" and p.endswith("-lib")):
    shutil.copytree(stage, f"{W}/fkst/{sid}.stage"); open(f"{W}/fkst/{sid}", "w").write(f"proposed {p}\n")
    print("  status: proposed\n  result: proposed"); sys.exit(0)
if n in ("dzd", "dze"):  # fleet9's lock test: the first submission of a reference is slow, so a second job of the tick meets it
    import time; time.sleep(float(os.environ.get("FKSLOWSUB") or 0))
promote(stage, p, W + ("/sk2" if n == "pubforge" else "/sk"))  # pubforge: signed by another key under the same name
print("  status: promoted\n  result: promoted")
PY
} > "$W/fk/submit"; chmod +x "$W/fk/submit"
PF=path:$W/pflake; po7() { jq -r --arg a "$1" '.[$a]' "$W/pouts.json"; }
nix eval --json "$PF#packages.x86_64-solaris" --apply 'builtins.mapAttrs (n: d: d.outPath)' > "$W/pouts.json" 2> "$W/peval.err" &&
  nix build --no-link "$PF#packages.x86_64-solaris.pubdep" >> "$W/fixture.log" 2>&1 || { no "fixture 7: $(tail -3 "$W/peval.err" "$W/fixture.log")"; }
P7="pubok pubok2 pubok3 pubprop pubrej pub429 pubforge pubcorrupt pubneeds pubflaky pubgate pubmut"	# pubdep: no row (fleet9's deps first would publish a rowed one)
{ print -r -- "$H"; for a in $P7; do rec $a 1 y "$(po7 $a)"; done; } > "$W/p.tsv"	# pubx: no row (an unrowed out)
mkdir -p "$W/hc/registry"; cp "$W/p.tsv" "$W/hc/registry/recipes.tsv"	# pre-submit-check.sh reads $GATE_CACHE/registry/recipes.tsv
r7() { typeset s= a; for a; do s="$s${s:+,}$(row $a 1 outdated)"; done; print "{\"rows\":[$s]}"; }
# tk7 [VAR=value...]: one tick, publish on, against the fake queue, the fixture cache (http) and the fixture key
tk7() { : > "$W/fk/log"; : > "$W/fk/sublog"; out=$(env BUILDER_PATH="$W/vp:$W/fk:$PATH" FKREAL=$RC FKLOG=$W/fk/log FKROWS=$W/p7.json FKW=$W FKGP=$GP \
  BUILDER_API=http://queue.invalid/q BUILDER_RECIPES=$HC/registry/recipes.tsv BUILDER_CACHE=$HC BUILDER_CACHE_KEY="$(<"$W/pk")" BUILDER_FLAKE=$PF BUILDER_LOAD_MAX=1000 \
  BUILDER_PUBLISH=1 BUILDER_PUBLISH_KEY=$W/hostkey BUILDER_AGENT=qbhost BUILDER_GATES=$W/gates BUILDER_PYTHON=$GP BUILDER_SUBMIT=$W/fk/submit \
  GATE_PYTHON=$GP GATE_GREP_DIR=$GG GATE_CACHE=$HC GATE_RECIPES= BUILDER_VERIFY_WAIT=1 BUILDER_PUBLISH_POLL=5 BUILDER_STATE=$W/st7 "$@" ksh93 "$S" once 2>&1)
  c=$(<"$W/fk/log"); sl=$(<"$W/fk/sublog"); }
begun() { print -r -- "$sl" | grep -c "^BEGIN .*qb-$1-"; }
PATH=$OS:$PATH; export PATH
# serial (BUILDER_JOBS 1), pub429 last: its back-off stops every LATER new submission (tick C checks that)
r7 pubok pubok2 pubprop pubrej pubforge pubcorrupt pubneeds pubflaky pubgate pub429 > "$W/p7.json"
print x > "$W/bearer"; tk7; print -r -- "$out" | sed 's/^/   7 /'; print -r -- "$sl" | sed 's/^/   s /'
sv7() { curl -sf "$HC/$(print -r -- "${1#/nix/store/}" | cut -c1-32).narinfo" | nawk '/^NarHash:/ {print $2}'; }
cl7() { print -r -- "$c" | grep '/claim ' | grep -c "\"pnames\":\[\"$1\"\]"; }
for a in pubok pubok2; do
  [[ $(begun $a) == 1 ]] && has "$a: published .*qb-$a-.*an 8UNr-only client verified it" && [[ $(cl7 $a) == 1 && -n $(sv7 "$(po7 $a)") ]] &&
    print -r -- "$c" | grep '/complete' | grep -q "\"status\":\"done\",\"version\":\"1\",\"nar_hash\":\"$(sv7 "$(po7 $a)")\",\"store_path\":\"$(po7 $a)\"" &&
    ok "$a: a served row's unserved out: built, pre-submit --leaf, submitted once, promoted, client-verified, claimed + completed done" || no "$a: $(print -r -- "$out" | grep " $a")"
done
print -r -- "$sl" | grep '^CALL' | grep -v "builder=qbhost key=$W/hostkey " | grep -q . && no "a submission without the host's own id and key" ||
  ok "every submission carries the host's builder id and key (never site-team)"
print -r -- "$c" | grep '/complete' | grep -q '"commit"' && no "commit sent for a path: flake (no git rev)" || ok "no commit in the body when the evaluated flake has no git rev"
[[ $(begun pubprop) == 1 && -s $W/st7/pub/$(basename "$(po7 pubprop)") && $(cl7 pubprop) == 0 ]] && has 'pubprop: .* is proposed .*waiting for review' &&
  ok "tier 1: proposed -> waits (marker kept), no claim, not a failure" || no "pubprop: $(print -r -- "$out" | grep pubprop)"
m7() { ls "$W/st7/tried/" 2> /dev/null | grep -c "qb-$1-.*\.drv\^out\.pub$"; }
[[ $(begun pubrej) == 1 && $(m7 pubrej) == 1 && $(cl7 pubrej) == 0 ]] && has 'decline pubrej: rejected \(sid-pubrej\)' &&
  ok "rejected: memo'd with the reason, no claim" || no "pubrej: $(print -r -- "$out" | grep pubrej)"
[[ $(begun pub429) == 1 && $(cl7 pub429) == 0 && -s $W/st7/pub/backoff && $(m7 pub429) == 0 ]] && (( $(<"$W/st7/pub/backoff") > $(printf '%(%s)T' now) + 800 )) &&
  has 'pub429: /begin answered 429: backing off 900 s' && ok "429 + Retry-After: backs off 900 s, not memo'd, no claim" || no "pub429: $(print -r -- "$out" | grep pub429)"
[[ $(begun pubforge) == 1 && $(cl7 pubforge) == 0 ]] && has 'decline .*qb-pubforge-.*: the client check failed' &&
  ok "NEG promoted but signed by another key: the 8UNr-style client check fails, no claim" || no "pubforge: $(print -r -- "$out" | grep pubforge)"
[[ $(print -r -- "$sl" | grep -c 'qb-pubflaky-') == 0 && $(m7 pubflaky) == 1 && $(cl7 pubflaky) == 0 ]] && has 'decline pubflaky: pre-submit-check.sh --leaf .* rc=1 \(check' &&
  ok "NEG --check DIFFERS (nondeterministic): never submitted, memo'd" || no "pubflaky: $(print -r -- "$out" | grep pubflaky)"
[[ $(print -r -- "$sl" | grep -c 'qb-pubgate-') == 0 && $(m7 pubgate) == 1 ]] && has 'decline pubgate: pre-submit-check.sh --leaf .* rc=1 \(drv' &&
  grep -q 'FAIL A1-path' "$W/st7/tried/"*qb-pubgate-*.presubmit && ok "NEG drv-gate --leaf FAILs (host env PATH): never submitted" || no "pubgate: $(print -r -- "$out" | grep pubgate)"
[[ $(print -r -- "$sl" | grep -c 'qb-pubcorrupt-') == 0 && $(m7 pubcorrupt) == 1 ]] && has 'decline pubcorrupt: nix-store --verify-path .* failed' &&
  ok "NEG this store's copy fails --verify-path: never submitted" || no "pubcorrupt: $(print -r -- "$out" | grep pubcorrupt)"
[[ $(print -r -- "$sl" | grep -c 'qb-pubneeds-') == 0 && $(m7 pubneeds) == 0 && $(cl7 pubneeds) == 0 ]] && has "pubneeds: .* waits for its references to be served first: .*qb-pubdep-" &&
  ! has 'deps first: first-publishing its reference .*qb-pubdep-' && ok "NEG deps first: a reference not served (and no served row names it) -> waits, not submitted, not memo'd" || no "pubneeds: $(print -r -- "$out" | grep pubneeds)"
# tick B: the dep is served now (published from elsewhere), the proposal approved: pubneeds publishes, pubprop is polled (not
# resubmitted) and claimed; a published out is not rebuilt or submitted again (its rebuild memo is ok); refused ones stay refused
mkdir -p "$W/hc/nar"; nix copy --to "file://$W/hc" "$(po7 pubdep)" >> "$W/fixture.log" 2>&1 &&
  ( export XDG_CACHE_HOME=$W/fkst/x; nix store sign --store "file://$W/hc" --key-file "$W/sk" "$(po7 pubdep)" ) >> "$W/fixture.log" 2>&1
# (tick A's 429 back-off is parked for this tick, so new submissions may start; tick C puts it back and checks it)
mv "$W/st7/pub/backoff" "$W/backoff.A"; : > "$W/fk/approve"; r7 pubok pubprop pubrej pubneeds pubflaky > "$W/p7.json"; tk7; print -r -- "$out" | sed 's/^/   B /'
mv "$W/backoff.A" "$W/st7/pub/backoff"
[[ $(begun pubneeds) == 1 && $(cl7 pubneeds) == 1 ]] && has 'pubneeds: published' && ok "deps first: once its reference is served, the next tick publishes it" || no "pubneeds B: $(print -r -- "$out" | grep pubneeds)"
[[ $(begun pubprop) == 0 && $(print -r -- "$sl" | grep -c 'status=sid-pubprop') == 1 && $(cl7 pubprop) == 1 && ! -e $W/st7/pub/$(basename "$(po7 pubprop)") ]] &&
  has 'pubprop: published .*sid-pubprop' && ok "an approved proposal: polled by id on the next tick (never resubmitted), then verified and claimed" || no "pubprop B: $(print -r -- "$out" | grep pubprop) $sl"
[[ $(print -r -- "$sl" | grep -c 'qb-pubok-') == 0 && $(cl7 pubok) == 1 ]] && has 'pubok: rebuilt and matched on an earlier tick' &&
  ok "published on an earlier tick: now served, so the verification path claims it again without a third build or a submission" || no "pubok B: $(print -r -- "$out" | grep ' pubok')"
[[ $(print -r -- "$sl" | grep -c 'qb-pub\(rej\|flaky\)-') == 0 ]] && has 'held pubrej: newest .*qb-pubrej-.* refused here \(rejected' &&
  ok "refused outs (rejected, --check differs) are not built or submitted again" || no "refused B: $(print -r -- "$out" | grep -E 'pubrej|pubflaky')"
# tick C: inside the 429 back-off no new submission starts; after it (backoff file in the past) pub429 is submitted again
r7 pubok3 pub429 > "$W/p7.json"; tk7
[[ $(print -r -- "$sl" | grep -c BEGIN) == 0 ]] && has 'new submissions back off for' && ok "inside the Retry-After window: no /begin at all" || no "429 window: $out"
print 1 > "$W/st7/pub/backoff"; tk7
[[ $(begun pub429) == 1 && $(begun pubok3) == 1 ]] && has 'pubok3: published' && ok "after the back-off: submissions resume (pub429 again: 429, pubok3 published)" || no "429 after: $(print -r -- "$out" | grep -E 'pub429|pubok3')"
# NEG controls on fresh outs (pubmut: a served row, unserved, clean): none of these may reach /begin
r7 pubmut > "$W/p7.json"
tk7 BUILDER_PUBLISH_ID=site-team BUILDER_STATE=$W/st7s
[[ -z $sl && $(cl7 pubmut) == 0 ]] && has 'decline pubmut: .* is not served' && ok "NEG builder id site-team: never submits from a host" || no "site-team: $out $sl"
tk7 BUILDER_PUBLISH=0 BUILDER_STATE=$W/st7z
[[ -z $sl && $(cl7 pubmut) == 0 ]] && has 'decline pubmut: .* is not served \(a first build' && ok "NEG BUILDER_PUBLISH=0 (the default): declines as before, nothing submitted" || no "publish 0: $out $sl"
tk7 BUILDER_PUBLISH_KEY=$W/nokey BUILDER_STATE=$W/st7k
[[ -z $sl ]] && has 'decline pubmut: .* is not served' && ok "NEG no readable host key: declines, nothing submitted" || no "no key: $out $sl"
if [[ -n ${OLD_BUILDER:-} ]]; then S0=$S S=$OLD_BUILDER; tk7 BUILDER_STATE=$W/st7o; S=$S0
  [[ -z $sl && $(cl7 pubmut) == 0 ]] && has 'decline pubmut: .* is not served' && ok "NEG origin/main's builder ($OLD_BUILDER) never submits, whatever BUILDER_PUBLISH says" || no "old builder: $out $sl"
else print "SKIP origin/main negative control: OLD_BUILDER unset (not counted as a pass)"; fi
# a mutant that skips pre-submit-check.sh: cache-submit.py's stamp interlock refuses it (NO-STAMP), no /begin
sed 's|bash "$BUILDER_GATES/scripts/pre-submit-check.sh" $fa "$2"|print -r -- "PASS $2 (mutant: no checks)"|' "$S" > "$W/mut.sh"; S0=$S S=$W/mut.sh; tk7 BUILDER_STATE=$W/st7m; S=$S0
! cmp -s "$S" "$W/mut.sh" && [[ $(print -r -- "$sl" | grep -c BEGIN) == 0 && $(cl7 pubmut) == 0 ]] && has "pubmut: submission .*ended 'plan NO-STAMP'" &&
  ok "NEG a builder that skips pre-submit-check: the planner says NO-STAMP, nothing begun" || no "mutant: $(print -r -- "$out" | grep pubmut) $sl"
# BUILDER_PUBLISH=dry, no bearer: every gate and the real planner (READY), never /begin, never a claim
rm -f "$W/bearer"; tk7 BUILDER_PUBLISH=dry BUILDER_STATE=$W/st7d
[[ $(print -r -- "$sl" | grep -c BEGIN) == 0 && $(claims) == 0 ]] && print -r -- "$sl" | grep -q '^CALL .*submit=0' && has 'dry run: would submit .*qb-pubmut-' &&
  grep -q "^READY  *$(po7 pubmut)" "$W/st7d/tried/"*qb-pubmut-*.submit && ok "BUILDER_PUBLISH=dry: built, gated, planned READY by cache-submit.py, never begun or claimed" || no "dry: $(print -r -- "$out" | grep pubmut)"
# an out no served row names (pubx), proved by hand: refused before any build
out=$(env BUILDER_PATH="$W/fk:$PATH" FKREAL=$RC BUILDER_RECIPES=$HC/registry/recipes.tsv BUILDER_CACHE=$HC BUILDER_FLAKE=$PF BUILDER_PUBLISH=dry BUILDER_PUBLISH_KEY=$W/hostkey \
  BUILDER_GATES=$W/gates BUILDER_PYTHON=$GP BUILDER_SUBMIT=$W/fk/submit FKW=$W FKGP=$GP BUILDER_STATE=$W/st7x ksh93 "$S" ready pubx "$(po7 pubx)" 2>&1)
has 'decline pubx: .* is not an out of the served recipes.tsv' && [[ ! -e $(po7 pubx) ]] && ok "NEG an out with no served row: never built or submitted" || no "pubx: $out"
rm -f "$W/bearer"
# --- 8. fleet4: eval-anchored jobs (BUILDER_EVAL). Repo3: main M1 -> M2 (evok moves); 26.11 = M1 + K (adds ev2611, with no
# pname/version attrs: parseDrvName); wave5 = M1 + W5 (adds evoff: on no allowed branch); wave6 = M1 + W6 (adds evw6: allowed
# only when listed). No out has a row or is served.
rm -f "$W/fk/approve"; R3=$W/repo3; mkdir -p "$R3"; g3() { git -C "$R3" -c user.name=t -c user.email=t@t "$@" > /dev/null 2>&1; }
cat > "$W/f8.tmpl" <<'F8'
{ outputs = { self }: let
    e = n: p: v: s: x: derivation ({ name = "qb-${n}-@TAG@"; pname = p; version = v; system = "x86_64-solaris";
      builder = "/usr/bin/bash"; args = [ "-c" "echo building ${n}; ${s}" ]; } // x);
    evindep = e "evindep" "evindep" "1" "echo dep > $out" { };
    # a host-PATH input (the legacy env PATH): --closure judges it, served or not
    evclodep = e "evclodep" "evclodep" "1" "echo dep > $out" { PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin"; };
  in { packages.x86_64-solaris = { inherit evindep;
    evok = e "evok" "evok" "1" "echo @EVOK@ > $out" { };
    evin = e "evin" "evin" "1" "read x < ${evindep}; echo $x > $out" { };	# builtins only: the builder has no PATH
    evclo = e "evclo" "evclo" "1" "read x < ${evclodep}; echo $x > $out" { };
    evver = e "evver" "evver" "1" "echo v > $out" { };
    gate = e "gate" "illumos-gate-proto" "0.65.0" "echo g > $out" { };
    "pkg-config" = e "pkgcfg" "pkgconf" "2.3.0" "echo p > $out" { };
    evvote = e "evvote" "evvote" "1" "echo evvote-@TAG@ > $out" { };
    evbump = e "evbump" "evbump" "@BV@" "echo bump@BV@ > $out" { };
    @EXTRA@
  }; }; }
F8
pf8() { sed -e "s|@EXTRA@|${2:-}|" -e "s|@EVOK@|$1|" -e "s|@BV@|${3:-1}|g" -e "s|@TAG@|${W##*/}|g" "$W/f8.tmpl" > "$R3/flake.nix"; g3 add -A; }
g3 init -b main; pf8 M1; g3 commit -m M1; M1=$(git -C "$R3" rev-parse HEAD)
g3 checkout -b 26.11; pf8 M1 'ev2611 = derivation { name = "ev2611-1"; system = "x86_64-solaris"; builder = "/usr/bin/bash"; args = [ "-c" "echo building ev2611; echo 2611-@TAG@ > $out" ]; };'
g3 commit -m K; K=$(git -C "$R3" rev-parse HEAD)
g3 checkout -b wave5 "$M1"; pf8 M1 'evoff = e "evoff" "evoff" "1" "echo off > $out" { };'; g3 commit -m W5; W5=$(git -C "$R3" rev-parse HEAD)
g3 checkout -b wave6 "$M1"; pf8 M1 'evw6 = e "evw6" "evw6" "1" "echo w6 > $out" { };' 2; g3 commit -m W6; W6=$(git -C "$R3" rev-parse HEAD); g3 checkout main
pe8() { nix eval --raw "git+file://$R3?ref=$1&rev=$2#packages.x86_64-solaris.$3.outPath" 2> /dev/null; }
EVOK1=$(pe8 main "$M1" evok) E2611=$(pe8 26.11 "$K" ev2611) EVIN=$(pe8 main "$M1" evin) EVDEP=$(pe8 main "$M1" evindep) EVOFF=$(pe8 wave5 "$W5" evoff)
NH1=$(nix flake metadata --json "git+file://$R3?ref=main&rev=$M1" 2> /dev/null | jq -r '.locked.narHash // empty')
NHK=$(nix flake metadata --json "git+file://$R3?ref=26.11&rev=$K" 2> /dev/null | jq -r '.locked.narHash // empty')
EVW6=$(pe8 wave6 "$W6" evw6) NHW6=$(nix flake metadata --json "git+file://$R3?ref=wave6&rev=$W6" 2> /dev/null | jq -r '.locked.narHash // empty')
[[ -n $EVOK1 && -n $E2611 && -n $EVIN && -n $EVDEP && -n $EVOFF && -n $EVW6 && $NH1 == sha256-* && $NHK == sha256-* && $NHW6 == sha256-* && $M1 != "$K" ]] ||
  no "fixture 8: M1=$M1 K=$K W5=$W5 W6=$W6 evok=$EVOK1 ev2611=$E2611 evoff=$EVOFF evw6=$EVW6 NH1=$NH1 NHW6=$NHW6"
r8() { typeset s= a; for a; do s="$s${s:+,}$(row ${a%%:*} ${a#*:} nixpkgs)"; done; print "{\"rows\":[$s]}"; }	# r8 pname:target...
# tk8 [VAR=value...]: one tick, eval on (BUILDER_EVAL=1, publish on), against the fake queue, the fixture cache and Repo3's main
tk8() { : > "$W/fk/log"; : > "$W/fk/sublog"; out=$(env BUILDER_PATH="$W/vp:$W/fk:$PATH" FKREAL=$RC FKLOG=$W/fk/log FKROWS=$W/p8.json FKW=$W FKGP=$GP \
  BUILDER_API=http://queue.invalid/q BUILDER_RECIPES=$HC/registry/recipes.tsv BUILDER_CACHE=$HC BUILDER_CACHE_KEY="$(<"$W/pk")" BUILDER_FLAKE="git+file://$R3?ref=main" \
  BUILDER_LOAD_MAX=1000 BUILDER_PUBLISH=1 BUILDER_EVAL=1 BUILDER_PUBLISH_KEY=$W/hostkey BUILDER_AGENT=qbhost BUILDER_GATES=$W/gates BUILDER_PYTHON=$GP \
  BUILDER_SUBMIT=$W/fk/submit GATE_PYTHON=$GP GATE_GREP_DIR=$GG GATE_CACHE=$HC GATE_RECIPES= BUILDER_VERIFY_WAIT=1 BUILDER_PUBLISH_POLL=5 BUILDER_STATE=$W/st8 \
  "$@" ksh93 "$S" once 2>&1); c=$(<"$W/fk/log"); sl=$(<"$W/fk/sublog"); }
b8() { print -r -- "$sl" | grep -c "^BEGIN .*-$1-"; }	# /begin count for an out named *-<n>-*
body8() { print -r -- "$sl" | grep '^BODY ' | grep -e "-$1-" | grep -c "\"eval\":{\"attr\":\"$2\",\"system\":\"x86_64-solaris\",\"commit\":\"$3\",\"branch\":\"$4\",\"flake_nar_hash\":\"$5\"}"; }
cm8() { print -r -- "$c" | grep '/complete' | grep "\"store_path\":\"$1\"" | grep -c "\"commit\":\"$2\""; }
# serve evclodep (a host-PATH input, published): --closure must judge it anyway
nix build --no-link "git+file://$R3?ref=main&rev=$M1#packages.x86_64-solaris.evindep" >> "$W/fixture.log" 2>&1
ECD=$(nix eval --raw "git+file://$R3?ref=main&rev=$M1#packages.x86_64-solaris.evclo.drvPath" 2> /dev/null)
ECDEP=$(nix-store -q --references "$ECD" 2> /dev/null | grep 'qb-evclodep-.*\.drv$')	# a .drv's references include its input drvs
nix build --no-link "$ECDEP^out" >> "$W/fixture.log" 2>&1 && ECO=$(nix-store -q --outputs "$ECDEP") && nix copy --to "file://$W/hc" "$ECO" >> "$W/fixture.log" 2>&1 &&
  ( export XDG_CACHE_HOME=$W/fkst/x8; nix store sign --store "file://$W/hc" --key-file "$W/sk" "$ECO" ) >> "$W/fixture.log" 2>&1 || no "fixture 8: serve evclodep ($ECDEP)"
# tick D: BUILDER_EVAL=dry, bearer present: the attr-only jobs take the eval path up to /begin, nothing begun or claimed
print x > "$W/bearer"; r8 evok:1 ev2611:1 evin:1 evclo:1 evver:2 gate:0.65.0 pkg-config:2.3.0 evoff:1 evw6:1 > "$W/p8.json"
tk8 BUILDER_EVAL=dry BUILDER_STATE=$W/st8d; print -r -- "$out" | sed 's/^/   8 /'; P8=$(<"$W/st8d/plan"); print -r -- "$P8" | sed 's/^/   p /'
[[ $(print -r -- "$sl" | grep -c BEGIN) == 0 && $(claims) == 0 ]] && ok "eval dry: nothing begun, nothing claimed (bearer present)" || no "eval dry begun/claimed: $sl"
dsub() { cat "$W/st8d/tried/"*-$1-*.submit 2> /dev/null; }
print -r -- "$P8" | grep -qx "evok EVAL evok 1 main $M1" && has 'dry run: would submit .*qb-evok-' &&
  dsub evok | grep '^  begin body ' | grep -q "\"eval\":{\"attr\":\"evok\",\"system\":\"x86_64-solaris\",\"commit\":\"$M1\",\"branch\":\"main\",\"flake_nar_hash\":\"$NH1\"}" &&
  grep -q "drv-closure${T}eval:evok:x86_64-solaris:$M1:main" "$W/st8d/stamps/"*.ok &&
  ok "an attr-only job (no served row) takes the eval path: EVAL at main's head, pre-submit --eval stamp (drv-closure), /begin body with the eval object + flake narHash" ||
  no "evok dry: $(print -r -- "$out" | grep evok) $(dsub evok | tail -5)"
print -r -- "$P8" | grep -qx "ev2611 EVAL ev2611 1 26.11 $K" && dsub ev2611 | grep '^  begin body ' | grep -q "\"commit\":\"$K\",\"branch\":\"26.11\",\"flake_nar_hash\":\"$NHK\"" &&
  ok "an attr only on 26.11 (no pname/version attrs: parseDrvName): EVAL at 26.11's head, branch 26.11 in the body" || no "ev2611: $(print -r -- "$P8" | grep ev2611) $(dsub ev2611 | grep 'begin body')"
has "evin: eval evin waits for non-FOD inputs to be published first: .*qb-evindep-" && ! ls "$W/st8d/tried/" 2> /dev/null | grep -q 'qb-evin-.*\.pub$' &&
  ok "NEG an unpublished non-FOD input: the eval job waits (deps first on the drv graph), nothing built, not memo'd" || no "evin: $(print -r -- "$out" | grep evin)"
has "decline evclo: drv-gate --closure FAILs .*qb-evclo-.* \([0-9]+ findings, first: FAIL A1-path .*qb-evclodep-" && ! ls "$W/st8d/tried/" 2> /dev/null | grep -q 'qb-evclo-' &&
  ok "NEG --closure (strict): a served host-PATH input fails the eval job before any build" || no "evclo: $(print -r -- "$out" | grep evclo)"
print -r -- "$P8" | grep -qx 'gate NO-RECIPE gate 0.65.0 (packages.gate at main is illumos-gate-proto 0.65.0: not this job)' &&
  print -r -- "$P8" | grep -qx 'pkg-config NO-RECIPE pkg-config 2.3.0 (packages.pkg-config at main is pkgconf 2.3.0: not this job)' &&
  ok "NEG identity: gate -> illumos-gate-proto and pkg-config -> pkgconf (versions equal, pnames differ): NO-RECIPE, never an eval job" || no "identity: $P8"
print -r -- "$P8" | grep -qx 'evver NO-RECIPE evver 2 (packages.evver at main is evver 1: not this job)' &&
  ok "NEG identity: the attr's version is not the job's target: NO-RECIPE" || no "evver: $(print -r -- "$P8" | grep evver)"
print -r -- "$P8" | grep -qx 'evoff NO-RECIPE evoff 1' && ! print -r -- "$sl" | grep -q 'qb-evoff-' &&
  ok "NEG an attr that evaluates on no allowed branch (only wave5): NO-RECIPE, never built" || no "evoff: $(print -r -- "$P8" | grep evoff)"
print -r -- "$P8" | grep -qx 'evw6 NO-RECIPE evw6 1' && ! print -r -- "$sl" | grep -q 'qb-evw6-' &&
  ok "NEG an attr only on wave6, BUILDER_EVAL_BRANCHES the default (main 26.11): NO-RECIPE, never built" || no "evw6 default: $(print -r -- "$P8" | grep evw6)"
# pre-submit-check.sh --eval on its own (the gate layer, not only the builder's pre-checks)
ps8() { ( export GATE_STAMP_DIR=$W/st8ps GATE_PYTHON=$GP GATE_GREP_DIR=$GG GATE_CACHE=$HC GATE_FLAKE="git+file://$R3?ref=main"; bash "$W/gates/scripts/pre-submit-check.sh" "$@" ) 2>&1; }
nix build --no-link "git+file://$R3?ref=main&rev=$M1#packages.x86_64-solaris.evin" >> "$W/fixture.log" 2>&1
o8=$(ps8 --eval evin x86_64-solaris "$M1" main "$EVIN"); r=$?
(( r == 1 )) && print -r -- "$o8" | grep -q "^  inputs: FAIL (not published: .*qb-evindep-" && print -r -- "$o8" | grep -q '^  eval: PASS' && ! ls "$W/st8ps" 2> /dev/null | grep -q . &&
  ok "NEG pre-submit --eval: an unpublished non-FOD input FAILs step inputs, no stamp" || no "pre-submit inputs: rc=$r $o8"
EVOFFM=$(pe8 main "$W5" evoff); o8=$(ps8 --eval evoff x86_64-solaris "$W5" main "$EVOFF"); r=$?
(( r == 1 )) && print -r -- "$o8" | grep -q "is not on main" &&
  ok "NEG pre-submit --eval: an off-branch commit FAILs the anchor (nix itself evaluates ?ref=main&rev=<wave5 commit> to ${EVOFFM:-nothing}$([[ $EVOFFM == "$EVOFF" ]] && print ': the same out'))" || no "pre-submit off-branch: rc=$r EVOFFM=$EVOFFM $o8"
o8=$(ps8 --eval evoff x86_64-solaris "$W5" wave5 "$EVOFF"); r=$?
(( r == 2 )) && print -r -- "$o8" | grep -q "not main, 26.11 or wave6" && ok "NEG pre-submit --eval: branch wave5 refused (allow-list main, 26.11, wave6)" || no "pre-submit wave5: rc=$r $o8"
o8=$(ps8 --eval evok x86_64-solaris "$M1" main "$(po7 pubok)"); r=$?
(( r == 1 )) && print -r -- "$o8" | grep -q '^  eval: FAIL (a served row names this out' && ok "NEG pre-submit --eval of an out a served row names: FAIL (it goes --leaf)" || no "pre-submit rowed: rc=$r $o8"
o8=$("$GP" "$W/gates/scripts/cs-fixture.py" --eval evoff x86_64-solaris "$W5" wave5 --cache-dir "$W/hc" 2>&1); r=$?
(( r != 0 )) && print -r -- "$o8" | grep -q "branch 'wave5' is not one of main, 26.11, wave6" && ok "NEG cache-submit.py --eval: branch wave5 refused" || no "cache-submit wave5: $o8"
# tick E: publish + eval on. evindep is served now, so evin goes too. Each is proposed with its eval object; nothing is claimed.
nix copy --to "file://$W/hc" "$EVDEP" >> "$W/fixture.log" 2>&1 && ( export XDG_CACHE_HOME=$W/fkst/x9; nix store sign --store "file://$W/hc" --key-file "$W/sk" "$EVDEP" ) >> "$W/fixture.log" 2>&1
r8 evok:1 evin:1 ev2611:1 > "$W/p8.json"; tk8; print -r -- "$out" | sed 's/^/   E /'; print -r -- "$sl" | grep -v '^BODY' | sed 's/^/   s /'
NHI=$NH1; [[ $(b8 evok) == 1 && $(b8 evin) == 1 && $(b8 ev2611) == 1 ]] && [[ $(body8 evok evok "$M1" main "$NH1") == 1 && $(body8 evin evin "$M1" main "$NHI") == 1 && $(body8 ev2611 ev2611 "$K" 26.11 "$NHK") == 1 ]] &&
  ok "eval on: evok, evin (input now published) and ev2611 begun once each, /begin carries {attr, system, commit, branch, flake_nar_hash}" || no "tick E: $(print -r -- "$sl" | grep -E 'BEGIN|BODY')"
[[ $(claims) == 0 ]] && has 'evok: .* is proposed .*waiting for review' && [[ $(<"$W/st8/pub/eval.evok") == "evok${T}main${T}$M1" ]] &&
  ok "an eval submission is always a proposal: no claim, pinned to its commit (pub/eval.evok)" || no "tick E proposal: $(print -r -- "$out" | grep evok)"
# tick F: main moves (evok's out changes at M2), the proposal is approved: polled at M1, verified, claimed and completed with M1
pf8 M2; g3 commit -m M2; M2=$(git -C "$R3" rev-parse HEAD); EVOK2=$(pe8 main "$M2" evok); : > "$W/fk/approve"
r8 evok:1 > "$W/p8.json"; tk8; print -r -- "$out" | sed 's/^/   F /'
[[ -n $EVOK2 && $EVOK2 != "$EVOK1" && ! -e $EVOK2 ]] && [[ $(b8 evok) == 0 && $(print -r -- "$sl" | grep -c 'status=sid-evok') == 1 ]] && has "evok: published .*qb-evok-.*an 8UNr-only client verified it" &&
  [[ $(nc evok) == 1 && $(cm8 "$EVOK1" "$M1") == 1 && ! -e $W/st8/pub/eval.evok ]] &&
  ok "main moved past the proposal: polled at its own commit (never the head's new out), promoted, verified, claimed, completed with commit $M1" || no "tick F: $(print -r -- "$out" | grep evok) $sl $c"
rm -f "$W/fk/approve"
# NEG controls on fresh state, none of which may reach /begin. ev2611 has a pending proposal in st8, so fresh dirs here.
r8 evok:1 > "$W/p8.json"
tk8 BUILDER_EVAL=0 BUILDER_STATE=$W/st8z
[[ $(print -r -- "$sl" | grep -c BEGIN) == 0 && $(claims) == 0 ]] && grep -qx 'evok NO-RECIPE evok 1' "$W/st8z/plan" &&
  ok "NEG BUILDER_EVAL=0 (the default): an attr-only job is NO-RECIPE as before, nothing submitted" || no "eval 0: $(<"$W/st8z/plan") $sl"
tk8 BUILDER_EVAL=dry BUILDER_EVAL_BRANCHES="wave5 main" BUILDER_STATE=$W/st8w; r=$(<"$W/st8w/plan")
has 'eval: branch wave5 is not main, 26.11 or wave6: never evaluated' && print -r -- "$r" | grep -qx "evok EVAL evok 1 main $M2" &&
  ok "NEG BUILDER_EVAL_BRANCHES naming wave5: wave5 is never evaluated (the allow-list is in the script, not only the option)" || no "branches wave5: $r $(print -r -- "$out" | grep 'eval:')"
# an off-branch commit reaching the job (a pin naming main and a wave5 commit): refused before any build or eval of it
r8 evoff:1 > "$W/p8.json"; mkdir -p "$W/st8o/pub"; printf 'evoff\tmain\t%s\n' "$W5" > "$W/st8o/pub/eval.evoff"
tk8 BUILDER_STATE=$W/st8o
[[ $(print -r -- "$sl" | grep -c BEGIN) == 0 && $(claims) == 0 ]] && has "decline evoff: $W5 is not on main here" && [[ ! -e $EVOFF ]] &&
  ok "NEG an off-branch commit (wave5's, named as main): declined, nothing built or submitted" || no "off-branch pin: $(print -r -- "$out" | grep evoff) $sl"
# fleet7: wave6 (infra's allow-list: main, 26.11, wave6) only when the host lists it; wave5 never, listed or not (onbranch)
mkdir -p "$W/st8o5/pub"; printf 'evoff\twave5\t%s\n' "$W5" > "$W/st8o5/pub/eval.evoff"; tk8 BUILDER_EVAL_BRANCHES="main 26.11 wave5" BUILDER_STATE=$W/st8o5
[[ $(print -r -- "$sl" | grep -c BEGIN) == 0 && $(claims) == 0 ]] && has "decline evoff: $W5 is not on wave5 here" && [[ ! -e $EVOFF ]] &&
  ok "NEG a wave5 commit pinned at wave5, BUILDER_EVAL_BRANCHES listing wave5: declined (onbranch), nothing built" || no "wave5 pin: $(print -r -- "$out" | grep evoff) $sl"
r8 evw6:1 > "$W/p8.json"; mkdir -p "$W/st8p6/pub"; printf 'evw6\twave6\t%s\n' "$W6" > "$W/st8p6/pub/eval.evw6"; tk8 BUILDER_STATE=$W/st8p6
[[ $(print -r -- "$sl" | grep -c BEGIN) == 0 && $(claims) == 0 ]] && has "decline evw6: $W6 is not on wave6 here \(allowed: main 26.11\)" && [[ ! -e $EVW6 ]] &&
  ok "NEG a wave6 commit pinned at wave6, wave6 not listed (the default): declined (onbranch), nothing built" || no "wave6 unlisted pin: $(print -r -- "$out" | grep evw6) $sl"
W6B="main 26.11 wave6"; tk8 BUILDER_EVAL=dry BUILDER_EVAL_BRANCHES="$W6B" BUILDER_STATE=$W/st8w6
[[ $(print -r -- "$sl" | grep -c BEGIN) == 0 && $(claims) == 0 ]] && grep -qx "evw6 EVAL evw6 1 wave6 $W6" "$W/st8w6/plan" && has 'dry run: would submit .*qb-evw6-' &&
  cat "$W/st8w6/tried/"*-evw6-*.submit 2> /dev/null | grep '^  begin body ' | grep -q "\"eval\":{\"attr\":\"evw6\",\"system\":\"x86_64-solaris\",\"commit\":\"$W6\",\"branch\":\"wave6\",\"flake_nar_hash\":\"$NHW6\"}" &&
  grep -q "drv-closure${T}eval:evw6:x86_64-solaris:$W6:wave6" "$W/st8w6/stamps/"*.ok &&
  ok "wave6 listed: an attr only on wave6 is EVAL at wave6's head, pre-submit --eval stamps it, cache-submit plans the body with branch wave6 (dry: nothing begun)" ||
  no "wave6 listed: $(cat "$W/st8w6/plan" 2>&1) $(print -r -- "$out" | grep evw6)"
if [[ -n ${MAIN_BUILDER:-} ]]; then r8 evok:1 > "$W/p8.json"; S0=$S S=$MAIN_BUILDER; tk8 BUILDER_STATE=$W/st8old; S=$S0
  [[ $(print -r -- "$sl" | grep -c BEGIN) == 0 && $(claims) == 0 ]] && grep -q '^evok NO-RECIPE' "$W/st8old/plan" &&
    ok "NEG origin/main's builder ($MAIN_BUILDER) never takes an eval job, whatever BUILDER_EVAL says" || no "main builder eval: $(cat "$W/st8old/plan" 2>&1) $sl"
else print "SKIP origin/main eval negative control: MAIN_BUILDER unset (not counted as a pass)"; fi
# mutants: the identity rule is in two places (plan, and the job at its commit); each must hold on its own
# (python, not sed: illumos sed has no portable way to say these)
mu8() { "$GP" -c 'import sys; s = open(sys.argv[1]).read()
for a, b in zip(sys.argv[3::2], sys.argv[4::2]): assert a in s, a; s = s.replace(a, b)
open(sys.argv[2], "w").write(s)' "$@"; }
mu8 "$S" "$W/mut8a.sh" 'if ($4 == n && $5 == v) {' 'if (1) {'
mu8 "$S" "$W/mut8b.sh" 'if ($4 == n && $5 == v) {' 'if (1) {' '[[ $i == "$en $3" ]] ||' ': ||'
r8 gate:0.65.0 > "$W/p8.json"; S0=$S S=$W/mut8a.sh; tk8 BUILDER_EVAL=dry BUILDER_STATE=$W/st8ma; S=$S0
! cmp -s "$S" "$W/mut8a.sh" && grep -q "^gate EVAL gate 0.65.0 main" "$W/st8ma/plan" && has "decline gate: packages.x86_64-solaris.gate at .* is 'illumos-gate-proto 0.65.0', not gate 0.65.0" &&
  [[ $(print -r -- "$sl" | grep -c 'qb-gate-') == 0 ]] && ok "NEG mutant without the plan's identity rule: the job's own check at its commit still declines gate -> illumos-gate-proto" ||
  no "mutant a: $(cat "$W/st8ma/plan") $(print -r -- "$out" | grep gate)"
S0=$S S=$W/mut8b.sh; tk8 BUILDER_EVAL=dry BUILDER_STATE=$W/st8mb; S=$S0
! cmp -s "$W/mut8a.sh" "$W/mut8b.sh" && has 'dry run: would submit .*qb-gate-' &&
  ok "NEG control of the control: a mutant without BOTH identity checks would submit gate as illumos-gate-proto (so the checks above can fail)" || no "mutant b: $(print -r -- "$out" | grep gate)"
r8 evw6:1 > "$W/p8.json"; mu8 "$S" "$W/mut8w.sh" '[[ $2 == @(main|26.11|wave6) &&' '[[ $2 == @(main|26.11) &&'
S0=$S S=$W/mut8w.sh; tk8 BUILDER_EVAL=dry BUILDER_EVAL_BRANCHES="$W6B" BUILDER_STATE=$W/st8w6m; S=$S0
! cmp -s "$S" "$W/mut8w.sh" && grep -qx "evw6 EVAL evw6 1 wave6 $W6" "$W/st8w6m/plan" && has "decline evw6: $W6 is not on wave6 here" && ! has 'would submit .*qb-evw6-' &&
  ok "NEG mutant whose onbranch lacks wave6: the same listed tick declines evw6 (so the wave6 pass above is onbranch's)" || no "mutant w6: $(print -r -- "$out" | grep evw6)"
# fleet7: a version bump. evbump is 1 on main and 26.11 and 2 at wave6's head; the job's target is 2, the served row is at 1
# (aarch64 pcre2 10.47 served, the job 10.48, wave6 2f3d4be at 10.48). (pname, target) has no served row: the eval path.
EVB1=$(pe8 main "$M1" evbump) EVB2=$(pe8 wave6 "$W6" evbump); [[ -n $EVB1 && -n $EVB2 && $EVB1 != "$EVB2" ]] || no "fixture 8: evbump $EVB1 $EVB2"
{ print -r -- "$H"; rec evbump 1 y "$EVB1"; } > "$W/hc/registry/recipes-bump.tsv"; { cat "$W/hc/registry/recipes-bump.tsv"; rec evbump 2 y "$EVB2"; } > "$W/rbump2.tsv"
for b8 in "st8bi:$W6B" "st8bn:main 26.11"; do env BUILDER_EVAL=1 BUILDER_FLAKE="git+file://$R3?ref=main" BUILDER_EVAL_BRANCHES="${b8#*:}" BUILDER_STATE=$W/${b8%%:*} ksh93 "$S" eindex > /dev/null 2>&1; done
pb8() { env BUILDER_EVAL=1 BUILDER_STATE=$W/$1 ksh93 "${3:-$S}" plan "$W/p8.json" "$2" 2>&1; }	# pb8 <state> <recipes> [builder]
r8 evbump:2 > "$W/p8.json"
[[ $(pb8 st8bi "$W/hc/registry/recipes-bump.tsv") == "evbump EVAL evbump 2 wave6 $W6" ]] &&
  ok "version bump: evbump 1 served, the job's target 2 = wave6's head: EVAL at wave6 (an older served version does not stop it)" || no "bump: $(pb8 st8bi "$W/hc/registry/recipes-bump.tsv")"
[[ $(pb8 st8bi "$W/rbump2.tsv") == "evbump BUILD $EVB2 2 -" ]] &&
  ok "NEG a served row at the target (evbump 2): the row path (BUILD), never the eval path" || no "bump served at target: $(pb8 st8bi "$W/rbump2.tsv")"
[[ $(pb8 st8bn "$W/hc/registry/recipes-bump.tsv") == "evbump NO-RECIPE evbump 2 (packages.evbump at main is evbump 1: not this job)" ]] &&
  ok "NEG the bump with wave6 not listed: NO-RECIPE (main and 26.11 have evbump 1)" || no "bump unlisted: $(pb8 st8bn "$W/hc/registry/recipes-bump.tsv")"
tk8 BUILDER_EVAL=dry BUILDER_EVAL_BRANCHES="$W6B" BUILDER_STATE=$W/st8bd BUILDER_RECIPES=$HC/registry/recipes-bump.tsv
[[ $(print -r -- "$sl" | grep -c BEGIN) == 0 && $(claims) == 0 ]] && grep -qx "evbump EVAL evbump 2 wave6 $W6" "$W/st8bd/plan" && has 'dry run: would submit .*qb-evbump-' &&
  cat "$W/st8bd/tried/"*-evbump-*.submit 2> /dev/null | grep '^  begin body ' | grep -q "\"eval\":{\"attr\":\"evbump\",\"system\":\"x86_64-solaris\",\"commit\":\"$W6\",\"branch\":\"wave6\",\"flake_nar_hash\":\"$NHW6\"}" &&
  grep -q "^$EVB2${T}.*drv-closure${T}eval:evbump:x86_64-solaris:$W6:wave6" "$W/st8bd/stamps/"*.ok &&
  ok "version bump, a dry tick: built, pre-submit --eval stamped, the /begin body anchors wave6's evbump 2 (nothing begun or claimed)" ||
  no "bump tick: $(cat "$W/st8bd/plan" 2>&1) $(print -r -- "$out" | grep evbump)"
if [[ -n ${EV7_BUILDER:-} ]]; then
  [[ $(pb8 st8bi "$W/hc/registry/recipes-bump.tsv" "$EV7_BUILDER") == "evbump NO-RECIPE evbump 2" ]] &&
    ok "NEG c49a27f's builder ($EV7_BUILDER): the same bump is NO-RECIPE (any served row of the pname refused the eval)" ||
    no "EV7_BUILDER bump: $(pb8 st8bi "$W/hc/registry/recipes-bump.tsv" "$EV7_BUILDER")"
else print "SKIP version-bump negative control: EV7_BUILDER unset (not counted as a pass)"; fi
# the second vote: `solnix-builder vote <attr> <commit> <branch> <NarHash> [pname]` builds that (attr, commit) here and completes
# the job with its NarHash and commit, only if the NarHash is the proposal's. The proposal's NarHash: evvote's out is one file.
print -r -- "evvote-${W##*/}" > "$W/evvote.txt"; chmod 444 "$W/evvote.txt"; nix-store --dump "$W/evvote.txt" > "$W/evvote.nar"
VH=sha256:$(nix-hash --type sha256 --flat --base32 "$W/evvote.nar"); VO=$(pe8 main "$M1" evvote)
vote8() { : > "$W/fk/log"; out=$(env ${VBR:+"BUILDER_EVAL_BRANCHES=$VBR"} BUILDER_PATH="$W/fk:$PATH" FKREAL=$RC FKLOG=$W/fk/log BUILDER_API=http://queue.invalid/q BUILDER_CACHE=$HC \
  BUILDER_FLAKE="git+file://$R3?ref=main" BUILDER_AGENT=qbvoter BUILDER_EVAL=${VEVAL:-1} BUILDER_STATE=${VST:-$W/st8v} ksh93 "$S" vote "$@" 2>&1); c=$(<"$W/fk/log"); }
print x > "$W/bearer"; [[ ! -e $VO ]] || no "fixture 8: $VO exists before the vote"
vote8 evvote "$M1" main "$VH" evvote; print -r -- "$out" | sed 's/^/   V /'
[[ $(nc evvote) == 1 && $(cm8 "$VO" "$M1") == 1 ]] && print -r -- "$c" | grep '/complete' | grep -q "\"nar_hash\":\"$VH\"" && ! print -r -- "$c" | grep -q independence &&
  has 'vote evvote: building ' && has 'a different builder' &&
  ok "second vote by another host: built fresh, NarHash = the proposal's, claimed and completed done with it and commit $M1 (no independence field)" || no "vote: $out $c"
# the out was built by THIS host now: a vote here again is a same-host vote (dixa's case) and says so, after a --rebuild
VEVAL=dry vote8 evvote "$M1" main "$VH" evvote; VEVAL=1	# ksh93: VAR=x before a function call outlives the call
has 'vote evvote: rebuilding .* \(a second build dir' && has 'same-host: this host built or proposed it' && has 'dry run: BUILDER_EVAL=dry: would claim evvote 1 and complete it with commit .*independence' && [[ $(claims) == 0 ]] &&
  ok "vote dry: a second build dir (--rebuild), same-host, would complete with the commit; no claim" || no "vote dry: $out"
vote8 evvote "$M1" main "$VH" evvote
print -r -- "$c" | grep '/complete' | grep -q '"independence":"same-host"' && [[ $(cm8 "$VO" "$M1") == 1 ]] &&
  ok "same-host vote (aarch64: dixa): the completion carries independence same-host and the commit" || no "same-host vote: $out $c"
vote8 evvote "$M1" main sha256:0000000000000000000000000000000000000000000000000000 evvote
has 'the proposal says sha256:0000.*no vote' && [[ $(claims) == 0 ]] && ok "NEG vote: a NarHash other than the proposal's: no vote, no claim" || no "vote mismatch: $out"
vote8 evoff "$W5" main "$VH"
has "vote evoff: $W5 is not on main" && [[ $(claims) == 0 && ! -e $EVOFF ]] && ok "NEG vote: an off-branch commit: no vote, nothing built" || no "vote off-branch: $out"
vote8 evvote "$M1" wave5 "$VH"
has 'is not on wave5' && [[ $(claims) == 0 ]] && ok "NEG vote: branch wave5: no vote" || no "vote wave5: $out"
VH6=$(nix-store -q --hash "$EVW6" 2> /dev/null); vote8 evw6 "$W6" wave6 "$VH6" evw6
has "vote evw6: $W6 is not on wave6 \(allowed: main 26.11\): no vote" && [[ $(claims) == 0 ]] && ok "NEG vote: a wave6 commit, wave6 not listed: no vote" || no "vote wave6 unlisted: $out"
VBR=$W6B VEVAL=dry vote8 evw6 "$W6" wave6 "$VH6" evw6; VBR= VEVAL=1
[[ $VH6 == sha256:* ]] && has "dry run: BUILDER_EVAL=dry: would claim evw6 1 and complete it with commit $W6" && [[ $(claims) == 0 ]] &&
  ok "vote: a wave6 commit, wave6 listed: reproduced, would complete with commit $W6 (dry: no claim)" || no "vote wave6 listed: $out"
vote8 gate "$M1" main "$VH" gate
has 'vote gate: at .* it is illumos-gate-proto, not gate: no vote' && [[ $(claims) == 0 ]] && ok "NEG vote: the job's pname is not the attr's (gate -> illumos-gate-proto): no vote" || no "vote gate: $out"
# --- 10. fleet6: sshsig queue auth (R7), retries signed anew (R8), the egress registration (s3). Each request is checked
# by rebuilding the spec message HERE from what was sent ("<METHOD>\n<path>\n<sha256 hex of the body>\n<ts>\n", path = the
# URL's) and verifying its X-Solnix-Sig (base64 of the armored SSHSIG) with ssh-keygen -Y verify against the test key.
SK=$(whence -p ssh-keygen); rm -f "$W/qkey" "$W/qkey.pub"; ssh-keygen -q -t ed25519 -N '' -C qb-queue -f "$W/qkey" < /dev/null
print -r -- "qb $(cut -d' ' -f1,2 "$W/qkey.pub")" > "$W/qsigners"; print "{\"rows\":[$(row good 1 outdated)]}" > "$W/g9.json"
QA=http://queue.invalid/api/v1/build-queue	# the production path shape: /api/v1/build-queue/<id>/heartbeat
t9() { typeset s=$1; shift; find "$W/rq" -depth -delete 2> /dev/null; mkdir -p "$W/rq"; : > "$W/fk/log"
  out=$(env BUILDER_PATH="$W/fk:$PATH" FKREAL=$RC FKLOG=$W/fk/log FKREQ=$W/rq FKROWS=$W/g9.json BUILDER_API=$QA BUILDER_RECIPES=file://$W/g.tsv \
    BUILDER_CACHE=file://$W/cache BUILDER_FLAKE=$F BUILDER_LOAD_MAX=1000 BUILDER_STATE=$W/st9 BUILDER_PUBLISH_KEY=$W/qkey BUILDER_SSH_KEYGEN=$SK \
    BUILDER_RETRY_WAIT=1 BUILDER_AGENT=qbhost BUILDER_PUBLISH_ID=qbhost "$@" ksh93 "$s" "$t9c" 2>&1); c=$(<"$W/fk/log"); }
t9c=once
hv() { tr -d '\r' < "$1/hdr" 2> /dev/null | sed -n "s/^$2: //p"; }	# hv <request> <header>
rqs() { typeset i=0; while (( (i += 1) <= $(cat "$W/rq/n" 2> /dev/null || print 0) )); do print -r -- "$W/rq/$i"; done; }
sigok() {	# sigok <request>: its X-Solnix-Sig verifies over the spec message rebuilt from its URL path, body and X-Solnix-Timestamp
  typeset u=$(<"$1/url") ts=$(hv "$1" X-Solnix-Timestamp); [[ $ts == +([0-9]) ]] || return 1
  printf 'POST\n%s\n%s\n%s\n' "/${u#http://*/}" "$(digest -a sha256 "$1/body")" "$ts" > "$1/msg"
  hv "$1" X-Solnix-Sig | openssl base64 -d -A > "$1/sig" 2> /dev/null
  ssh-keygen -Y verify -f "$W/qsigners" -I qb -n solnix-build-queue -s "$1/sig" < "$1/msg" > /dev/null 2>&1; }
paths9() { for r in $(rqs); do u=$(<"$r/url"); u=${u#$QA}; print -n "${u#http://queue.invalid/api/v1} "; done; }
allsig() { typeset r n=0; for r in $(rqs); do sigok "$r" && [[ -z $(hv "$r" X-Solnix-Build) ]] || return 1; n=$((n + 1)); done; (( n >= 3 )); }
print BEARER-qb9 > "$W/bearer"
t9 "$S" BUILDER_QUEUE_AUTH=sshsig; print -r -- "$out" | sed 's/^/   9 /'
[[ $(paths9) == '/claim /42/heartbeat /42/complete ' ]] && allsig && has 'complete 42 -> 200' &&
  ok "sshsig: claim, heartbeat and complete each carry X-Solnix-Sig + X-Solnix-Timestamp over the spec bytes (path /api/v1/build-queue/...), no bearer" ||
  no "sshsig: $(paths9) $(for r in $(rqs); do print -n "[$(cat "$r/hdr" 2> /dev/null | cut -c1-40 | tr '\n' '|')] "; done)"
[[ $(<"$W/rq/1/body") == *'"pnames":["good"]'* ]] && ! grep -q BEARER-qb9 "$W"/rq/*/hdr && ok "sshsig: the bearer file is never read (its value is in no request)" || no "sshsig sent the bearer"
mu8 "$S" "$W/mut9m.sh" "qs=\$(printf '%s\\n%s\\n%s\\n%s\\n'" "qs=\$(printf '%s\\n%s\\n%s\\n%s'"
t9 "$W/mut9m.sh" BUILDER_QUEUE_AUTH=sshsig
! allsig && [[ -n $(hv "$W/rq/1" X-Solnix-Sig) ]] && ok "NEG mutant signing the message without its final newline: refused by the check (the check sees the bytes)" || no "mutant message passed"
rm -f "$W/bearer"; t9 "$S" BUILDER_QUEUE_AUTH=sshsig
[[ $(paths9) == '/claim /42/heartbeat /42/complete ' ]] && allsig && ok "sshsig with no bearer file at all: the key is the credential, claimed and completed" || no "sshsig no bearer: $(paths9)"
t9 "$S" BUILDER_QUEUE_AUTH=sshsig BUILDER_PUBLISH_KEY=$W/nokey
[[ ! -e $W/rq/n ]] && has 'dry run: no .*nokey' && ok "NEG sshsig, key unreadable: a dry run, nothing sent" || no "sshsig no key: $(paths9) $(print -r -- "$out" | grep -i 'dry run' | head -2)"
print BEARER-qb9 > "$W/bearer"; t9 "$S" BUILDER_QUEUE_AUTH=bearer
[[ $(paths9) == '/claim /42/heartbeat /42/complete ' && $(hv "$W/rq/2" X-Solnix-Build) == BEARER-qb9 ]] && ! egrep -qi 'X-Solnix-(Sig|Timestamp)' "$W"/rq/*/hdr &&
  ok "bearer: X-Solnix-Build on each request, no X-Solnix-Sig or X-Solnix-Timestamp" || no "bearer: $(cat "$W"/rq/*/hdr 2> /dev/null | cut -c1-30 | tr '\n' '|')"
t9 "$S"; [[ $(hv "$W/rq/1" X-Solnix-Build) == BEARER-qb9 && -z $(hv "$W/rq/1" X-Solnix-Sig) ]] && ok "the default (no BUILDER_QUEUE_AUTH): bearer, as before" || no "default auth"
t9 "$S" BUILDER_QUEUE_AUTH=both; n=0; for r in $(rqs); do sigok "$r" && [[ $(hv "$r" X-Solnix-Build) == BEARER-qb9 ]] && n=$((n + 1)); done
(( n == 3 )) && ok "both (the control for the two checks above): each request has the bearer AND a valid signature" || no "both: $n of 3"
# R8: a heartbeat answered 503 is retried with a new X-Solnix-Timestamp, so a new signature (ed25519 is deterministic: the
# same message gives the same bytes, which infra refuses as a replay); a mutant that keeps the ts resends the same bytes
rt9() { : > "$W/fail9"; t9 "$1" BUILDER_QUEUE_AUTH=sshsig FKFAIL=$W/fail9; h1=$W/rq/2 h2=$W/rq/3; }
rt9 "$S"; print -r -- "$out" | grep -E 'heartbeat|retry' | sed 's/^/   R /'
[[ $(paths9) == '/claim /42/heartbeat /42/heartbeat /42/complete ' ]] && sigok "$h1" && sigok "$h2" && (( $(hv "$h2" X-Solnix-Timestamp) > $(hv "$h1" X-Solnix-Timestamp) )) &&
  [[ $(hv "$h1" X-Solnix-Sig) != "$(hv "$h2" X-Solnix-Sig)" ]] && has 'queue POST /42/heartbeat -> 503: retry 1 in 1 s, signed anew' && has 'heartbeat 42 -> 200' &&
  ok "R8: a 503 heartbeat is retried signed anew: a later ts and another signature, both valid" || no "retry: $(paths9) $(print -r -- "$out" | grep -E 'retry|heartbeat')"
mu8 "$S" "$W/mut9t.sh" 'while aqs=$(printf '"'%(%s)T'"' now); (( aqs <= aqt )); do sleep 1; done; aqt=$aqs' '(( aqt )) || aqt=$(printf '"'%(%s)T'"' now)'
rt9 "$W/mut9t.sh"
[[ $(paths9) == '/claim /42/heartbeat /42/heartbeat /42/complete ' && $(hv "$h1" X-Solnix-Sig) == "$(hv "$h2" X-Solnix-Sig)" ]] && cmp -s "$h1/hdr" "$h2/hdr" &&
  ok "NEG mutant keeping the ts: the retry is byte-identical to the first try (the replay R8 refuses), so the check above can fail" || no "mutant ts: $(paths9)"
if [[ -n ${PRESIG_BUILDER:-} ]]; then t9 "$PRESIG_BUILDER" BUILDER_QUEUE_AUTH=sshsig
  ! allsig && grep -q BEARER-qb9 "$W/rq/1/hdr" && ok "NEG a builder before this change ($PRESIG_BUILDER), asked for sshsig: bearer only, no signature (fails the check)" || no "presig builder passed"
else print "SKIP sshsig negative control: PRESIG_BUILDER unset (not counted as a pass)"; fi
# s3 egress: exactly six keys; sig = armored SSHSIG (namespace solnix-builder) over the four lines; the first try's ip is
# TEST-NET-1, a 400 gives `seen`, re-signed once; the address is kept for the next run; a failure never fails the builder
egok() {	# egok <request> <ip>: six keys, the values, and the signature over the four-line message
  typeset b=$1/body ts; [[ $(jq -c 'keys' "$b") == '["ip","keyid","kind","sig","ts","version"]' ]] || return 1
  [[ $(jq -r '[.version, .kind, .keyid, .ip, (.ts|type)] | join(" ")' "$b") == "1 builder_egress qbhost $2 number" ]] || return 1
  ts=$(jq -r .ts "$b"); jq -j .sig "$b" > "$1/sig"; [[ $(head -1 "$1/sig") == '-----BEGIN SSH SIGNATURE-----' ]] || return 1
  printf 'solnix-builder-egress-v1\n%s\n%s\n%s\n' qbhost "$2" "$ts" | ssh-keygen -Y verify -f "$W/qsigners" -I qb -n solnix-builder -s "$1/sig" > /dev/null 2>&1; }
e9() { typeset r; t9c=egress; t9 "$1" BUILDER_EGRESS=1 BUILDER_STATE=$W/st9e "${@:2}"; r=$?; t9c=once; return $r; }
mkdir -p "$W/st9e"; e9 "$S"; r=$?; print -r -- "$out" | sed 's/^/   E /'
(( r == 0 )) && [[ $(paths9) == '/builder/egress /builder/egress ' ]] && egok "$W/rq/1" 192.0.2.1 && egok "$W/rq/2" 198.51.100.7 &&
  [[ $(cut -d' ' -f2 "$W/st9e/egress") == 198.51.100.7 ]] && has 'egress: qbhost 198.51.100.7 -> 200 .*"registered"' &&
  ok "egress: six keys, signed over the four lines; 192.0.2.1 -> 400 seen 198.51.100.7 -> signed anew -> 200 registered, logged and kept" || no "egress: $(paths9) $out"
e9 "$S"; [[ $(paths9) == '/builder/egress ' ]] && egok "$W/rq/1" 198.51.100.7 && ok "egress again: the kept address first, one request" || no "egress 2: $(paths9)"
e9 "$S" FKE500=1; r=$?; (( r == 0 )) && has 'egress: qbhost 198.51.100.7 -> 500' && [[ $(paths9) == '/builder/egress ' ]] && ok "egress answered 500: logged, rc 0 (never fails the builder)" || no "egress 500: rc $r $out"
e9 "$S" BUILDER_EGRESS=0; [[ ! -e $W/rq/n ]] && ok "NEG BUILDER_EGRESS=0 (not an identified builder): nothing sent" || no "egress off sent $(paths9)"
mu8 "$S" "$W/mut9e.sh" 'ts: $ts, sig: $sig}' 'ts: $ts, sig: $sig, agent: "x"}'
e9 "$W/mut9e.sh"; ! egok "$W/rq/1" 198.51.100.7 && [[ $(jq 'keys | length' "$W/rq/1/body") == 7 ]] && ok "NEG mutant with a seventh key: the six-key check fails" || no "mutant egress passed"
grep -q 'egress; egl=' "$S" && ok "the SMF loop registers egress at start and every BUILDER_EGRESS_SECS" || no "no egress in the loop"
rm -f "$W/bearer"
# --- 9. fleet5: a job listing several outputs of one drv (gcc 15.3.0: out and -lib; wave6: out and -debug). Each unserved one
# is first-published as its own submission, deps first; the job is claimed once every listed out is served, and completed once
# with the primary (the default output). Shapes: mlib out -> lib (gcc); mdev out -> lib, dev -> out (a later pass); mdbg out +
# a -debug with no refs; mserv -lib served already; mpri out served already; mrej -lib fails the gate (S4 names a host);
# msib -debug served from ANOTHER build (another NarHash); mprop -lib proposed (tier 1), approved on the next tick.
mkdir -p "$W/mflake"; cat > "$W/mflake/flake.nix" <<MF
{ outputs = { self }: let
    m = n: o: s: derivation { name = "qb-\${n}-${W##*/}"; system = "x86_64-solaris"; builder = "/usr/bin/bash"; outputs = o;
      args = [ "-c" "echo building \${n}; \${s}" ]; };
    T = "${W##*/}";
  in { packages.x86_64-solaris = {
    mlib = m "mlib" [ "out" "lib" ] "echo mlib-lib-\${T} > \$lib; echo \$lib > \$out";
    mdev = m "mdev" [ "out" "lib" "dev" ] "echo mdev-lib-\${T} > \$lib; echo \$lib > \$out; echo \$out > \$dev";
    mdbg = m "mdbg" [ "out" "debug" ] "echo mdbg-\${T} > \$out; echo mdbg-debug-\${T} > \$debug";
    mserv = m "mserv" [ "out" "lib" ] "echo mserv-lib-\${T} > \$lib; echo \$lib > \$out";
    mpri = m "mpri" [ "out" "lib" ] "echo mpri-\${T} > \$out; echo mpri-lib-\${T} > \$lib";
    mrej = m "mrej" [ "out" "lib" ] "echo mrej-lib-\${T} built on floki > \$lib; echo \$lib > \$out";
    msib = m "msib" [ "out" "debug" ] "echo msib-\${T} > \$out; echo msib-debug-\${T} > \$debug";
    mprop = m "mprop" [ "out" "lib" ] "echo mprop-lib-\${T} > \$lib; echo \$lib > \$out";
  }; }; }
MF
MFL=path:$W/mflake; M9="mlib mdev mdbg mserv mpri mrej msib mprop"
nix eval --json "$MFL#packages.x86_64-solaris" --apply 'builtins.mapAttrs (n: d: builtins.listToAttrs (map (o: { name = o; value = d.${o}.outPath; }) d.outputs))' > "$W/mouts.json" 2> "$W/meval.err" ||
  no "fixture 9: $(tail -3 "$W/meval.err")"
mo9() { jq -r --arg a "$1" --arg o "${2:-out}" '.[$a][$o]' "$W/mouts.json"; }
for a in $M9; do for x in $(jq -r --arg a "$a" '.[$a] | keys[]' "$W/mouts.json"); do rec $a 1 y "$(mo9 $a $x)"; done; done >> "$W/p.tsv"
cp "$W/p.tsv" "$W/hc/registry/recipes.tsv"
ML=$(mo9 mlib lib) MO9=$(mo9 mlib) DL=$(mo9 mdev lib) DO=$(mo9 mdev) DD=$(mo9 mdev dev) GO=$(mo9 mdbg) GD=$(mo9 mdbg debug) SL=$(mo9 mserv lib) SO=$(mo9 mserv)
PL=$(mo9 mpri lib) PO=$(mo9 mpri) RL=$(mo9 mrej lib) RO=$(mo9 mrej) IO=$(mo9 msib) ID=$(mo9 msib debug) QL=$(mo9 mprop lib) QO=$(mo9 mprop)
# served by someone else before any tick: mserv's -lib and mpri's out (signed as published); msib's -debug with another NarHash
nix build --no-link "$MFL#packages.x86_64-solaris.mserv^*" "$MFL#packages.x86_64-solaris.mpri^*" >> "$W/fixture.log" 2>&1 &&
  nix copy --to "file://$W/hc" "$SL" "$PO" >> "$W/fixture.log" 2>&1 &&
  ( export XDG_CACHE_HOME=$W/fkst/x9; nix store sign --store "file://$W/hc" --key-file "$W/sk" "$SL" "$PO" ) >> "$W/fixture.log" 2>&1 &&
  [[ $DD == *-qb-mdev-*-dev && $ML == *-qb-mlib-*-lib && -n $(sv7 "$SL") && -n $(sv7 "$PO") ]] || no "fixture 9: ML=$ML DD=$DD $(tail -2 "$W/fixture.log")"
printf 'StorePath: %s\nNarHash: sha256:%s\n' "$ID" 0000000000000000000000000000000000000000000000000000 > "$W/hc/$(print -r -- "${ID#/nix/store/}" | cut -c1-32).narinfo"
bg9() { print -r -- "$sl" | grep -c "^BEGIN $1 "; }	# /begin count for exactly that path
ln9() { print -r -- "$sl" | grep -n "^BEGIN $1 " | head -1 | cut -d: -f1; }	# its /begin's line in the submitter log
dn9() { print -r -- "$c" | grep '/complete' | grep -c "\"status\":\"done\",\"version\":\"1\",\"nar_hash\":\"$(sv7 "$1")\",\"store_path\":\"$1\""; }
tk9() { tk7 FKROWS=$W/p9.json BUILDER_FLAKE=$MFL BUILDER_STATE=$W/st9 "$@"; }
print x > "$W/bearer"
# NEG control: origin/main's builder on the gcc shape picks out, builds, waits for -lib every tick, never offers -lib
if [[ -n ${F5_BUILDER:-} ]]; then S0=$S S=$F5_BUILDER; w9="mlib: $MO9 waits for its references to be served first: ${ML#/nix/store/}"
  r7 mlib > "$W/p9.json"; tk9 BUILDER_STATE=$W/st9o; o1=$out s1=$sl c1=$(claims); tk9 BUILDER_STATE=$W/st9o; o2=$out s2=$sl c2=$(claims)
  r7 mpri > "$W/p9.json"; tk9 BUILDER_STATE=$W/st9p BUILDER_PUBLISH=0; c3=$(cl7 mpri); S=$S0
  print -r -- "$o2" | grep ' mlib' | sed 's/^/   9o /'
  [[ $(print -r -- "$o1" | grep -cF "$w9") == 1 && $(print -r -- "$o2" | grep -cF "$w9") == 1 && -z $s1$s2 && $c1 == 0 && $c2 == 0 ]] &&
    ok "NEG origin/main's builder ($F5_BUILDER) loops on the gcc shape: each tick builds out and waits for -lib, never submits -lib, never claims" ||
    no "F5_BUILDER mlib: $(print -r -- "$o1" "$o2" | grep ' mlib') $s1 $s2"
  (( c3 == 1 )) && ok "NEG origin/main's builder without a publish key claims mpri though its -lib is unserved (the gap: infra claims once every listed out is served)" || no "F5_BUILDER mpri: $c3 claims"
else print "SKIP origin/main multi-output negative control: F5_BUILDER unset (not counted as a pass)"; fi
r7 mpri mlib > "$W/p9.json"; tk9 BUILDER_STATE=$W/st9z BUILDER_PUBLISH=0
[[ -z $sl && $(claims) == 0 ]] && has "decline mpri: $PO is served, its sibling output\(s\) ${PL#/nix/store/} not" && has "decline mlib: $MO9 is not served \(a first build" &&
  ok "NEG a host that may not publish declines a job whose drv has a listed out unserved (mpri: out served, -lib not): no claim" || no "publish 0: $(print -r -- "$out" | grep -E ' (mpri|mlib)') $sl"
r7 $M9 > "$W/p9.json"; tk9; print -r -- "$out" | sed 's/^/   9 /'; print -r -- "$sl" | grep -v '^BODY' | sed 's/^/   s /'
[[ $(bg9 "$ML") == 1 && $(bg9 "$MO9") == 1 ]] && (( $(ln9 "$ML") < $(ln9 "$MO9") )) && [[ $(cl7 mlib) == 1 && $(dn9 "$MO9") == 1 ]] &&
  ok "the gcc shape (out references -lib): -lib submitted first, then out, then one claim" || no "mlib: $(print -r -- "$out" | grep ' mlib')"
[[ $(bg9 "$DL") == 1 && $(bg9 "$DO") == 1 && $(bg9 "$DD") == 1 ]] && (( $(ln9 "$DL") < $(ln9 "$DO") && $(ln9 "$DO") < $(ln9 "$DD") )) &&
  has "mdev: $DD waits for its references to be served first: ${DO#/nix/store/}" && [[ $(cl7 mdev) == 1 && $(dn9 "$DO") == 1 ]] &&
  ok "three outputs (dev -> out -> lib): dev waits in the first pass, lib then out go, then dev in a later pass of the same tick; one claim" || no "mdev: $(print -r -- "$out" | grep ' mdev')"
[[ $(bg9 "$GD") == 1 && $(bg9 "$GO") == 1 && $(cl7 mdbg) == 1 && $(dn9 "$GO") == 1 ]] && ok "out + a -debug that references nothing: both published, one claim" || no "mdbg: $(print -r -- "$out" | grep ' mdbg')"
[[ $(bg9 "$SL") == 0 && $(bg9 "$SO") == 1 && $(cl7 mserv) == 1 && $(dn9 "$SO") == 1 ]] && ! print -r -- "$sl" | grep -q "paths=$SL" &&
  ok "-lib already served by someone else: only out is submitted, one claim" || no "mserv: $(print -r -- "$out" | grep ' mserv')"
[[ $(bg9 "$PL") == 1 && $(bg9 "$PO") == 0 && $(cl7 mpri) == 1 && $(dn9 "$PO") == 1 ]] && ! print -r -- "$sl" | grep -q "paths=$PO" &&
  ok "out already served by someone else: only -lib is submitted, then one claim" || no "mpri: $(print -r -- "$out" | grep ' mpri')"
! print -r -- "$c" | grep '/complete' | egrep -q '"store_path":"[^"]*-(lib|debug|dev)"' && [[ $(dn9 "$MO9") == 1 && $(dn9 "$DO") == 1 && $(dn9 "$PO") == 1 ]] && (( $(ln9 "$ML") < $(ln9 "$MO9") )) &&
  ok "each completion names the primary (out) and its served NarHash, though -lib was published first (mlib), dev last (mdev), out not at all (mpri)" || no "primary: $(print -r -- "$c" | grep '/complete')"
[[ $(bg9 "$RL") == 0 && $(bg9 "$RO") == 0 && $(cl7 mrej) == 0 ]] && ! print -r -- "$sl" | grep -q "paths=$RO" && has 'decline mrej: pre-submit-check.sh --leaf .*-lib rc=1 \([a-z,]*gate' &&
  ls "$W/st9/tried/" | grep -q 'qb-mrej-.*\.drv\^lib\.pub$' && ok "NEG a sibling refused at the gate (-lib names a host): the job declines, out is never offered, no claim" || no "mrej: $(print -r -- "$out" | grep ' mrej')"
[[ -z $(print -r -- "$sl" | grep 'qb-msib-') && $(cl7 msib) == 0 ]] && has "decline msib: cache.solnix.io serves its sibling $ID with sha256:0{52}, this host built sha256:" &&
  ls "$W/st9/tried/" | grep -q 'qb-msib-.*\.drv\^out\.pub$' && ok "NEG a served sibling of another build (-debug, another NarHash): out is never submitted, memo'd, no claim" || no "msib: $(print -r -- "$out" | grep ' msib')"
[[ $(bg9 "$QL") == 1 && $(bg9 "$QO") == 0 && $(cl7 mprop) == 0 && -s $W/st9/pub/${QL##*/} ]] && has "mprop: $QL is proposed \(sid-mprop-lib\)" &&
  has "mprop: $QO waits for its references to be served first: ${QL#/nix/store/}" && ok "tier 1: -lib proposed, out waits for it (not submitted), no claim, the proposal kept" || no "mprop: $(print -r -- "$out" | grep ' mprop')"
# tick 9B: the -lib proposal is approved; mrej's refusal stands
: > "$W/fk/approve"; r7 mrej mprop > "$W/p9.json"; tk9; print -r -- "$out" | sed 's/^/   9B /'; rm -f "$W/fk/approve"
[[ $(print -r -- "$sl" | grep -c 'status=sid-mprop-lib') == 1 && $(bg9 "$QL") == 0 && $(bg9 "$QO") == 1 && $(cl7 mprop) == 1 && $(dn9 "$QO") == 1 && ! -e $W/st9/pub/${QL##*/} ]] &&
  ok "the approved -lib proposal: polled by id on the next tick, then out submitted, one claim" || no "mprop B: $(print -r -- "$out" | grep ' mprop') $sl"
! has 'mrej: first build of' && has "held mrej: newest $RL refused here \(pre-submit-check" && [[ $(cl7 mrej) == 0 ]] && ! print -r -- "$sl" | grep -q 'qb-mrej-' &&
  ok "a refused sibling: the next tick declines the job before any build" || no "mrej B: $(print -r -- "$out" | grep ' mrej')"
rm -f "$W/bearer"
# --- 11. fleet8: a fixed build dir left by another build uid is the host's failure, never a memo'd refusal of the out. A first
# build leaves W=/var/tmp/srcpkg-<buildKey> 0700 as its nixbld uid; pre-submit's --check, as another uid, cannot remove it
# (dixa a64t openssl/sqlite, 2026-11-04: memo'd, 13 h blocked). The fixture's drvs use that W the way mk-src-pkg does (rm; mkdir
# -m 700; trap rm), and the `nice` wrapper plants a stale W (another uid's, 0700, holding a file) right after that drv's first
# build: inside the tick, past the tick-start sweep. BUILDER_WSWEEP is a wrapper that runs only the per-drv (keyed) sweep, so
# nothing else under this host's /var/tmp is touched. pubstale, pubsweep: GNU rm wording (store coreutils, copied into the fixture
# flake: an inputSrc, as drv-gate wants); pubheld: illumos rm wording (/usr/bin, the store's illumos-userland on solnix), and its
# owner runs a process (kept); pubstfl: a genuine DIFFERS whose log also names ANOTHER key's W (still memo'd).
if [[ $(/usr/bin/id -u) == 0 ]]; then
K11=$(printf '%04x' $RANDOM $RANDOM $RANDOM); KS=${K11}0001 KH=${K11}0002 KF=${K11}0003 KW=${K11}0004 KD=${K11}00ff
SWS=${WSWEEP:-$G/modules/config/community/solnix-wsweep.ksh} CU=${COREUTILS:-/nix/store/vfd9kp6r0f56iz8y73ab6vb0bf2d0890-coreutils-9.7}
[[ -e $CU ]] || nix-store -r "$CU" > /dev/null 2>&1
mkdir -p "$W/sflake/cu" "$W/swn" "$W/sws"; cp "$CU/bin/coreutils" "$W/sflake/cu/" && ln -s coreutils "$W/sflake/cu/rm" && ln -s coreutils "$W/sflake/cu/mkdir" || no "fixture 11: no coreutils at $CU"
cat > "$W/sflake/flake.nix" <<SF
{ outputs = { self }: let
    sw = n: k: rm: mk: body: derivation { name = "qb-\${n}-${W##*/}"; system = "x86_64-solaris"; builder = "/usr/bin/bash"; buildKey = k;
      args = [ "-c" "W=/var/tmp/srcpkg-\${k}; \${rm} -r -f \"\$W\"; \${mk} -m 700 \"\$W\" || exit 1; trap 'cd /; \${rm} -r -f \"\$W\"' EXIT; cd \"\$W\"; echo building \${n}; \${body}" ]; };
    g = n: k: sw n k "\${./cu}/rm" "\${./cu}/mkdir";
  in { packages.x86_64-solaris = {
    pubstale = g "pubstale" "$KS" "echo stale-${W##*/} > \$out";
    pubsweep = g "pubsweep" "$KW" "echo sweep-${W##*/} > \$out";
    pubheld = sw "pubheld" "$KH" "/usr/bin/rm" "/usr/bin/mkdir" "echo held-${W##*/} > \$out";
    pubstfl = g "pubstfl" "$KF" "echo \"rm: cannot remove '/var/tmp/srcpkg-$KD': Permission denied (a test prints it)\"; echo \$RANDOM\$\$ > \$out";
  }; }; }
SF
SFL=path:$W/sflake
nix eval --json "$SFL#packages.x86_64-solaris" --apply 'builtins.mapAttrs (n: d: d.outPath)' > "$W/souts.json" 2> "$W/seval.err" || no "fixture 11: $(tail -3 "$W/seval.err")"
po11() { jq -r --arg a "$1" '.[$a]' "$W/souts.json"; }
for a in pubstale pubsweep pubheld pubstfl; do rec $a 1 y "$(po11 $a)"; done >> "$W/p.tsv"; cp "$W/p.tsv" "$W/hc/registry/recipes.tsv"
# nice, as fbuild calls it for the first build: build, then (SWPLANT=1) leave the W of each SWKEYS <name>:<key> being built, as
# another build uid (SWUID) would have left it
{ print '#!/bin/sh'; print '/usr/bin/nice "$@"; r=$?'
  print '[ -n "$SWPLANT" ] && for p in $SWKEYS; do case " $* " in *-qb-${p%%:*}-*) d=/var/tmp/srcpkg-${p#*:}; [ -e "$d" ] || { /usr/bin/mkdir -m 700 "$d" && echo left > "$d/src.tar" && /usr/bin/chown -R "${SWUID:-30999}:30000" "$d"; };; esac; done'
  print 'exit $r'; } > "$W/swn/nice"; chmod +x "$W/swn/nice"
# BUILDER_WSWEEP: only the keyed call (the per-drv sweep), logged; the tick-start call (one argument) does nothing here
{ print '#!/usr/bin/ksh93'; print "[[ \$# == 2 ]] || exit 0; print -r -- \"\$*\" >> $W/sws/calls; exec /usr/bin/ksh93 $SWS \"\$@\""; } > "$W/sws/wsweep"; chmod +x "$W/sws/wsweep"
tk11() { : > "$W/sws/calls"; tk7 BUILDER_PATH="$W/swn:$W/vp:$W/fk:$PATH" FKROWS=$W/p11.json BUILDER_FLAKE=$SFL "$@"; }
m11() { ls "$1/tried/" 2> /dev/null | grep -c "qb-$2-.*\.drv\^out\.pub$"; }
sweeps() { grep -c "^0 $1\$" "$W/sws/calls" 2> /dev/null; }
wq() { [[ -e /var/tmp/srcpkg-$1 ]] && print kept || print gone; }
cw() { typeset k; for k in "$@"; do [[ -e /var/tmp/srcpkg-$k ]] && find "/var/tmp/srcpkg-$k" -depth -delete; done; }
print x > "$W/bearer"; r7 pubstale > "$W/p11.json"
# NEG control: origin/main's builder memos the stale-W failure, and its next tick declines the out before any build
if [[ -n ${F8_BUILDER:-} ]]; then S0=$S S=$F8_BUILDER
  tk11 BUILDER_STATE=$W/st11o SWPLANT=1 SWKEYS=pubstale:$KS BUILDER_WSWEEP=$W/sws/wsweep; o1=$out c1=$(cl7 pubstale); m1=$(m11 "$W/st11o" pubstale); cw $KS
  tk11 BUILDER_STATE=$W/st11o BUILDER_WSWEEP=$W/sws/wsweep; o2=$out c2=$(cl7 pubstale); S=$S0
  print -r -- "$o1"$'\n'"$o2" | grep ' pubstale' | sed 's/^/   11o /'
  (( m1 == 1 && c1 == 0 && c2 == 0 )) && print -r -- "$o1" | grep -q 'decline pubstale: pre-submit-check.sh --leaf .* rc=1 (check' &&
    print -r -- "$o2" | grep -q 'decline pubstale: .*first publish was refused here' && ! print -r -- "$o2" | grep -q 'pubstale: first build of' &&
    ok "NEG origin/main's builder ($F8_BUILDER): a stale W of another uid fails --check, memo'd as the out's refusal; the next tick declines it unbuilt" ||
    no "F8_BUILDER: memo $m1, claims $c1 $c2: $(print -r -- "$o1"$'\n'"$o2" | grep ' pubstale')"
else print "SKIP origin/main stale-W negative control: F8_BUILDER unset (not counted as a pass)"; fi
# 11A, no sweep (BUILDER_WSWEEP unset): the stale W fails --check; not memo'd, nothing submitted or claimed. pubstfl: a DIFFERS.
r7 pubstale pubheld pubstfl > "$W/p11.json"
tk11 BUILDER_STATE=$W/st11 SWPLANT=1 "SWKEYS=pubstale:$KS pubheld:$KH" BUILDER_WSWEEP=; print -r -- "$out" | grep -E ' pub(stale|held|stfl)' | sed 's/^/   11A /'
grep -q '^  check: FAIL (error: builder for ' "$W/st11/tried/"*qb-pubstale-*.presubmit && ! grep -q "srcpkg-$KS" "$W/st11/tried/"*qb-pubstale-*.presubmit &&
  ok "the stale W fails pre-submit's --check, whose .presubmit keeps only 'error: builder ... failed', not the W (so the builder reads nix log)" ||
  no "11A presubmit: $(grep check: "$W/st11/tried/"*qb-pubstale-*.presubmit 2>&1)"
for a in "pubstale:cannot remove '/var/tmp/srcpkg-$KS': Permission denied" "pubheld:/var/tmp/srcpkg-$KH: Permission denied"; do x=${a%%:*}
  (( $(m11 "$W/st11" $x) == 0 && $(cl7 $x) == 0 && $(begun $x) == 0 )) && has "decline $x: the host, not the out, failed pre-submit-check.sh --leaf .*${a#*:}" &&
    ! has "held $x" && ok "$x: a stale W of another uid fails --check: the host's failure (${a#*:}), not memo'd (not held), nothing submitted or claimed" ||
    no "11A $x: memo $(m11 "$W/st11" $x): $(print -r -- "$out" | grep " $x")"
done
(( $(m11 "$W/st11" pubstfl) == 1 && $(begun pubstfl) == 0 )) && has 'decline pubstfl: pre-submit-check.sh --leaf .* rc=1 \(check' &&
  ok "NEG a genuine DIFFERS whose log names ANOTHER key's W ($KD): still memo'd, never submitted" || no "11A pubstfl: $(print -r -- "$out" | grep ' pubstfl')"
# mutants: one that reads only .presubmit (no nix log), one whose W pattern is not anchored on the drv's own buildKey
mu8 "$S" "$W/mut11a.sh" '[[ -z $fy && -n $x && ,$w, == *,check,* ]] && fy=' ': || fy='
mu8 "$S" "$W/mut11b.sh" '+-${x}['"'"'\"]?[:;] (Permission denied|File exists)' '+-[0-9a-f]+'"'"'?: Permission denied'
cw $KS; r7 pubstale > "$W/p11.json"; S0=$S S=$W/mut11a.sh; tk11 BUILDER_STATE=$W/st11ma SWPLANT=1 SWKEYS=pubstale:$KS BUILDER_WSWEEP=; S=$S0
! cmp -s "$S" "$W/mut11a.sh" && (( $(m11 "$W/st11ma" pubstale) == 1 )) && ok "NEG a mutant that reads only .presubmit memos the stale-W failure (the nix log read is what saves it)" ||
  no "mut11a: memo $(m11 "$W/st11ma" pubstale): $(print -r -- "$out" | grep ' pubstale')"
r7 pubstfl > "$W/p11.json"; S0=$S S=$W/mut11b.sh; tk11 BUILDER_STATE=$W/st11mb BUILDER_WSWEEP=; S=$S0
! cmp -s "$S" "$W/mut11b.sh" && (( $(m11 "$W/st11mb" pubstfl) == 0 )) && has 'decline pubstfl: the host, not the out' &&
  ok "NEG a mutant matching any key's W calls the DIFFERS a host failure (never memo'd: rebuilt every tick); anchored on the drv's own key, it memos" ||
  no "mut11b: memo $(m11 "$W/st11mb" pubstfl): $(print -r -- "$out" | grep ' pubstfl')"
# 11B: the next tick of 11A's state dir, the stale W (mut11a's) still there: the per-drv sweep before --check removes it; published
r7 pubstale > "$W/p11.json"; [[ $(wq $KS) == kept ]] || no "11B: no stale W before the tick"
tk11 BUILDER_STATE=$W/st11 BUILDER_WSWEEP=$W/sws/wsweep; print -r -- "$out" | grep ' pubstale' | sed 's/^/   11B /'
(( $(sweeps $KS) == 1 && $(begun pubstale) == 1 && $(cl7 pubstale) == 1 )) && has "pubstale: solnix-wsweep: removing stale /var/tmp/srcpkg-$KS \(uid 30999, no process of uid 30999 runs\)" &&
  has 'pubstale: published .*an 8UNr-only client verified it' && [[ $(wq $KS) == gone ]] &&
  ok "the next tick passes: the per-drv sweep removes the W (whatever its age), --check SAME, published, claimed" || no "11B: sweeps $(sweeps $KS): $(print -r -- "$out" | grep ' pubstale')"
# 11C: the W is left INSIDE the tick, after the first build (the dixa shape), and its owner runs no process: swept, published
r7 pubsweep > "$W/p11.json"; tk11 BUILDER_STATE=$W/st11c SWPLANT=1 SWKEYS=pubsweep:$KW BUILDER_WSWEEP=$W/sws/wsweep
print -r -- "$out" | grep ' pubsweep' | sed 's/^/   11C /'
(( $(sweeps $KW) == 1 && $(begun pubsweep) == 1 && $(cl7 pubsweep) == 1 && $(m11 "$W/st11c" pubsweep) == 0 )) && has "pubsweep: solnix-wsweep: removing stale /var/tmp/srcpkg-$KW" &&
  ok "a W left inside the tick (after the first build, past the tick-start sweep): swept before --check, published in the same tick" || no "11C: $(print -r -- "$out" | grep ' pubsweep')"
# 11D: the W's owner runs a process (a live build, as far as root can tell): the sweep keeps it; --check fails, not memo'd
cw $KH; r7 pubheld > "$W/p11.json"
"$GP" -c 'import os, time; os.setgid(30000); os.setuid(30998); time.sleep(900)' & HOLD=$!; sleep 2
tk11 BUILDER_STATE=$W/st11d SWPLANT=1 SWKEYS=pubheld:$KH SWUID=30998 BUILDER_WSWEEP=$W/sws/wsweep; print -r -- "$out" | grep ' pubheld' | sed 's/^/   11D /'
(( $(sweeps $KH) == 1 && $(m11 "$W/st11d" pubheld) == 0 && $(cl7 pubheld) == 0 && $(begun pubheld) == 0 )) && [[ $(wq $KH) == kept ]] &&
  has "pubheld: solnix-wsweep: keeping /var/tmp/srcpkg-$KH \(uid 30998 runs a process" && has 'decline pubheld: the host, not the out' &&
  ok "the W's owner runs a process: the sweep keeps it (never a dir a live build may use); declined, not memo'd" || no "11D: $(print -r -- "$out" | grep ' pubheld')"
# 11E: that process ended: the next tick sweeps the W and publishes
kill $HOLD; wait $HOLD 2> /dev/null; tk11 BUILDER_STATE=$W/st11d BUILDER_WSWEEP=$W/sws/wsweep; print -r -- "$out" | grep ' pubheld' | sed 's/^/   11E /'
(( $(begun pubheld) == 1 && $(cl7 pubheld) == 1 )) && has "pubheld: solnix-wsweep: removing stale /var/tmp/srcpkg-$KH" && [[ $(wq $KH) == gone ]] &&
  ok "its owner's process gone: the next tick sweeps the W and publishes" || no "11E: $(print -r -- "$out" | grep ' pubheld')"
# 11F: a DIFFERS with the sweep on is memo'd too (the sweep ran; the check still differs)
r7 pubstfl > "$W/p11.json"; tk11 BUILDER_STATE=$W/st11f BUILDER_WSWEEP=$W/sws/wsweep
(( $(sweeps $KF) == 1 && $(m11 "$W/st11f" pubstfl) == 1 && $(begun pubstfl) == 0 )) && ok "NEG a genuine DIFFERS with the sweep on: memo'd, never submitted" || no "11F: $(print -r -- "$out" | grep ' pubstfl')"
cw $KS $KH $KF $KW $KD; rm -f "$W/bearer"
else print "SKIP section 11 (stale fixed build dirs): needs root, to own a dir as another uid (not counted as a pass)"; fi
# --- 12. fleet9: newest row first (infra 2026-11-05 s3, and the A2 deadlock on aarch64). Repo12: main F1 (every attr at batch b1)
# + C1 (b1's rows) + H (head: a README; it evaluates b1, as dixi's main does W12's older rows); branch w: F2 (b2, and the dp* attrs
# that reference a dz* at b2) + C2 (b2's rows). The listing's rows carry commit C2, as infra fills rows[].commit with the newest
# batch's. Served before any tick: every b1 out, nfb's b2 (real) and ncr's b2 (a narinfo: served, but its dry run needs an input
# nobody has). The dz* b2 outs are built here and not served (A2: dixa built the batch). nho's b2 names a host (a genuine gate
# FAIL); nsu's b2 row names an out no commit evaluates to.
print x > "$W/bearer"; R12=$W/repo12; mkdir -p "$R12/docs/registry"; g12() { git -C "$R12" -c user.name=t -c user.email=t@t "$@" > /dev/null 2>&1; }
cat > "$W/f12.tmpl" <<'F12'
{ outputs = { self }: let
    mk = name: script: derivation { inherit name; system = "x86_64-solaris"; builder = "/usr/bin/bash"; args = [ "-c" script ]; };
    t = n: mk "qb-${n}-@B@-@TAG@" "echo building ${n}; echo ${n}-@B@-@TAG@ > $out";
    p = n: z: mk "qb-${n}-@B@-@TAG@" "echo building ${n}; echo ${z} > $out";
    zs = { dza = t "dza"; dzb = t "dzb"; dzc = t "dzc"; dzd = t "dzd"; dze = t "dze"; };
  in { packages.x86_64-solaris = zs // { nfa = t "nfa"; nfb = t "nfb"; nsu = t "nsu";
    ncr = if "@B@" == "b1" then t "ncr" else mk "qb-ncr-@B@-@TAG@" "read x < ${t "ncrdep"}; echo $x > $out";
    nho = if "@B@" == "b1" then t "nho" else mk "qb-nho-@B@-@TAG@" "echo building nho; echo nho-@TAG@ built on floki > $out";
    @DP@
  }; }; }
F12
pf12() { sed -e "s|@B@|$1|g" -e "s|@TAG@|${W##*/}|g" -e "s|@DP@|${2:-}|" "$W/f12.tmpl" > "$R12/flake.nix"; g12 add -A; }
e12() { nix eval --raw "git+file://$R12?rev=$1#packages.x86_64-solaris.$2.$3" 2> /dev/null; }
A12="nfa nfb ncr nho nsu dza dzb dzc dzd dze" P12="dpa dpb dpc dpd1 dpd2 dpe1 dpe2"; typeset -A O1 O2 D2
g12 init -b main; pf12 b1; g12 commit -m F1; x=$(git -C "$R12" rev-parse HEAD); for a in $A12; do O1[$a]=$(e12 "$x" $a outPath); done
{ print -r -- "$H"; for a in $A12; do rec $a 1 y "${O1[$a]}"; done; } > "$R12/docs/registry/recipes.tsv"; g12 add -A; g12 commit -m C1; C1=$(git -C "$R12" rev-parse HEAD)
g12 checkout -b w; pf12 b2 'dpa = p "dpa" zs.dza; dpb = p "dpb" zs.dzb; dpc = p "dpc" zs.dzc; dpd1 = p "dpd1" zs.dzd; dpd2 = p "dpd2" zs.dzd; dpe1 = p "dpe1" zs.dze; dpe2 = p "dpe2" zs.dze;'
g12 commit -m F2; x=$(git -C "$R12" rev-parse HEAD); for a in $A12 $P12; do O2[$a]=$(e12 "$x" $a outPath) D2[$a]=$(e12 "$x" $a drvPath); done
O2[nsu]=/nix/store/00000000000000000000000000000000-qb-nsu-b2	# a row no commit evaluates to
for a in $A12 $P12; do rec $a 1 y "${O2[$a]}"; done >> "$R12/docs/registry/recipes.tsv"; g12 add -A; g12 commit -m C2; C2=$(git -C "$R12" rev-parse HEAD)
g12 checkout main; print h > "$R12/README"; g12 add -A; g12 commit -m H; H12=$(git -C "$R12" rev-parse HEAD)
{ for a in $A12; do rec $a 1 y "${O1[$a]}"; done; for a in $A12 $P12; do rec $a 1 y "${O2[$a]}"; done; } >> "$W/p.tsv"; cp "$W/p.tsv" "$W/hc/registry/recipes.tsv"
nix build --no-link "git+file://$R12?rev=$C1#packages.x86_64-solaris."{nfa,nfb,ncr,nho,nsu,dza,dzb,dzc,dzd,dze} \
  "git+file://$R12?rev=$C2#packages.x86_64-solaris."{nfb,dza,dzb,dzc,dzd,dze} >> "$W/fixture.log" 2>&1 &&
  nix copy --to "file://$W/hc" $(for a in $A12; do print -r -- "${O1[$a]}"; done) "${O2[nfb]}" >> "$W/fixture.log" 2>&1 &&
  ( export XDG_CACHE_HOME=$W/fkst/x12; nix store sign --store "file://$W/hc" --key-file "$W/sk" $(for a in $A12; do print -r -- "${O1[$a]}"; done) "${O2[nfb]}" ) >> "$W/fixture.log" 2>&1 &&
  [[ -n $C1 && -n $C2 && -n $H12 && ${O1[nfa]} != "${O2[nfa]}" && ${O2[dpa]} == *-qb-dpa-b2-* && -n $(sv7 "${O1[dza]}") && -z $(sv7 "${O2[dza]}") && -e ${O2[dza]} ]] ||
  no "fixture 12: C1=$C1 C2=$C2 nfa=${O1[nfa]} ${O2[nfa]} $(tail -2 "$W/fixture.log")"
printf 'StorePath: %s\nNarHash: %s\n' "${O2[ncr]}" "$GH" > "$W/hc/$(print -r -- "${O2[ncr]#/nix/store/}" | cut -c1-32).narinfo"
r12() { typeset s= a; for a; do s="$s${s:+,}$(rc $a "$C2")"; done; print "{\"rows\":[$s]}"; }	# rows[].commit = C2, the newest batch's
tk12() { tk7 FKROWS=$W/p12.json BUILDER_FLAKE="git+file://$R12?ref=main" "$@"; }
cd12() { print -r -- "$c" | grep '/complete' | grep -c "\"store_path\":\"$1\""; }	# completions naming that out
# NEG control: origin/main's builder votes the older rows (b1) and sends the listing's commit; A2: dpa waits on dza's b2 forever
if [[ -n ${F9_BUILDER:-} ]]; then r12 nfa nfb ncr dza dpa > "$W/p12.json"; S0=$S S=$F9_BUILDER; tk12 BUILDER_STATE=$W/st12o; S=$S0
  print -r -- "$out" | grep -E ' (nfa|nfb|ncr|dza|dpa)[: ]' | sed 's/^/   12o /'
  [[ $(cd12 "${O1[nfa]}") == 1 && $(cd12 "${O1[nfb]}") == 1 && $(cd12 "${O2[nfa]}") == 0 && $(cd12 "${O2[nfb]}") == 0 ]] &&
    ok "NEG origin/main's builder ($F9_BUILDER): votes the older row's out (nfa b1 though b2 is unserved, nfb b1 though b2 is served)" || no "F9 older: $(print -r -- "$c" | grep complete)"
  [[ $(cm8 "${O1[ncr]}" "$C2") == 1 ]] && ok "NEG origin/main's builder: the vote on ncr's b1 out carries the listing's commit C2 (the newest batch's), not C1" || no "F9 crev: $(print -r -- "$c" | grep complete)"
  [[ $(cd12 "${O1[dza]}") == 1 && $(cl7 dpa) == 0 && -z $(print -r -- "$sl" | grep '^BEGIN') ]] && has "dpa: ${O2[dpa]} waits for its references to be served first: ${O2[dza]#/nix/store/}" &&
    ok "NEG origin/main's builder, the A2 shape: zlib (dza) voted on its older out, pcre2 (dpa) waits for dza's newest row, nothing published" || no "F9 A2: $(print -r -- "$out" | grep -E ' (dza|dpa)')"
else print "SKIP origin/main newest-first negative control: F9_BUILDER unset (not counted as a pass)"; fi
# 12z: a host that may not publish (BUILDER_PUBLISH=0)
r12 nfa nfb ncr nho > "$W/p12.json"; tk12 BUILDER_STATE=$W/st12z BUILDER_PUBLISH=0; print -r -- "$out" | grep -E ' (nfa|nfb|ncr|nho)[: ]' | sed 's/^/   12z /'
has "decline nfa: ${O2[nfa]} is not served \(a first build .*\[${C2:0:12}\]: the job waits for it \(no vote on an older row\)" && [[ $(cl7 nfa) == 0 && $(cd12 "${O1[nfa]}") == 0 ]] &&
  ok "NEG strict: the newest row's out unserved and this host may not publish: declined (it waits), the older served row never voted" || no "12z nfa: $(print -r -- "$out" | grep ' nfa')"
[[ $(cm8 "${O2[nfb]}" "$C2") == 1 && $(cd12 "${O1[nfb]}") == 0 ]] && has "nfb: rebuilt ${O2[nfb]} here, identical" &&
  ok "the newest row's out served: the vote is on the newest (nfb b2), with its commit C2" || no "12z nfb: $(print -r -- "$out" | grep ' nfb')"
[[ $(cm8 "${O1[ncr]}" "$C1") == 1 && $(cm8 "${O1[ncr]}" "$C2") == 0 ]] && has "ncr: candidate head .*skipped: the dry run would build 1 .*\[${C2:0:12}\]" &&
  ok "crev: the newest (served) cannot be rebuilt here, so the older row's out is voted (at head), sent with the commit of that out's row (C1: the same drv as head's), not the listing's C2" || no "12z ncr: $(print -r -- "$c" | grep complete) $(print -r -- "$out" | grep ' ncr')"
# 12p: a host that may publish. nho's newest is refused at the gate: held; nsu's newest is not evaluated: it waits; A2: dza then dpa
r12 nfa nho nsu dza dpa > "$W/p12.json"; tk12 BUILDER_STATE=$W/st12p; print -r -- "$out" | grep -E ' (nfa|nho|nsu|dza|dpa)[: ]' | sed 's/^/   12p /'
[[ $(bg9 "${O2[nfa]}") == 1 && $(cm8 "${O2[nfa]}" "$C2") == 1 && $(cd12 "${O1[nfa]}") == 0 ]] && has "nfa: published ${O2[nfa]}" &&
  ok "newest first: nfa's newest row's out (b2, unserved) is first-published, claimed and completed with it and C2; the older b1 never voted" || no "12p nfa: $(print -r -- "$out" | grep ' nfa')"
has "held nho: newest ${O2[nho]} refused here \(pre-submit-check.sh --leaf failed: [a-z,]*gate" && [[ $(cl7 nho) == 0 && $(cd12 "${O1[nho]}") == 0 ]] &&
  ok "a genuine refusal of the newest (publish-gate FAIL): logged 'held nho: newest <out> refused here (...)', no vote on the older, no claim" || no "12p nho: $(print -r -- "$out" | grep ' nho')"
has "decline nsu: the newest row's ${O2[nsu]} is not served, and no commit here evaluates to it" && [[ $(cl7 nsu) == 0 ]] &&
  ok "NEG the newest row's out evaluates at no commit here: declined (it waits), the older served row never voted" || no "12p nsu: $(print -r -- "$out" | grep ' nsu')"
[[ $(bg9 "${O2[dza]}") == 1 && $(bg9 "${O2[dpa]}") == 1 && $(cd12 "${O1[dza]}") == 0 && $(cl7 dza) == 1 && $(cl7 dpa) == 1 ]] && (( $(ln9 "${O2[dza]}") < $(ln9 "${O2[dpa]}") )) &&
  [[ $(cm8 "${O2[dza]}" "$C2") == 1 ]] && ok "A2: zlib's newest row (dza b2) is first-published and completed with it, never the older out; pcre2 (dpa, references it) is published after it" ||
  no "12p A2: $(print -r -- "$out" | grep -E ' (dza|dpa)')"
r12 nho > "$W/p12.json"; tk12 BUILDER_STATE=$W/st12p
has "held nho: newest ${O2[nho]} refused here \(pre-submit-check" && ! has 'nho: first build of' && ! has 'nho: rebuilding' && [[ $(cl7 nho) == 0 ]] &&
  ok "the next tick: held again before any build (a human fixes or retires the row; infra lists 'held ')" || no "12p2 nho: $(print -r -- "$out" | grep ' nho')"
# 12b: deps first. dpb's only job (dzb's job was closed by an older builder's vote: no dzb row in the listing) needs dzb's b2
r12 dpb > "$W/p12.json"; w12="dpb: ${O2[dpb]} waits for its references to be served first: ${O2[dzb]#/nix/store/}"
if [[ -n ${F9_BUILDER:-} ]]; then S0=$S S=$F9_BUILDER; tk12 BUILDER_STATE=$W/st12bo; S=$S0
  print -r -- "$out" | grep -qF "$w12" && [[ -z $(print -r -- "$sl" | grep '^BEGIN') && $(cl7 dpb) == 0 ]] &&
    ok "NEG origin/main's builder: dpb waits for dzb's newest row forever (no job lists it), nothing published" || no "F9 dpb: $(print -r -- "$out" | grep ' dpb')"
else print "SKIP origin/main deps-first negative control: F9_BUILDER unset (not counted as a pass)"; fi
mu8 "$S" "$W/mut12b.sh" 'fdep "$1" "$gr" &&' 'false &&'; S0=$S S=$W/mut12b.sh; tk12 BUILDER_STATE=$W/st12bm; S=$S0
! cmp -s "$S" "$W/mut12b.sh" && print -r -- "$out" | grep -qF "$w12" && [[ -z $(print -r -- "$sl" | grep '^BEGIN') && $(cl7 dpb) == 0 ]] &&
  ok "NEG a mutant without deps first: dpb waits, nothing published (so the pass below is fdep's)" || no "mut12b: $(print -r -- "$out" | grep ' dpb')"
tk12 BUILDER_STATE=$W/st12b; print -r -- "$out" | grep ' dpb' | sed 's/^/   12b /'
has "dpb: deps first: first-publishing its reference ${O2[dzb]}" && [[ $(bg9 "${O2[dzb]}") == 1 && $(bg9 "${O2[dpb]}") == 1 && $(cl7 dpb) == 1 && $(cl7 dzb) == 0 ]] &&
  (( $(ln9 "${O2[dzb]}") < $(ln9 "${O2[dpb]}") )) && ok "deps first: dpb's unserved reference (dzb's newest row, no job) is first-published in the same tick, then dpb; one claim (dpb)" ||
  no "12b: $(print -r -- "$out" | grep ' dpb') $(print -r -- "$sl" | grep BEGIN)"
# 12c: the reference was refused here (memo'd): held, never published
mkdir -p "$W/st12c/tried"; print -r -- "pre-submit-check.sh --leaf failed: gate (a test memo)" > "$W/st12c/tried/${D2[dzc]##*/}^out.pub"
r12 dpc > "$W/p12.json"; tk12 BUILDER_STATE=$W/st12c
has "held dpc: its reference ${O2[dzc]} refused here \(pre-submit-check.sh --leaf failed: gate \(a test memo\)\)" && [[ -z $(print -r -- "$sl" | grep '^BEGIN') && $(cl7 dpc) == 0 ]] &&
  ok "deps first never publishes a reference refused here: 'held dpc: its reference <out> refused here (...)', nothing submitted" || no "12c: $(print -r -- "$out" | grep ' dpc')"
# 12d: two jobs of one tick need the same reference (dzd's b2); its submission is slow (FKSLOWSUB), so the second job meets it
j12="BUILDER_JOBS=2 BUILDER_BUSY=0 BUILDER_NCPU=4 BUILDER_CORES=1 BUILDER_LOAD_MAX=auto"
r12 dpd1 dpd2 > "$W/p12.json"; tk12 BUILDER_STATE=$W/st12d $j12 FKSLOWSUB=20; s12=$sl k12=$(( $(cl7 dpd1) + $(cl7 dpd2) )); print -r -- "$out" | grep -E ' dpd[12]' | sed 's/^/   12d /'
[[ $(bg9 "${O2[dzd]}") == 1 && $k12 == 1 ]] && has "dpd[12]: ${O2[dzd]#/nix/store/} is being published by another job of this tick" &&
  ok "two jobs need one reference: one /begin for it (the per-out lock), the other job meets the lock; one of the two published" || no "12d: $(print -r -- "$s12" | grep BEGIN) $(print -r -- "$out" | grep -E 'dpd|lock|another job')"
tk12 BUILDER_STATE=$W/st12d $j12; n12=$(print -r -- "$s12"$'\n'"$sl" | grep -c "^BEGIN .*-qb-dpd[12]-")
[[ $(bg9 "${O2[dzd]}") == 0 && $n12 == 2 && $(cl7 dpd1) == 1 && $(cl7 dpd2) == 1 ]] && ok "the next tick: the other one publishes (its reference is served now): each dpd out begun once in all" || no "12d2: $n12 $(print -r -- "$out" | grep -E ' dpd')"
mu8 "$S" "$W/mut12d.sh" 'mkdir "$flk" 2> /dev/null ||' ': ||' 'first1 "$@"; flr=$?; rmdir "$flk"; return $flr' 'first1 "$@"'
r12 dpe1 dpe2 > "$W/p12.json"; S0=$S S=$W/mut12d.sh; tk12 BUILDER_STATE=$W/st12dm $j12 FKSLOWSUB=30; S=$S0
! cmp -s "$S" "$W/mut12d.sh" && [[ $(bg9 "${O2[dze]}") == 2 ]] && ok "NEG a mutant without the lock: both jobs submit the reference (two /begin of one out)" || no "mut12d: $(print -r -- "$sl" | grep BEGIN)"
# 12e: BUILDER_SKIP (solnix.cache.build.skipPnames): the seed rows are never planned
{ print -r -- "$H"; rec binutils-seed 2.47 y /nix/store/00000000000000000000000000000001-binutils-seed-2.47; rec illumos-early 1 y /nix/store/00000000000000000000000000000002-illumos-early
  rec illumos-userland ac45d71fc2 y /nix/store/00000000000000000000000000000003-illumos-userland; rec x-seedy 1 y /nix/store/00000000000000000000000000000004-x-seedy-1; } > "$W/s12.tsv"
print "{\"rows\":[$(row binutils-seed 2.47 user-request),$(row illumos-early 1 user-request),$(row illumos-userland ac45d71fc2 user-request),$(row x-seedy 1 outdated)]}" > "$W/s12.json"
SK12="*-seed illumos-early illumos-userland"; p12=$(env BUILDER_SKIP="$SK12" ksh93 "$S" plan "$W/s12.json" "$W/s12.tsv" 2>&1)
[[ $p12 == "binutils-seed SKIP (BUILDER_SKIP)"$'\n'"illumos-early SKIP (BUILDER_SKIP)"$'\n'"illumos-userland SKIP (BUILDER_SKIP)"$'\n'"x-seedy BUILD "* ]] &&
  ok "BUILDER_SKIP='$SK12': binutils-seed, illumos-early, illumos-userland SKIP; x-seedy still BUILD" || no "skip: $p12"
[[ $(ksh93 "$S" plan "$W/s12.json" "$W/s12.tsv" 2>&1 | grep -c ' BUILD ') == 4 ]] && ok "NEG BUILDER_SKIP unset: all four BUILD (the skip is the setting's)" || no "skip unset"
if [[ -n ${F9_BUILDER:-} ]]; then env BUILDER_SKIP="$SK12" ksh93 "$F9_BUILDER" plan "$W/s12.json" "$W/s12.tsv" 2>&1 | grep -q '^binutils-seed BUILD ' &&
  ok "NEG origin/main's builder plans binutils-seed BUILD whatever BUILDER_SKIP says" || no "F9 skip"
else print "SKIP origin/main skip negative control: F9_BUILDER unset (not counted as a pass)"; fi
L12=$(env BUILDER_SKIP="$SK12" ksh93 "$S" plan "$W/live.json" "$W/live.tsv" 2>&1)
(( $(print -r -- "$L12" | grep -c ' SKIP ') > 0 )) && ! print -r -- "$L12" | egrep -q '^([^ ]*-seed|illumos-early|illumos-userland) BUILD' &&
  ok "the live listing with the module's default: $(print -r -- "$L12" | grep -c ' SKIP ') rows SKIP, none of them BUILD" || no "live skip: $(print -r -- "$L12" | grep -E 'seed|illumos-(early|userland) ')"
grep -q 'BUILDER_SKIP = lib.concatStringsSep " " cfg.skipPnames' "$G/modules/config/community/builder.nix" && grep -q 'default = \[ "\*-seed" "illumos-early" "illumos-userland" \];' "$G/modules/config/community/builder.nix" &&
  ok "builder.nix: skipPnames defaults to the seed rows and is passed as BUILDER_SKIP" || no "builder.nix skipPnames"
# 12f: log stamps in UTC whatever TZ says (lixi: 12:40:46Z for 17:40Z)
ut12() { typeset u0 u1 l; u0=$(date -u +%Y-%m-%dT%H:%M); l=$(env TZ=US/Eastern BUILDER_LOAD_MAX=0 BUILDER_BUSY=0 BUILDER_STATE=$W/st12u ksh93 "$1" once 2>&1 | grep ' builder: ' | head -1)
  u1=$(date -u +%Y-%m-%dT%H:%M); l=${l%% *}; [[ $l == *Z && ( ${l:0:16} == "$u0" || ${l:0:16} == "$u1" ) ]]; }
[[ $(TZ=US/Eastern date +%H) != "$(date -u +%H)" ]] && ut12 "$S" && ok "TZ=US/Eastern: the log stamp is date -u's (UTC)" || no "utc stamp"
if [[ -n ${F9_BUILDER:-} ]]; then ! ut12 "$F9_BUILDER" && ok "NEG origin/main's builder under TZ=US/Eastern: a local-time stamp with a Z" || no "F9 utc: the control cannot fail"
else print "SKIP origin/main utc negative control: F9_BUILDER unset (not counted as a pass)"; fi
# 12g: nap's deadline. sleep stubbed: each step really sleeps, and the first one moves SECONDS by JUMP (a suspend, or a clock
# stepped back); BUILDER_NAP_STEP=1 stands in for 60. Prints "<steps> <wall seconds>". Its own ksh93 process: an assignment to
# SECONDS in a $(...) subshell leaves the parent's SECONDS at epoch seconds (measured on dixi's ksh93 93u+).
{ sed -n '/^nap() {/,/^}/p' "$S"; print -r -- 'integer n=0 t0=$(date +%s) JUMP=$1; shift
function sleep { n=n+1; command sleep "$1"; (( n == 1 )) && SECONDS=$(( SECONDS + JUMP )); }
BUILDER_NAP_STEP=1; if [[ $1 == old ]]; then sleep "$2"; else nap "$1"; fi; print "$n $(( $(date +%s) - t0 ))"'; } > "$W/nap12.ksh"
np12() { ksh93 "$W/nap12.ksh" "$@"; }	# np12 <jump> <secs> | np12 <jump> old <secs>
r=$(np12 7200 3600); [[ ${r% *} == 1 ]] && (( ${r#* } <= 3 )) && ok "nap 3600 with a 2 h clock jump in its first step (a suspend): ends after that step ($r)" || no "nap jump: $r"
r=$(np12 0 3); (( ${r% *} >= 3 && ${r#* } >= 3 )) && ok "nap 3 without a jump: waits it out in 1 s steps ($r), so the check above can fail" || no "nap plain: $r"
r=$(np12 -7200 3600); [[ ${r% *} == 1 ]] && ok "nap 3600, the clock stepped back 2 h: ends after one step, not 2 h late ($r)" || no "nap back: $r"
r=$(np12 7200 old 4); (( ${r#* } >= 4 )) && grep -q 'nap "$(pause)"' "$S" && ! grep -q 'sleep "$(pause' "$S" &&
  ok "NEG a single sleep (origin/main's loop: sleep \"\$(pause)\") sleeps its whole length through the same jump ($r); the loop uses nap" || no "old sleep: $r"
if [[ -n ${F9_BUILDER:-} ]]; then grep -q 'sleep "$(pause)"' "$F9_BUILDER" && ! grep -q '^nap()' "$F9_BUILDER" && ok "NEG origin/main's loop sleeps one pause (no deadline)" || no "F9 nap"
else print "SKIP origin/main nap negative control: F9_BUILDER unset (not counted as a pass)"; fi
rm -f "$W/bearer"
(( bad )) && print "RESULT: FAIL" || print "RESULT: PASS"
exit $bad
