#!/usr/bin/env bash
# oi-tranche3-persist.sh — per-package death-resilient persist for tranche 3.
# For ONE built package (its main out path on the builder), verify + record +
# publish, appending incrementally so a mid-run death strands at most this pkg.
#
#   BUILDER_IP=<ip> ./scripts/oi-tranche3-persist.sh <pname> <main-out-path>
#
# Steps (all append-only):
#   1. resolve deriver (must be a .drv) + ALL outputs of that .drv
#   2. per output: host-free closure check, append to tranche3-paths.txt
#   3. append a real-derivations.tsv row per output (tranche=3)
#   4. hand tranche3-paths.txt to oi-fleet-publish.sh (idempotent, skips cached)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO"
PNAME="${1:?usage: BUILDER_IP=<ip> oi-tranche3-persist.sh <pname> <out-path>}"
OUT="${2:?need main out path}"
IP="${BUILDER_IP:?set BUILDER_IP}"
SYSTEM="${SYSTEM:-x86_64-solaris}"
PATHS="$REPO/artifacts/tranche3-paths.txt"; touch "$PATHS"
TSV="$REPO/docs/registry/real-derivations.tsv"
HOST_NIX='export PATH=/nix-tools/bin:$PATH;'

R() { ./scripts/oi-ssh.sh "$IP" "$HOST_NIX $*" </dev/null; }

DRV="$(R nix-store -q --deriver "$OUT")"
case "$DRV" in *.drv) ;; *) echo "FAIL: no .drv deriver for $OUT ($DRV)"; exit 1;; esac
OUTS="$(R nix-store -q --outputs "$DRV")"

echo "=== persist $PNAME ($DRV) ==="
for sp in $OUTS; do
  case "$sp" in /nix/store/*) ;; *) continue;; esac
  # host-free closure
  leak="$(R nix-store -qR "$sp" '| grep -v "^/nix/store/"' || true)"
  if [ -n "$leak" ]; then echo "  HOST-LEAK in $sp: $leak"; continue; fi
  base="$(basename "$sp")"; hash="${base%%-*}"
  name="${base#*-}"                     # e.g. gettext-1.0-dev
  # version = trailing token that looks like N... else "0"
  ver="$(printf '%s' "$name" | grep -oE '[0-9][0-9.]*' | head -1)"; ver="${ver:-0}"
  # pname column: full name minus version-ish; keep simple: use $name's leading id
  pn="$(printf '%s' "$name" | sed -E "s/-${ver}.*//; s/-$//")"; pn="${pn:-$PNAME}"
  grep -qF "$sp" "$PATHS" || echo "$sp" >> "$PATHS"
  # runs col left blank (spot-checked separately); mark y for deriver+hermetic
  if ! grep -qP "\t$hash\t" "$TSV" 2>/dev/null && ! grep -q "	$hash	" "$TSV"; then
    printf '%s\t%s\t%s\t%s\ty\ty\ty\t%s\t3\n' "$pn" "$ver" "$hash" "$sp" "$SYSTEM" >> "$TSV"
  fi
  echo "  recorded $base"
done

BUILDER_IP="$IP" SYSTEM="$SYSTEM" ./scripts/oi-fleet-publish.sh "$PATHS"
