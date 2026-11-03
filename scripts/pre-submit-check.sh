#!/usr/bin/env bash
# pre-submit-check.sh [--leaf] <out> [<out>...] -- what a host (dixi, dixa, lixi) and our own submitter must pass before an out
# is offered to cache.solnix.io (we promised infra: no host publishes until this runs on it). Every out is checked on
# THIS host, from its own store:
#   1. row     the SERVED recipes.tsv has a row whose out column names this exact path (the authority the site uses)
#   2. drv     scripts/drv-gate.sh --closure on its deriver: the whole .drv closure builds from the store only (A1-A4).
#              --leaf: drv-gate.sh --leaf instead (the deriver + every unserved input drv), for a host's first publish of an
#              out whose row is SERVED (maintainer 2026-11-03: pre-wave6 outs have host-PATH drvs deep in their closure).
#              The stamp records the mode (5th column); --closure stays the default for an out with no served row.
#   3. check   nix-store --realise --check of the deriver, so EVERY output (out, debug, man, ...) rebuilt bit-identical
#   4. gate    scripts/publish-gate.sh: deriver, host/user names, store RUNPATH + ldd, build-host identity, undeclared
#              references, and the out checks B6-B13 over the NAR stream (the bytes that get published)
#   5. store   B5/B11 on this store's copy (no setuid/setgid/sticky/writable bits, devices or FIFOs; mtime 1; owner):
#              the NAR cannot carry them, so only the exporting host can see them
#   6. closure B12: nothing in the runtime closure is in scripts/not-for-cache.tsv
#   7. log     the deriver's build log (nix log): configure/cmake/meson found no host tool, perl Configure ignored no
#              -D (LOOPHOLES.md classes 1-3, 5); a missing log FAILs (only the building host has it)
#   8. deps    every reference has a narinfo on the cache, or is in this batch AHEAD of it (deps first); cache-submit.py
#              then re-checks each reference under the 8UNr key before it submits
# Then it prints an EVIDENCE line: whether this host has /usr/gnu (an OI build host, where a host tool can satisfy a
# build silently) or not (a solnix host: only store tools exist, so the build is stronger evidence of store-only).
# On PASS it writes a stamp $GATE_STAMP_DIR/<NarHash nix32>.ok (default ~/.cache/solnix-pre-submit) that
# scripts/cache-submit.py --submit requires (--stamps <dir>): an out that did not pass here cannot be submitted.
# Exit 0 iff every out PASSes. Env: GATE_GREP_DIR, GATE_PYTHON (see publish-gate.sh / drv-gate.sh), GATE_RECIPES (a local
# recipes.tsv instead of the served one: then NO stamp is written), GATE_SKIP_CHECK=1 (skip step 3: then NO stamp),
# GATE_ALLOW_UNFREE=1 (the row says unfree=y). --selftest: run the selftests of every component.
set -u
here=$(cd "$(dirname "$0")" && pwd)
PATH=${GATE_GREP_DIR:+$GATE_GREP_DIR:}/usr/gnu/bin:/usr/bin:/usr/sbin:$PATH
py=${GATE_PYTHON:-$(command -v python3)}
[ -n "$py" ] && "$py" -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2>/dev/null || {
  echo "pre-submit: no python3 >= 3.9 (set GATE_PYTHON)" >&2; exit 2; }
export GATE_PYTHON=$py
if [ "${1:-}" = --selftest ]; then
  rc=0; "$py" "$here/gate-checks.py" selftest | tail -1 || rc=1
  bash "$here/publish-gate.sh" --selftest || rc=1
  exit $rc
fi
mode=--closure; [ "${1:-}" = --leaf ] && { mode=--leaf; shift; }
[ $# -gt 0 ] || { echo "usage: pre-submit-check.sh [--leaf] <out>... | --selftest" >&2; exit 2; }
# GATE_CACHE: another cache for the authority and deps steps (scripts/test-builder.sh's fixture cache). A stamp made against
# it gets nothing past cache-submit.py --submit, which plans only against the served recipes.tsv and 8UNr-published refs.
CACHE=${GATE_CACHE:-https://cache.solnix.io}
T=$(mktemp -d "${TMPDIR:-/tmp}/presubmit.XXXXXX"); trap 'rm -rf "$T"' EXIT
stamps=${GATE_STAMP_DIR:-$HOME/.cache/solnix-pre-submit}; mkdir -p "$stamps"
if [ -n "${GATE_RECIPES:-}" ]; then cp "$GATE_RECIPES" "$T/recipes.tsv" || exit 2; authority="local $GATE_RECIPES (no stamps)"
else
  c=$(curl -s -o "$T/recipes.tsv" -w '%{http_code}' "$CACHE/registry/recipes.tsv")
  [ "$c" = 200 ] || { echo "pre-submit: served recipes.tsv HTTP $c" >&2; exit 2; }
  authority="served recipes.tsv ($CACHE) sha256 $("$py" -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()[:16])' "$T/recipes.tsv")"
fi
head -1 "$T/recipes.tsv" | grep -q $'\tout\t' || { echo "pre-submit: recipes.tsv has no out column" >&2; exit 2; }
ocol=$(head -1 "$T/recipes.tsv" | tr '\t' '\n' | grep -n -x out | cut -d: -f1)
awk -F'\t' -v c="$ocol" 'NR>1 && $c != "" {print $c}' "$T/recipes.tsv" | sort -u > "$T/outs"
if [ -d /usr/gnu/bin ]; then ev="OI build host ($(uname -n)): /usr/gnu exists, so a host tool could have satisfied a build step unseen; WEAKER evidence than a build on a host without /usr/gnu"
else ev="host without /usr/gnu ($(uname -n)): only store tools exist here, so this build is direct evidence of store-only"; fi
echo "pre-submit: authority $authority; $(wc -l < "$T/outs" | tr -d ' ') out rows; drv gate $mode"
echo "EVIDENCE $ev"
batch=" $* "; rc=0; seen=""
for p in "$@"; do
  why=""; step() { echo "  $1: $2"; }
  case "$p" in /nix/store/*) ;; *) echo "FAIL $p: not a store path"; rc=1; continue ;; esac
  [ -e "$p" ] || { echo "FAIL $p: not in this store"; rc=1; continue; }
  echo "== $p"
  # 1 row
  if grep -qx -F "$p" "$T/outs"; then step row "PASS (served row names this out)"; else step row FAIL; why="$why no served row names this out;"; fi
  # 2 drv
  d=$(nix-store -q --deriver "$p" 2>/dev/null)
  if bash "$here/drv-gate.sh" $mode "$p" > "$T/drv" 2>&1; then step drv "PASS $mode ($(tail -1 "$T/drv" | sed 's/^PASS [^ ]* //'))"
  else step drv FAIL; grep -E '^(FAIL A|WARN)' "$T/drv" | head -8 | sed 's/^/    /'; why="$why drv-gate;"; fi
  grep '^EXEMPT' "$T/drv" | cut -c1-400 | sed 's/^/    /'
  # 3 check: every output of the deriver rebuilt bit-identical
  if [ "${GATE_SKIP_CHECK:-0}" = 1 ]; then step check "SKIPPED (GATE_SKIP_CHECK=1: no stamp)"; nostamp=1
  else nostamp=""
    case "$d" in /nix/store/*.drv)
      outs=$(nix-store -q --outputs "$d" | tr '\n' ' ')
      if nix-store --realise --check "$d" > "$T/check" 2>&1; then step check "PASS (SAME: $outs)"
      else step check "FAIL ($(grep -m1 -iE 'differ|may not be deterministic|error' "$T/check" | cut -c1-160))"; why="$why --check;"; fi ;;
    *) step check "FAIL (no deriver)"; why="$why no deriver;" ;; esac
  fi
  # 4 publish-gate (includes the NAR out checks)
  if bash "$here/publish-gate.sh" "$p" > "$T/gate" 2>&1; then step gate PASS; else step gate FAIL; grep -E '^(FAIL|  FAIL)' "$T/gate" | head -12 | cut -c1-300 | sed 's/^/    /'; why="$why publish-gate;"; fi
  grep -E '^ *(WARN|INFO)' "$T/gate" | head -8 | cut -c1-240 | sed 's/^ */    /'
  # 5 store form, 6 closure
  "$py" "$here/gate-checks.py" store "$p" > "$T/store" 2>&1 && step store PASS || { step store FAIL; grep '^FAIL B' "$T/store" | head -5 | sed 's/^/    /'; why="$why store form;"; }
  "$py" "$here/gate-checks.py" closure "$p" > "$T/clo" 2>&1 && step closure PASS || { step closure FAIL; grep '^FAIL B' "$T/clo" | head -5 | sed 's/^/    /'; why="$why closure denylist;"; }
  # 7 build log (LOOPHOLES classes 1-3, 5): only the host that built the out has it
  if [ -n "$d" ] && nix log "$d" > "$T/log" 2>/dev/null && [ -s "$T/log" ]; then
    "$py" "$here/gate-checks.py" log "$p" "$T/log" > "$T/logc" 2>&1 && step log "PASS $(tail -1 "$T/logc" | sed 's/^PASS [^ ]* //')" \
      || { step log FAIL; grep '^FAIL L' "$T/logc" | head -6 | cut -c1-260 | sed 's/^/    /'; why="$why build log;"; }
  else step log "FAIL (no build log for $d here: pre-submit runs on the host that built it)"; why="$why no build log;"; fi
  # 8 deps first: each reference is served under 8UNr, or appears earlier in this batch
  miss=""
  for r in $(nix-store -q --references "$p"); do
    [ "$r" = "$p" ] && continue
    case "$seen" in *" $r "*) continue ;; esac
    h=$(basename "$r" | cut -c1-32)
    [ "$(curl -s -o /dev/null -w '%{http_code}' "$CACHE/$h.narinfo")" = 200 ] && continue
    case "$batch" in *" $r "*) miss="$miss $(basename "$r")(later in this batch: order deps first)";; *) miss="$miss $(basename "$r")";; esac
  done
  if [ -z "$miss" ]; then step deps PASS; else step deps "FAIL (not served:$miss)"; why="$why unserved references;"; fi
  seen="$seen $p "
  if [ -z "$why" ]; then
    nh=$(nix path-info --json "$p" 2>/dev/null | "$py" -c 'import json,sys; d=json.load(sys.stdin); d=d[0] if isinstance(d,list) else next(iter(d.values())); print(d["narHash"])')
    if [ -z "${GATE_RECIPES:-}" ] && [ -z "$nostamp" ] && [ -n "$nh" ]; then
      key=$("$py" "$here/gate-checks.py" stampkey "$nh")
      printf '%s\t%s\t%s\t%s\t%s\n' "$p" "$nh" "$(date -u +%FT%TZ)" "$(uname -n)" "drv${mode#-}" > "$stamps/$key.ok"
      echo "PASS $p (stamp $stamps/$key.ok)"
    else echo "PASS $p (no stamp: ${GATE_RECIPES:+local recipes}${nostamp:+--check skipped})"; fi
  else echo "FAIL $p:$why"; rc=1; fi
done
exit $rc
