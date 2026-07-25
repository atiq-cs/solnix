#!/usr/bin/env bash
# oi-fleet-publish.sh — sign + publish a list of solnix package store paths (built
# on a fleet builder) to the solnix.io S3 cache. Bridges through a LOCAL temp store
# (host Nix 2.3.16 has no S3; docs/cache.md gotcha). Idempotent per narinfo.
#
#   BUILDER_IP=<ip> ./scripts/oi-fleet-publish.sh <paths-file>
#     paths-file: one /nix/store/... path per line (extra cols after TAB ignored)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO"

PATHS_FILE="${1:?usage: BUILDER_IP=<ip> oi-fleet-publish.sh <paths-file>}"
IP="${BUILDER_IP:?set BUILDER_IP to the builder that holds these paths}"

SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE
SOPS() { nix run nixpkgs#sops -- "$@"; }
HOST_NIX='export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:$PATH; export NIX_CONF_DIR=/nix-tools/etc/nix;'

S3='s3://solnix-cache?endpoint=s3.solnix.io&region=us-east-1&scheme=https'
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
TS="$WORK/store"; mkdir -p "$TS"
umask 077
SOPS --decrypt --extract '["cache_signing_key"]' secrets/cache-signing.yaml > "$WORK/sign.key"

pub=0; skip=0; fail=0
while IFS=$'\t' read -r first rest <&3; do
  SP="$first"
  [ -n "$SP" ] || continue
  case "$SP" in /nix/store/*) ;; *) continue;; esac
  hash="$(basename "$SP" | cut -d- -f1)"
  if curl -fsS "https://s3.solnix.io/solnix-cache/$hash.narinfo" >/dev/null 2>&1; then
    echo "skip (cached): $(basename "$SP")"; skip=$((skip+1)); continue
  fi
  echo "=== publish $(basename "$SP") ==="
  if ! ./scripts/oi-ssh.sh "$IP" "$HOST_NIX nix-store --export \$(nix-store -qR $SP)" </dev/null | nix-store --store "$TS" --import >/dev/null 2>>"$WORK/err"; then
    echo "  FAIL export/import"; fail=$((fail+1)); continue
  fi
  nix store sign --store "$TS" -k "$WORK/sign.key" --recursive "$SP" 2>>"$WORK/err" || { echo "  FAIL sign"; fail=$((fail+1)); continue; }
  nix copy --store "$TS" --to "$S3" "$SP" 2>>"$WORK/err" || { echo "  FAIL copy"; fail=$((fail+1)); continue; }
  pub=$((pub+1))
done 3< "$PATHS_FILE"

echo "=== published=$pub skipped=$skip failed=$fail ==="
[ "$fail" = 0 ] || { echo "--- errors ---"; tail -20 "$WORK/err" 2>/dev/null; }
