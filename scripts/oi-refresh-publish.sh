#!/usr/bin/env bash
# refresh-publish one path from a builder to S3, forcing nix copy --refresh so a
# stale local narinfo ("copying 0 paths") can't skip an object that isn't in S3.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO"
IP="${BUILDER_IP:?}"; SP="${1:?store-path}"; SYSTEM="${SYSTEM:-x86_64-solaris}"
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
HOST_NIX='export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:$PATH; export NIX_CONF_DIR=/nix-tools/etc/nix;'
S3='s3://solnix-cache?endpoint=s3.solnix.io&region=us-east-1&scheme=https'
eval "$(nix run nixpkgs#sops -- --decrypt secrets/s3-cache.yaml \
  | awk -F': ' '/aws_access_key_id|aws_secret_access_key/{print "export "toupper($1)"=\""$2"\""}')"
export AWS_DEFAULT_REGION=us-east-1 AWS_EC2_METADATA_DISABLED=true
W="$(mktemp -d)"; TS="$W/store"; mkdir -p "$TS"; umask 077
trap 'rm -rf "$W" 2>/dev/null || true' EXIT
nix run nixpkgs#sops -- --decrypt --extract '["cache_signing_key"]' secrets/cache-signing.yaml > "$W/sign.key"
./scripts/oi-ssh.sh "$IP" "$HOST_NIX nix-store --export \$(nix-store -qR $SP)" </dev/null \
  | nix-store --store "$TS" --import >/dev/null
nix store sign --store "$TS" -k "$W/sign.key" --recursive "$SP" >/dev/null
nix copy --refresh --store "$TS" --to "$S3" "$SP"
h="$(basename "$SP" | cut -d- -f1)"
AM="$REPO/docs/registry/arch-manifest.tsv"
grep -q "^$h	" "$AM" || printf '%s\t%s\t%s\n' "$h" "$SP" "$SYSTEM" >> "$AM"
echo "REFRESH-OK $SP"
