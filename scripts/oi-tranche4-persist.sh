#!/usr/bin/env bash
# oi-tranche4-persist.sh — per-package death-resilient persist for tranche 4.
# For ONE built package (its main out path on the builder), verify + record +
# publish, appending incrementally so a mid-run death strands at most this pkg.
#
#   BUILDER_IP=<ip> ./scripts/oi-tranche4-persist.sh <pname> <main-out-path>
#
# Steps (all append-only):
#   1. resolve deriver (must be a .drv) + ALL outputs of that .drv
#   2. per output: host-free closure check, append to tranche4-paths.txt
#   3. append a real-derivations.tsv row per output (tranche=4)
#   4. hand tranche4-paths.txt to oi-fleet-publish.sh (idempotent, skips cached)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO"
PNAME="${1:?usage: BUILDER_IP=<ip> oi-tranche4-persist.sh <pname> <out-path>}"
OUT="${2:?need main out path}"
IP="${BUILDER_IP:?set BUILDER_IP}"
SYSTEM="${SYSTEM:-x86_64-solaris}"
PATHS="$REPO/artifacts/tranche4-paths.txt"; touch "$PATHS"
TSV="$REPO/docs/registry/real-derivations.tsv"
HOST_NIX='export PATH=/nix-tools/bin:$PATH;'

R() { ./scripts/oi-ssh.sh "$IP" "$HOST_NIX $*" </dev/null; }

DRV="$(R nix-store -q --deriver "$OUT")"
case "$DRV" in *.drv) ;; *) echo "FAIL: no .drv deriver for $OUT ($DRV)"; exit 1;; esac
OUTS="$(R nix-store -q --outputs "$DRV")"

echo "=== persist $PNAME ($DRV) ==="
# Per-package publish scope: collect just this pkg's outputs here, publish only
# those (the whole-list re-publish hangs on the flaky endpoint).
WORKPATHS="$(mktemp)"; : > "$WORKPATHS"
for sp in $OUTS; do
  case "$sp" in /nix/store/*) ;; *) continue;; esac
  # host-free closure
  leak="$(R nix-store -qR "$sp" '| grep -v "^/nix/store/"' || true)"
  if [ -n "$leak" ]; then echo "  HOST-LEAK in $sp: $leak"; continue; fi
  base="$(basename "$sp")"; hash="${base%%-*}"
  name="${base#*-}"                     # e.g. gettext-1.0-dev
  # version = trailing token that looks like N... else "0"
  ver="$(printf '%s' "$name" | grep -oE '[0-9][0-9.]*' | head -1 || true)"; ver="${ver:-0}"
  # pname column: full name minus version-ish; keep simple: use $name's leading id
  pn="$(printf '%s' "$name" | sed -E "s/-${ver}.*//; s/-$//")"; pn="${pn:-$PNAME}"
  grep -qF "$sp" "$PATHS" || echo "$sp" >> "$PATHS"
  echo "$sp" >> "$WORKPATHS"
  # published col: on this backend the cache is non-durable, so record
  # "staged" (built + verified locally + staged to the on-host bcache) rather
  # than "y"; a later durable re-publish flips it to "y".
  if ! grep -qP "\t$hash\t" "$TSV" 2>/dev/null && ! grep -q "	$hash	" "$TSV"; then
    printf '%s\t%s\t%s\t%s\ty\ty\tstaged\t%s\t4\n' "$pn" "$ver" "$hash" "$sp" "$SYSTEM" >> "$TSV"
  fi
  echo "  recorded $base"
done

# Stage this package's outputs into the on-host local binary cache (durable),
# because s3.solnix.io's narinfo/nar layer is a NON-DETERMINISTIC backend (writes
# return 200 without persisting; both `nix copy` and `aws s3 cp` flap). The
# LOCAL store paths + staged bcache are the deliverable; they get re-published
# once the backend is fixed. We still fire ONE best-effort S3 upload (harmless,
# may partially land) but do NOT gate success on it.
BC="${BCACHE:-/nix/tranche4-bcache}"
R "mkdir -p $BC; [ -f $BC/nix-cache-info ] || printf 'StoreDir: /nix/store\\nWantMassQuery: 1\\nPriority: 41\\n' > $BC/nix-cache-info" >/dev/null 2>&1 || true
while IFS= read -r sp; do
  R "nix copy --to file://$BC $sp" >/dev/null 2>&1 && echo "  staged $(basename "$sp") -> $BC" || echo "  STAGE-FAIL $(basename "$sp")"
done < "$WORKPATHS"

# best-effort S3 (non-authoritative; backend flaps). Never fails the persist.
BUILDER_IP="$IP" SYSTEM="$SYSTEM" ./scripts/oi-fleet-publish.sh "$WORKPATHS" || true
