#!/usr/bin/env bash
# sparc-cache-publish.sh — sign + publish the pure sparc hello/stdenv closures
# from `sun` to the solnix.io S3 cache. Adapts scripts/oi-cache-publish.sh to
# the sun host (ssh gburd@sun, nix at /nix/nix-tools) instead of the AWS EC2
# x86 host. Append-only: skips paths whose narinfo already exists.
#   ./scripts/sparc-cache-publish.sh <store-path> [store-path ...]
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE

SUN="gburd@sun"
HOST_NIX='export PATH=/nix/nix-tools/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:$PATH; export NIX_CONF_DIR=/nix/nix-tools/etc/nix;'

[ "$#" -ge 1 ] || { echo "usage: $0 <store-path> [store-path ...]" >&2; exit 1; }
PATHS=("$@")

S3='s3://solnix-cache?endpoint=s3.solnix.io&region=us-east-1&scheme=https'
eval "$(sops --decrypt secrets/s3-cache.yaml \
  | awk -F': ' '/aws_access_key_id|aws_secret_access_key/{print "export "toupper($1)"=\""$2"\""}')"
export AWS_DEFAULT_REGION=us-east-1 AWS_EC2_METADATA_DISABLED=true
[ -n "${AWS_ACCESS_KEY_ID:-}" ] || { echo "FATAL: no S3 creds from sops" >&2; exit 1; }

WORK="$(mktemp -d)"
cleanup() { [ -f "$WORK/sign.key" ] && { shred -u "$WORK/sign.key" 2>/dev/null || rm -f "$WORK/sign.key"; }; rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT
TS="$WORK/store"; mkdir -p "$TS"
umask 077
sops --decrypt --extract '["cache_signing_key"]' secrets/cache-signing.yaml > "$WORK/sign.key"

for SP in "${PATHS[@]}"; do
  echo "=== publishing $SP ==="
  hash="$(basename "$SP" | cut -d- -f1)"
  if curl -fsS "https://s3.solnix.io/solnix-cache/$hash.narinfo" >/dev/null 2>&1; then
    echo "  already in cache (narinfo present) — skipping"
    continue
  fi
  echo "  exporting closure from sun + importing locally..."
  ssh "$SUN" "$HOST_NIX nix-store --export \$(nix-store -qR $SP)" \
    | nix-store --store "$TS" --import >/dev/null
  echo "  signing closure..."
  nix store sign --store "$TS" -k "$WORK/sign.key" --recursive "$SP"
  echo "  copying to S3..."
  nix copy --store "$TS" --to "$S3" "$SP"
done

echo "=== done. published: ${PATHS[*]} ==="
