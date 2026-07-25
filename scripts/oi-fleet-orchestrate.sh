#!/usr/bin/env bash
# oi-fleet-orchestrate.sh — schedule (pkg,cc) build jobs across the illumos
# builder fleet. Atomic job claim via `mkdir` (portable, no flock fd tricks).
# Each FLEET entry is one worker slot; repeat an IP for more concurrency on a
# big host. Results: $OUTDIR/<pkg>.<cc>.{path,log}.
#
# Usage: FLEET="ip ip ip2" oi-fleet-orchestrate.sh <outdir> <pkg:cc...>
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO"
SSH() { ./scripts/oi-ssh.sh "$@"; }
HOST_ENV='export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:/usr/sbin; export NIX_CONF_DIR=/nix-tools/etc/nix;'
REMOTE=/var/tmp/solnix-pkgs

OUTDIR="${1:?usage: FLEET=... oi-fleet-orchestrate.sh <outdir> <pkg:cc...>}"; shift
mkdir -p "$OUTDIR"
JOBS=("$@")
FLEET=(${FLEET:-})
[ "${#FLEET[@]}" -gt 0 ] || { echo "FATAL: set FLEET env" >&2; exit 1; }

# lay each job down as a claimable marker dir path. Fresh queue dir per run.
QDIR="$OUTDIR/.q.$$"; mkdir -p "$QDIR"
i=0
for j in "${JOBS[@]}"; do printf '%s\n' "$j" > "$QDIR/$(printf '%04d' $i).job"; i=$((i+1)); done
CLAIM="$OUTDIR/.claim.$$"; mkdir -p "$CLAIM"

build_one() { # ip pkg cc
  local ip="$1" pkg="$2" cc="$3" sp
  sp=$(timeout 5400 ./scripts/oi-ssh.sh "$ip" "$HOST_ENV cd $REMOTE/pkgs/illumos && nix-build packages.nix -A $pkg.$cc --no-out-link" 2> "$OUTDIR/$pkg.$cc.log")
  if [ -n "$sp" ] && [[ "$sp" == /nix/store/* ]]; then
    echo "$sp" > "$OUTDIR/$pkg.$cc.path"
    echo "OK   [$ip] $pkg.$cc -> $sp"
  else
    echo "FAIL [$ip] $pkg.$cc"
  fi
}

worker() {
  local ip="$1" jf pkg cc line
  for jf in "$QDIR"/*.job; do
    [ -e "$jf" ] || continue
    local base; base=$(basename "$jf" .job)
    # atomic claim: mkdir succeeds for exactly one worker.
    if mkdir "$CLAIM/$base" 2>/dev/null; then
      line=$(cat "$jf")
      pkg="${line%%:*}"; cc="${line##*:}"
      build_one "$ip" "$pkg" "$cc"
    fi
  done
}

for ip in "${FLEET[@]}"; do worker "$ip" & done
wait
echo "=== orchestration done ==="
