#!/usr/bin/env bash
# sparc-t2-publish.sh — durable publish for sparc tranche-2 outputs.
# Fixes the "copying 0 paths" skip that left tranche-1 narinfos at 404: builds a
# local file:// binary cache (nix copy --refresh ALWAYS writes narinfo+nar
# there, no destination-present short-circuit), then `aws s3 cp --recursive`
# that cache dir up to S3 (raw PUTs, not nix copy's want-mass query). Then
# VERIFIES the narinfo sticks on origin (re-read 3x over ~30s). Append-only:
# skips a path whose narinfo is already durably present.
#   ./scripts/sparc-t2-publish.sh <store-path> [store-path ...]
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO"
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
SUN="gburd@sun"
HOST_NIX='export PATH=/nix/nix-tools/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:$PATH; export NIX_CONF_DIR=/nix/nix-tools/etc/nix;'
[ "$#" -ge 1 ] || { echo "usage: $0 <store-path> ..." >&2; exit 1; }
PATHS=("$@")

eval "$(sops --decrypt secrets/s3-cache.yaml \
  | awk -F': ' '/aws_access_key_id|aws_secret_access_key/{print "export "toupper($1)"=\""$2"\""}')"
export AWS_DEFAULT_REGION=us-east-1 AWS_EC2_METADATA_DISABLED=true
[ -n "${AWS_ACCESS_KEY_ID:-}" ] || { echo "FATAL: no S3 creds from sops" >&2; exit 1; }
S3BUCKET="s3://solnix-cache"
AWSFLAGS=(--endpoint-url https://s3.solnix.io --region us-east-1)

WORK="$(mktemp -d)"
cleanup() { [ -f "$WORK/sign.key" ] && { shred -u "$WORK/sign.key" 2>/dev/null || rm -f "$WORK/sign.key"; }; rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT
TS="$WORK/store"; CACHE="$WORK/cache"; mkdir -p "$TS" "$CACHE"
umask 077
sops --decrypt --extract '["cache_signing_key"]' secrets/cache-signing.yaml > "$WORK/sign.key"
printf 'StoreDir: /nix/store\nWantMassQuery: 1\nPriority: 30\n' > "$CACHE/nix-cache-info"

verify_sticky() {
  local h="$1" ok=0
  for i in 1 2 3; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "https://s3.solnix.io/solnix-cache/$h.narinfo" || echo 000)"
    echo "    verify[$i]: $code"
    [ "$code" = "200" ] && ok=$((ok+1))
    sleep 8
  done
  [ "$ok" -ge 3 ]
}

for SP in "${PATHS[@]}"; do
  hash="$(basename "$SP" | cut -d- -f1)"
  echo "=== $SP ==="
  if curl -fsS "https://s3.solnix.io/solnix-cache/$hash.narinfo" >/dev/null 2>&1; then
    echo "  narinfo already present — skip"; continue
  fi
  echo "  export closure from sun + import locally..."
  ssh "$SUN" "$HOST_NIX nix-store --export \$(nix-store -qR $SP)" \
    | nix-store --store "$TS" --import >/dev/null
  echo "  sign + write to local file:// cache..."
  nix store sign --store "$TS" -k "$WORK/sign.key" --recursive "$SP"
  nix copy --refresh --store "$TS" --to "file://$CACHE?compression=xz" "$SP"
  echo "  aws s3 cp cache -> S3 (raw PUTs)..."
  aws "${AWSFLAGS[@]}" s3 cp "$CACHE/" "$S3BUCKET/" --recursive \
    --exclude "nix-cache-info" >/dev/null
  if verify_sticky "$hash"; then
    echo "  DURABLE-STICKY $SP"
  else
    echo "  WARN not-sticky $SP (narinfo did not hold 3x)"
  fi
done
echo "=== done: ${PATHS[*]} ==="
