#!/usr/bin/ksh93
# test-builder.sh -- solnix-builder on illumos (ksh93, jq, nix, curl): the planner against fixed rows + a fixed recipes
# file, the live listing, and the dry run (no bearer -> no claim). curl is real for the listing and cache; the claim
# endpoint is never reached without a bearer, which the NEG cases prove with a recording fake API.
S=${1:-$(dirname "$0")/../modules/config/community/solnix-builder.sh}
W=$(mktemp -d /tmp/bld.XXXXXX); trap 'find "$W" -depth -delete' EXIT
bad=0; ok() { print "ok: $1"; }; no() { print "FAIL: $1"; bad=1; }
export BUILDER_STATE=$W BUILDER_BEARER_FILE=$W/bearer BUILDER_PATH=$PATH
T=$'\t'; H="pname${T}version${T}url${T}sha256${T}buildsys${T}deps${T}flags${T}system${T}out${T}debug"
{ print -r -- "$H"
  print -r -- "wget${T}1.24.5${T}u${T}s${T}a${T}d${T}has_manpages=y${T}x86_64-solaris${T}/nix/store/wd17vpnhxxj4p6jp2nq6qylrp6gm63dh-wget-1.24.5${T}"
  print -r -- "openssl${T}3.4.0${T}u${T}s${T}a${T}d${T}has_manpages=n${T}x86_64-solaris${T}/nix/store/arszvzha3cavkifl7qhhnqq67rqy8nhf-openssl-3.4.0${T}"
  print -r -- "jq${T}1.7.1${T}u${T}s${T}a${T}d${T}has_manpages=y${T}x86_64-solaris${T}/nix/store/1fjqlkii7xmvhqrbryx59n7gbv46c3j5-jq-1.7.1${T}"
  print -r -- "zlib${T}1.3.2${T}u${T}s${T}a${T}d${T}has_manpages=y${T}x86_64-solaris${T}/nix/store/lkhrzj1xyvkg92z0d8j0din7lfqngk4s-zlib-1.3.2${T}"
} > "$W/r.tsv"
row() { print -n "{\"pname\":\"$1\",\"target\":\"$2\",\"current\":\"$2\",\"system\":\"${4:-x86_64-solaris}\",\"reasons\":\"$3\",\"attempts\":0}"; }
print "{\"count\":6,\"rows\":[$(row wget-1.24.5 1.24.5 manpage-missing),$(row openssl3 3.4.0 manpage-missing),$(row jq 1.7.1 outdated),$(row zlib 1.3.1 manpage-missing),$(row ninja 1.12.1 manpage-missing),$(row jq 1.7.1 outdated aarch64-solaris)]}" > "$W/rows.json"
P=$(ksh93 "$S" plan "$W/rows.json" "$W/r.tsv"); print -r -- "$P" | sed 's/^/   /'
want() { print -r -- "$P" | egrep -q "$2" && ok "$1" || no "$1"; }
want "wget-1.24.5 (pname carries the version): served out already ships man1 -> MET" '^wget-1\.24\.5 MET /nix/store/wd17vpnh'
want "openssl3 -> openssl row, has_manpages=n -> NO-MAN" '^openssl3 NO-MAN /nix/store/arszvzha'
want "jq outdated with a served row -> BUILD" '^jq BUILD /nix/store/1fjqlkii'
want "zlib 1.3.1 (only 1.3.2 served) -> NO-RECIPE" '^zlib NO-RECIPE zlib 1\.3\.1'
want "ninja (no row) -> NO-RECIPE" '^ninja NO-RECIPE'
want "aarch64 row on x86_64 -> OTHER-SYSTEM" '^jq OTHER-SYSTEM aarch64-solaris'
[[ $(print -r -- "$P" | wc -l | tr -d ' ') == 6 ]] && ok "one decision per row" || no "rows: $(print -r -- "$P" | wc -l)"
# live: the real listing + the served recipes.tsv must plan without error, every row decided
curl -sS -m 30 -o "$W/live.json" https://telemetry.solnix.io/api/v1/build-queue/rows && curl -sS -m 60 -o "$W/live.tsv" https://cache.solnix.io/registry/recipes.tsv
L=$(ksh93 "$S" plan "$W/live.json" "$W/live.tsv"); n=$(jq '.rows|length' "$W/live.json")
[[ $(print -r -- "$L" | egrep -c ' (BUILD|MET|NO-MAN|NO-RECIPE|OTHER-SYSTEM) ') == "$n" ]] && ok "live listing: $n rows, all decided: $(print -r -- "$L" | cut -d' ' -f2 | sort | uniq -c | tr -s ' \n' ' ')" || no "live: $L"
print -r -- "$L" > "${LIVE_PLAN_OUT:-/dev/null}"
# NEG: no bearer -> plans, finds a BUILD, and still never claims. The API base is file://$W, so `rows` is the fixture
# and a claim attempt would need curl -X POST to file:// (it would fail loudly as "claim -> 000"); the log must say dry run.
cp "$W/rows.json" "$W/rows"
out=$(env BUILDER_API=file://$W BUILDER_RECIPES=file://$W/r.tsv BUILDER_LOAD_MAX=1000 ksh93 "$S" once 2>&1)
print -r -- "$out" | grep -q 'BUILD' && print -r -- "$out" | grep -q 'dry run: no' && ! print -r -- "$out" | grep -q 'claim ->' &&
  ok "NEG no bearer: planned a BUILD, did not claim" || no "dry run: $out"
: > "$W/bearer"; out=$(env BUILDER_API=file://$W BUILDER_RECIPES=file://$W/r.tsv BUILDER_LOAD_MAX=1000 ksh93 "$S" once 2>&1)
print -r -- "$out" | grep -q 'dry run: no' && ok "NEG empty bearer file: dry run" || no "empty bearer: $out"
print x > "$W/bearer"; out=$(env BUILDER_API=file://$W BUILDER_RECIPES=file://$W/r.tsv BUILDER_LOAD_MAX=1000 ksh93 "$S" once 2>&1)
print -r -- "$out" | grep -q 'claim -> ' && ok "control: with a bearer it does try to claim ($(print -r -- "$out" | grep -o 'claim -> .*'))" || no "bearer present but no claim attempt: $out"
rm -f "$W/bearer"
# a granted claim must be heartbeat and completed, never dropped (2026-10-28: a $(api ...) subshell lost $code and the
# token, orphaning a real job for its lease). Fake curl on PATH: rows/recipes from the fixtures, claim grants zlib.
mkdir -p "$W/fk"; cat > "$W/fk/curl" <<'FK'
#!/bin/sh
o=; u=; d=; while [ $# -gt 0 ]; do case $1 in -o) o=$2; shift;; --data-binary) d=$2; shift;; -w|-m|-X|-H) shift;; -*) ;; *) u=$1;; esac; shift; done
cat > /dev/null; echo "$u $d" >> "$FKLOG"
case $u in
*/rows) cp "$FKW/rows.json" "$o";; *recipes.tsv) cp "$FKW/r.tsv" "$o";;
*/claim) echo '{"jobs":[{"id":42,"claim_token":"00000000-0000-4000-8000-000000000042","pname":"zlib","current_version":"1.3.1","target_version":"1.3.1"}]}' > "$o";;
*) echo '{"state":"ok"}' > "$o";;
esac; printf 200
FK
chmod +x "$W/fk/curl"; print x > "$W/bearer"
out=$(env BUILDER_PATH="$W/fk:$PATH" FKW=$W FKLOG=$W/fk/log BUILDER_LOAD_MAX=1000 ksh93 "$S" once 2>&1); rm -f "$W/bearer"
c=$(cat "$W/fk/log"); print -r -- "$c" | sed 's/^/   /'
print -r -- "$c" | grep -q '/42/heartbeat' && print -r -- "$c" | grep -q '/42/complete .*"claim_token":"00000000-0000-4000-8000-000000000042".*"status":"failed".*cannot serve' &&
  ok "granted claim: heartbeat + complete failed with the reason (token kept)" || no "claim handling: $out"
out=$(env BUILDER_LOAD_MAX=0 ksh93 "$S" once 2>&1); print -r -- "$out" | grep -q 'not idle' && ok "NEG busy (load >= 0): does nothing" || no "busy: $out"
exit $bad
