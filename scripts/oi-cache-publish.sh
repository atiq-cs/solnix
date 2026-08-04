#!/usr/bin/env bash
# oi-cache-publish.sh — sign + publish illumos store closures to the solnix.io
# S3 binary cache (T2.3). Idempotent: re-running only re-uploads paths the cache
# is missing. Reads S3 creds and the cache signing key from sops IN-SHELL — never
# writes credentials or the secret key to a durable file.
#
#   ./scripts/oi-cache-publish.sh [store-path ...]
#
# With no args, publishes the default set: the bootable world (system-path
# closure) + the gate proto (seed slice). Store paths live on the illumos build
# host (Nix 2.3.16, no S3 support); this script bridges them to the cache via
# `nix-store --export` on the host -> `nix-store --import` into a LOCAL temp
# store -> `nix store sign` -> `nix copy --to s3://...` from the local box
# (local Nix has working S3; 2.3.16 does not — see docs/cache.md §gotchas).
#
# Env / prereqs (dev box):
#   - SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt (the repo age key)
#   - local `nix` with S3 store support (2.4+), `aws` cli, `sops`
#   - the illumos host reachable via scripts/oi-ssh.sh (IP auto-discovered)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE
SOPS() { nix run nixpkgs#sops -- "$@"; }   # local sops via nixpkgs (no global install needed)

# --- discover the illumos build host --------------------------------------
IP="${SOLNIX_BUILD_IP:-$(aws ec2 describe-instances --profile numa --region us-east-2 \
  --filters Name=tag:Name,Values=solnix-build Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)}"
[ -n "$IP" ] && [ "$IP" != "None" ] || { echo "FATAL: no running solnix-build host" >&2; exit 1; }
echo "illumos build host: $IP"

HOST_NIX='export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:$PATH; export NIX_CONF_DIR=/nix-tools/etc/nix;'

# --- default publish set (resolved to VALID built paths on the host) -------
# The bootable world is the illumos-system-path closure; the seed is the gate
# proto FOD. These are the concrete, currently-built store paths on the host.
if [ "$#" -eq 0 ]; then
  set -- \
    /nix/store/b1q9mlpjpy9k31j0q6mjmc1h7l99ha2s-system-path \
    /nix/store/y9d8x07cnxp9pyhb75v8bsd50cv6h98w-illumos-gate-proto
fi
PATHS=("$@")

# --- S3 target + creds (in-shell only) -------------------------------------
S3='s3://solnix-cache?endpoint=s3.solnix.io&region=us-east-1&scheme=https'
eval "$(SOPS --decrypt secrets/s3-cache.yaml \
  | awk -F': ' '/aws_access_key_id|aws_secret_access_key/{print "export "toupper($1)"=\""$2"\""}')"
export AWS_DEFAULT_REGION=us-east-1 AWS_EC2_METADATA_DISABLED=true
[ -n "${AWS_ACCESS_KEY_ID:-}" ] || { echo "FATAL: no S3 creds from sops" >&2; exit 1; }

# --- ensure nix-cache-info exists at the bucket root -----------------------
if ! curl -fsS https://s3.solnix.io/solnix-cache/nix-cache-info >/dev/null 2>&1; then
  echo "creating nix-cache-info (StoreDir: /nix/store)"
  printf 'StoreDir: /nix/store\n' \
    | aws --endpoint-url https://s3.solnix.io s3 cp - s3://solnix-cache/nix-cache-info
fi

# --- work dir (local temp store + signing key), cleaned on exit ------------
WORK="$(mktemp -d)"
cleanup() {
  [ -f "$WORK/sign.key" ] && { shred -u "$WORK/sign.key" 2>/dev/null || rm -f "$WORK/sign.key"; }
  rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT
TS="$WORK/store"; mkdir -p "$TS"

# signing key -> mode-0600 temp file (nix store sign needs a key file)
umask 077
SOPS --decrypt --extract '["cache_signing_key"]' secrets/cache-signing.yaml > "$WORK/sign.key"

for SP in "${PATHS[@]}"; do
  echo "=== publishing $SP ==="

  # idempotency: skip if the cache already has this narinfo
  hash="$(basename "$SP" | cut -d- -f1)"
  if curl -fsS "https://s3.solnix.io/solnix-cache/$hash.narinfo" >/dev/null 2>&1; then
    echo "  already in cache (narinfo present) — skipping"
    continue
  fi

  # export the full closure (topo order) from the host, import into temp store
  echo "  exporting closure from host + importing locally..."
  ./scripts/oi-ssh.sh "$IP" "$HOST_NIX nix-store --export \$(nix-store -qR $SP)" \
    | nix-store --store "$TS" --import >/dev/null

  # sign the whole closure with the cache key
  echo "  signing closure..."
  nix store sign --store "$TS" -k "$WORK/sign.key" --recursive "$SP"

  # copy to S3 (uploads narinfos + nars; skips objects already present)
  echo "  copying to S3..."
  nix copy --store "$TS" --to "$S3" "$SP"
done

echo "=== done. published paths: ${PATHS[*]} ==="
echo "substituter (consumers):  https://s3.solnix.io/solnix-cache"
echo "trusted-public-key:       cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8="
