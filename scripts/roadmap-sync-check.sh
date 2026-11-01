#!/usr/bin/env bash
# roadmap-sync-check: compare the published roadmap (solnix.io/data/roadmap.json)
# against the actual build state in this repo, and flag drift. Run before/after
# any milestone (release, new arch phase, RISC-V R-P bump, GPU runtime). Does NOT
# edit the site -- it reports what the site should say so the update is deliberate.
#
# Usage: scripts/roadmap-sync-check.sh [path-to-roadmap.json]
# Default site path is a sibling checkout: ../solnix.io/site/data/roadmap.json
set -uo pipefail
cd "$(dirname "$0")/.."

RM="${1:-../solnix.io/site/data/roadmap.json}"
REG="docs/registry/real-derivations.tsv docs/registry/recipes.tsv"  # was real-derivations-224.tsv, gone: every count read 0
RISCV=docs/design-riscv-port.md

# --- ground truth from the repo ---
x86=$(cat $REG 2>/dev/null | grep -c x86_64-solaris)
aa=$(cat $REG 2>/dev/null | grep -c aarch64-solaris)
sp=$(cat $REG 2>/dev/null | grep -c sparcv9)
rp=$(grep -oE 'R-P[0-9]+' "$RISCV" 2>/dev/null | sort -tP -k2 -n | tail -1)
rel=$(ls RELEASE-NOTES-*.md 2>/dev/null | head -1 | sed -E 's/.*NOTES-(.*)\.md/\1/')
gpu_compile=$( [ -d src/drm-port ] && echo yes || echo no )

echo "== solnix ground truth =="
echo "  x86_64 real derivations : $x86"
echo "  aarch64 real derivations: $aa"
echo "  sparcv9 real derivations: $sp"
echo "  RISC-V phase reached    : ${rp:-none}"
echo "  release cut             : ${rel:-none}"
echo "  GPU stack compiles      : $gpu_compile (src/drm-port present)"
echo

if [ ! -f "$RM" ]; then
  echo "roadmap.json not found at: $RM"
  echo "  (pass the path, or check out solnix.io as a sibling of solnix)"
  exit 3
fi

# --- what the site currently claims ---
echo "== published roadmap states (data/roadmap.json) =="
jq -r '.phases[] | "  phase \(.number) [\(.state)] \(.name)"' "$RM" 2>/dev/null
echo

# --- drift heuristics: the repo state IMPLIES a minimum roadmap state ---
warn=0
imply() { # phase, min-state, why
  local n="$1" min="$2" why="$3"
  local cur; cur=$(jq -r --argjson n "$n" '.phases[]|select(.number==$n)|.state' "$RM" 2>/dev/null)
  # rank: planned < in progress < done
  rank() { case "$1" in done|live) echo 2;; "in progress") echo 1;; *) echo 0;; esac; }
  if [ "$(rank "$cur")" -lt "$(rank "$min")" ]; then
    echo "  DRIFT: phase $n is '$cur' but should be at least '$min' -- $why"
    warn=1
  fi
}
echo "== drift check =="
[ "$x86" -gt 100 ] && { imply 0 done "cache/infra clearly live"; imply 1 done "$x86 x86_64 derivations"; }
[ -n "$rel" ] && imply 2 done "release $rel is cut"
[ "$aa" -gt 5 ]  && imply 3 "in progress" "$aa aarch64 derivations"
[ "$sp" -gt 5 ]  && imply 4 "in progress" "$sp sparcv9 derivations"
[ -n "$rp" ]     && imply 5 "in progress" "RISC-V at $rp"
[ "$gpu_compile" = yes ] && imply 6 "in progress" "GPU stack compiles (src/drm-port)"
grep -q '^cosmic-comp	' docs/registry/recipes.tsv && imply 7 "in progress" "COSMIC desktop rows in the registry"
[ "$warn" -eq 0 ] && echo "  no drift: the published roadmap matches the repo state."
echo
echo "To fix drift: edit ../solnix.io/site/data/roadmap.json (states: planned|in progress|done),"
echo "then 'bash gen-roadmap.sh phases data/roadmap.json' to preview. CI regenerates the page on push."
exit $warn
