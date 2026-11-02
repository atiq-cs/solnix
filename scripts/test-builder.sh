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
(( n > 0 )) && [[ $(print -r -- "$L" | egrep -c ' (BUILD|MET|MAN-GAP|NO-MAN|NO-RECIPE|OTHER-SYSTEM) ') == "$n" ]] && ok "live listing: $n rows, all decided: $(print -r -- "$L" | cut -d' ' -f2 | sort | uniq -c | tr -s ' \n' ' ')" || no "live: $n: $L"
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
case $u in */rows*) ;; *) cat > /dev/null;; esac; echo "$u $d" >> "$FKLOG"
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
*) echo '{"claim_expires_at":"x"}' > "$o";;
esac; [ -z "$w" ] || printf 200
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
ls "$W/stmix/eval" 2> /dev/null | grep -q "^$RA\.x86_64-solaris\.pin1$" && ls "$W/stmix/eval" | grep -q "^$RW\.x86_64-solaris\.wrow$" &&
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
rm -f "$W/bearer"
(( bad )) && print "RESULT: FAIL" || print "RESULT: PASS"
exit $bad
