#!/usr/bin/env bash
# sun-cache-publish.sh — sign + publish sparcv9-solaris store closures built on
# the `sun` host (Nix 2.3.16, no S3) to the solnix.io S3 binary cache.
# Bridges host store paths to the cache: `nix-store --export` on sun over ssh ->
# `nix-store --import` into a LOCAL temp store -> `nix store sign` -> `nix copy
# --to s3://...` from the local box (local Nix has working S3; 2.3.16 does not).
# Idempotent: skips paths whose narinfo already exists in the cache.
#
#   ./scripts/sun-cache-publish.sh <store-path ...>
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE
SOPS() { sops "$@"; }

HOST="${SUN_HOST:-gburd@sun}"
HOST_NIX='export PATH=/nix/nix-tools/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:$PATH; export NIX_CONF_DIR=/nix/nix-tools/etc/nix;'

[ "$#" -ge 1 ] || { echo "usage: $0 <store-path ...>" >&2; exit 1; }
PATHS=("$@")

S3='s3://solnix-cache?endpoint=s3.solnix.io&region=us-east-1&scheme=https'
eval "$(SOPS --decrypt secrets/s3-cache.yaml \
  | awk -F': ' '/aws_access_key_id|aws_secret_access_key/{print "export "toupper($1)"=\""$2"\""}')"
export AWS_DEFAULT_REGION=us-east-1 AWS_EC2_METADATA_DISABLED=true
[ -n "${AWS_ACCESS_KEY_ID:-}" ] || { echo "FATAL: no S3 creds from sops" >&2; exit 1; }

if ! curl -fsS "https://s3.solnix.io/solnix-cache/nix-cache-info?x=$RANDOM" >/dev/null 2>&1; then
  echo "creating nix-cache-info (StoreDir: /nix/store)"
  printf 'StoreDir: /nix/store\n' \
    | aws --endpoint-url https://s3.solnix.io s3 cp - s3://solnix-cache/nix-cache-info
fi

WORK="$(mktemp -d)"
cleanup() {
  [ -f "$WORK/sign.key" ] && { shred -u "$WORK/sign.key" 2>/dev/null || rm -f "$WORK/sign.key"; }
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT
TS="$WORK/store"; mkdir -p "$TS"

umask 077
SOPS --decrypt --extract '["cache_signing_key"]' secrets/cache-signing.yaml > "$WORK/sign.key"

for SP in "${PATHS[@]}"; do
  echo "=== publishing $SP ==="
  hash="$(basename "$SP" | cut -d- -f1)"
  if curl -fsS "https://s3.solnix.io/solnix-cache/$hash.narinfo?x=$RANDOM" >/dev/null 2>&1; then
    echo "  already in cache (narinfo present) — skipping"
    continue
  fi
  echo "  exporting closure from sun + importing locally..."
  ssh "$HOST" "$HOST_NIX nix-store --export \$(nix-store -qR $SP)" \
    | nix-store --store "$TS" --import >/dev/null
  echo "  signing closure..."
  nix store sign --store "$TS" -k "$WORK/sign.key" --recursive "$SP"
  echo "  copying to S3..."
  nix copy --store "$TS" --to "$S3" "$SP"
  # durability: s3.solnix.io tiers to Backblaze B2 async; cache.solnix.io (the
  # durable CDN) serves only once synced. Poll until B2 has the narinfo.
  echo -n "  waiting for durable B2 sync (cache.solnix.io)"
  for i in $(seq 1 6); do
    if curl -fsS -o /dev/null "https://cache.solnix.io/$hash.narinfo?x=$RANDOM" 2>/dev/null; then
      echo " OK"; break
    fi
    echo -n "."; sleep 5
  done
  curl -fsS -o /dev/null "https://cache.solnix.io/$hash.narinfo?x=$RANDOM" 2>/dev/null \
    || echo " (still syncing — durable within minutes)"
done

echo "=== done. published: ${PATHS[*]} ==="
