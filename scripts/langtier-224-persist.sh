#!/usr/bin/env bash
# langtier-224-persist.sh — per-package death-resilient persist for the 2.24
# language-runtime tier. For ONE built store path on the 2.24 builder:
#   1. resolve deriver (.drv) + all its outputs
#   2. host-free closure check per output (all /nix/store; /lib/64 libc-family
#      is loaded at runtime by the RTLD, not a store dep, so it never appears in
#      a `nix-store -qR` closure — this checks the recorded closure only)
#   3. append registry rows (real-derivations-224.tsv) + artifacts/langtier-224-paths.txt
#   4. sign + upload each closure to s3.solnix.io, then GET-verify on the
#      durable cache.solnix.io with a cache-busting query string
#
#   BUILDER_IP=3.148.209.93 ./scripts/langtier-224-persist.sh <pname> <version> <main-out-path>
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO"
PNAME="${1:?usage: BUILDER_IP=<ip> langtier-224-persist.sh <pname> <version> <out-path>}"
VER="${2:?need version}"
OUT="${3:?need main out path}"
IP="${BUILDER_IP:?set BUILDER_IP}"
SYSTEM="${SYSTEM:-x86_64-solaris}"
PATHS="$REPO/artifacts/langtier-224-paths.txt"; mkdir -p "$REPO/artifacts"; touch "$PATHS"
TSV="$REPO/docs/registry/real-derivations-224.tsv"
KEY=~/.ssh/id_ed25519
HOST_NIX='source /etc/profile.d/nix-illumos.sh;'
R() { ssh -o StrictHostKeyChecking=no -i "$KEY" "root@$IP" "$HOST_NIX $*" </dev/null; }

DRV="$(R nix-store -q --deriver "$OUT")"
case "$DRV" in *.drv) ;; *) echo "FAIL: no .drv deriver for $OUT ($DRV)"; exit 1;; esac
OUTS="$(R nix-store -q --outputs "$DRV")"
echo "=== persist $PNAME-$VER ($DRV) ==="

# sops creds/keys
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"; export SOPS_AGE_KEY_FILE
SOPS() { nix run nixpkgs#sops -- "$@"; }
S3='s3://solnix-cache?endpoint=s3.solnix.io&region=us-east-1&scheme=https'
eval "$(SOPS --decrypt secrets/s3-cache.yaml \
  | awk -F': ' '/aws_access_key_id|aws_secret_access_key/{print "export "toupper($1)"=\""$2"\""}')"
export AWS_DEFAULT_REGION=us-east-1 AWS_EC2_METADATA_DISABLED=true
[ -n "${AWS_ACCESS_KEY_ID:-}" ] || { echo "FATAL: no S3 creds from sops" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'shred -u "$WORK/sign.key" 2>/dev/null||rm -f "$WORK/sign.key"; rm -rf "$WORK"' EXIT
TS="$WORK/store"; mkdir -p "$TS"; umask 077
SOPS --decrypt --extract '["cache_signing_key"]' secrets/cache-signing.yaml > "$WORK/sign.key"

for sp in $OUTS; do
  case "$sp" in /nix/store/*) ;; *) continue;; esac
  leak="$(R nix-store -qR "$sp" '| grep -v "^/nix/store/"' || true)"
  if [ -n "$leak" ]; then echo "  HOST-LEAK in $sp: $leak"; continue; fi
  base="$(basename "$sp")"; hash="${base%%-*}"
  # registry row (append-only, one per output)
  suffix="${base#*-}"; sub="${suffix#$PNAME-$VER}"; sub="${sub#-}"
  pn="$PNAME"; [ -n "$sub" ] && pn="$PNAME-$sub"
  grep -qF "$sp" "$PATHS" || echo "$sp" >> "$PATHS"
  if ! grep -q "	$hash	" "$TSV" 2>/dev/null; then
    printf '%s\t%s\t%s\t%s\ty\ty\tpublished\t%s\t2.24\n' "$pn" "$VER" "$hash" "$sp" "$SYSTEM" >> "$TSV"
  fi
  # export closure host->local temp store, sign, upload
  if ! R nix-store --export '$(nix-store -qR '"$sp"')' | nix-store --store "$TS" --import >/dev/null 2>>"$WORK/err"; then
    echo "  FAIL export/import $base"; continue
  fi
  nix store sign --store "$TS" -k "$WORK/sign.key" --recursive "$sp" 2>>"$WORK/err" || { echo "  FAIL sign $base"; continue; }
  nix copy --refresh --store "$TS" --to "$S3" "$sp" 2>>"$WORK/err" || { echo "  FAIL copy $base"; continue; }
  echo "  uploaded $base"
done

# durable-verify each output's narinfo on cache.solnix.io with cache-bust
echo "=== verify durable (cache.solnix.io, cache-bust) ==="
ok=0; bad=0
for sp in $OUTS; do
  case "$sp" in /nix/store/*) ;; *) continue;; esac
  hash="$(basename "$sp" | cut -d- -f1)"
  code="$(curl -s -o /dev/null -w '%{http_code}' "https://cache.solnix.io/$hash.narinfo?cb=$(date +%s%N)")"
  if [ "$code" = 200 ]; then echo "  DURABLE $hash ($code)"; ok=$((ok+1)); else echo "  MISSING $hash ($code)"; bad=$((bad+1)); fi
done
echo "=== $PNAME-$VER durable=$ok missing=$bad ==="
[ -s "$WORK/err" ] && { echo "--- errors ---"; tail -15 "$WORK/err"; } || true
