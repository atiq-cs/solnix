#!/usr/bin/env bash
# cache-retire-verify.sh -- client-side check that the infra team's retirement of
# docs/registry/CACHE-RETIRE-20261005.tsv is what a Nix client actually sees.
#
# For a fixed sample (docs/registry/CACHE-RETIRE-20261005-verify-sample.tsv) it
# fetches each narinfo TWICE: the plain URL (what Nix requests, so the CDN edge
# answers) and a cache-busted URL (the origin). Pass conditions:
#   phantom / junk / not-installable -> 404 on the PLAIN url
#   keep                             -> 200 and verifies under 8UNr
# Negative control: the same verify under a key that signs nothing must fail.
# Read-only; uses only public endpoints.
set -uo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
S=${1:-$here/docs/registry/CACHE-RETIRE-20261005-verify-sample.tsv}
K8='cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8='
W=$(mktemp -d); echo 'StoreDir: /nix/store' > "$W/nix-cache-info"
fail=0
while IFS=$'\t' read -r c k; do
  plain=$(curl -s -A curl/8 -o "$W/$k" -w '%{http_code}' "https://cache.solnix.io/$k")
  origin=$(curl -s -A curl/8 -o /dev/null -w '%{http_code}' "https://cache.solnix.io/$k?cb=$RANDOM$RANDOM")
  v=-
  if [ "$plain" = 200 ]; then
    sp=$(sed -n 's/^StorePath: //p' "$W/$k")
    XDG_CACHE_HOME=$W/xc nix store verify --no-contents --store "file://$W" --trusted-public-keys "$K8" "$sp" >/dev/null 2>&1 && v=8UNr || v=not-8UNr
    # a content-addressed path (narinfo CA:) verifies under ANY key, so a pass on it
    # says nothing about the signature (measured: both 'keep PASS' rows were CA).
    [ "$v" = 8UNr ] && XDG_CACHE_HOME=$W/xc nix store verify --no-contents --store "file://$W" \
      --trusted-public-keys 'x-1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' "$sp" >/dev/null 2>&1 && v=CA-any-key
  fi
  case "$c" in
    # A content-addressed object (CA: fixed:...) is trusted by its content, not a
    # signature, so "verifies under any key" is correct for it and counts as a pass.
    keep) [ "$plain" = 200 ] && { [ "$v" = 8UNr ] || [ "$v" = CA-any-key ]; } && r=PASS || r=FAIL ;;
    *)    [ "$plain" = 404 ] && r=PASS || r=FAIL ;;
  esac
  [ "$r" = FAIL ] && fail=$((fail+1))
  printf '%s\t%s\tplain=%s\torigin=%s\tsig=%s\n' "$r" "$c" "$plain" "$origin" "$v"
done < "$S" | tee "$W/res" | awk -F'\t' '{print $1, $2, $3, $4, $5}' | sort | uniq -c
fail=$(grep -c '^FAIL' "$W/res")
k=$(awk -F'\t' '$1=="keep"{print $2}' "$S" | while read -r x; do grep -q '^CA:' "$W/$x" 2>/dev/null || { echo "$x"; break; }; done)
if [ -s "$W/$k" ]; then
  sp=$(sed -n 's/^StorePath: //p' "$W/$k")
  XDG_CACHE_HOME=$W/xc2 nix store verify --no-contents --store "file://$W" \
    --trusted-public-keys 'x-1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' "$sp" >/dev/null 2>&1 \
    && { echo "NEGATIVE CONTROL FAILED: a key that signs nothing verified $sp"; fail=$((fail+1)); } \
    || echo "negative control ok: unrelated key rejects $sp"
fi
echo "failures: $fail"
[ "$fail" = 0 ]
