#!/usr/bin/env bash
# sparc-publish-sun.sh <store-path...> — publish sparcv9 store closures built on
# the real UltraSPARC `sun` to the durable solnix.io S3 cache. Mirrors
# oi-cache-publish.sh but SSHes to gburd@sun directly (not the EC2 auto-
# discovery). Exports each closure from sun -> imports to a local temp store ->
# signs with the cache key -> nix copy --to s3. Idempotent (skips narinfo-
# present). Creds + signing key read from sops IN-SHELL only.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO"
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"; export SOPS_AGE_KEY_FILE
SOPS() { nix run nixpkgs#sops -- "$@"; }
SUN="gburd@sun"
HOST_NIX='export PATH=/nix/nix-tools/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:$PATH; export NIX_CONF_DIR=/nix/nix-tools/etc/nix;'
S3='s3://solnix-cache?endpoint=s3.solnix.io&region=us-east-1&scheme=https'

[ "$#" -ge 1 ] || { echo "usage: $0 <store-path...>" >&2; exit 1; }

eval "$(SOPS --decrypt secrets/s3-cache.yaml \
  | awk -F': ' '/aws_access_key_id|aws_secret_access_key/{print "export "toupper($1)"=\""$2"\""}')"
export AWS_DEFAULT_REGION=us-east-1 AWS_EC2_METADATA_DISABLED=true
[ -n "${AWS_ACCESS_KEY_ID:-}" ] || { echo "FATAL: no S3 creds from sops" >&2; exit 1; }

if ! curl -fsS https://s3.solnix.io/solnix-cache/nix-cache-info >/dev/null 2>&1; then
  printf 'StoreDir: /nix/store\n' | aws --endpoint-url https://s3.solnix.io s3 cp - s3://solnix-cache/nix-cache-info
fi

WORK="$(mktemp -d)"
cleanup() { [ -f "$WORK/sign.key" ] && { shred -u "$WORK/sign.key" 2>/dev/null || rm -f "$WORK/sign.key"; }; rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT
# Persistent import store (env TS_DIR) so the large shared seed/gcc closure is
# imported ONCE and reused across invocations; default to a stable dir.
TS="${TS_DIR:-$HOME/.cache/solnix-sparc-publish-store}"; mkdir -p "$TS"
umask 077
SOPS --decrypt --extract '["cache_signing_key"]' secrets/cache-signing.yaml > "$WORK/sign.key"

for SP in "$@"; do
  echo "=== publishing $SP ==="
  hash="$(basename "$SP" | cut -d- -f1)"
  if curl -fsS "https://s3.solnix.io/solnix-cache/$hash.narinfo" >/dev/null 2>&1; then
    echo "  already in cache — skipping"; continue
  fi
  echo "  exporting closure from sun + importing locally..."
  ssh "$SUN" "$HOST_NIX nix-store --export \$(nix-store -qR $SP)" | nix-store --store "$TS" --import >/dev/null
  echo "  signing closure..."
  nix store sign --store "$TS" -k "$WORK/sign.key" --recursive "$SP"
  echo "  copying to S3..."
  nix copy --store "$TS" --to "$S3" "$SP"
done
echo "=== done. published: $* ==="
echo "verify: https://s3.solnix.io/solnix-cache  key: cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8="
