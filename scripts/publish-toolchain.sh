#!/usr/bin/env bash
# publish-toolchain.sh — publish the fleetA toolchain paths to s3.solnix.io.
# Mirrors oi-fleet-publish.sh but sources the host nix profile (for
# LD_LIBRARY_PATH so host nix-store can load its boost libs) and takes an
# explicit BUILDER_IP + key. Bridges: host export -> local import -> sign ->
# nix copy --to s3. Idempotent via s3api head-object unless FORCE=1.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO"
PATHS_FILE="${1:?usage: BUILDER_IP=<ip> publish-toolchain.sh <paths-file>}"
IP="${BUILDER_IP:?set BUILDER_IP}"
KEY="${SOLNIX_KEY:-$HOME/.ssh/id_ed25519}"
SYSTEM="${SYSTEM:-x86_64-solaris}"
ARCH_MANIFEST="$REPO/docs/registry/arch-manifest.tsv"; touch "$ARCH_MANIFEST"
SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE
SOPS() { nix run nixpkgs#sops -- "$@"; }
HOST='. /etc/profile.d/nix-illumos.sh;'
RSSH() { ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "root@$IP" "$@"; }

S3='s3://solnix-cache?endpoint=s3.solnix.io&region=us-east-1&scheme=https'
eval "$(SOPS --decrypt secrets/s3-cache.yaml \
  | awk -F': ' '/aws_access_key_id|aws_secret_access_key/{print "export "toupper($1)"=\""$2"\""}')"
export AWS_DEFAULT_REGION=us-east-1 AWS_EC2_METADATA_DISABLED=true

WORK="$(mktemp -d)"
cleanup() { [ -f "$WORK/sign.key" ] && { shred -u "$WORK/sign.key" 2>/dev/null || rm -f "$WORK/sign.key"; }; rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT
TS="$WORK/store"; mkdir -p "$TS"
umask 077
SOPS --decrypt --extract '["cache_signing_key"]' secrets/cache-signing.yaml > "$WORK/sign.key"

pub=0; skip=0; fail=0
while IFS=$'\t' read -r SP rest; do
  [ -n "$SP" ] || continue
  case "$SP" in /nix/store/*) ;; *) continue;; esac
  hash="$(basename "$SP" | cut -d- -f1)"
  if [ -z "${FORCE:-}" ] && aws --endpoint-url https://s3.solnix.io s3api head-object --bucket solnix-cache --key "$hash.narinfo" >/dev/null 2>&1; then
    echo "skip (cached): $(basename "$SP")"; skip=$((skip+1)); continue
  fi
  echo "=== publish $(basename "$SP") ==="
  if ! RSSH "$HOST nix-store --export \$(nix-store -qR $SP)" </dev/null | nix-store --store "$TS" --import >/dev/null 2>>"$WORK/err"; then
    echo "  FAIL export/import"; fail=$((fail+1)); continue
  fi
  nix store sign --store "$TS" -k "$WORK/sign.key" --recursive "$SP" 2>>"$WORK/err" || { echo "  FAIL sign"; fail=$((fail+1)); continue; }
  nix copy --refresh --store "$TS" --to "$S3" "$SP" 2>>"$WORK/err" || { echo "  FAIL copy"; fail=$((fail+1)); continue; }
  grep -q "^$hash	" "$ARCH_MANIFEST" || printf '%s\t%s\t%s\n' "$hash" "$SP" "$SYSTEM" >> "$ARCH_MANIFEST"
  pub=$((pub+1))
done < "$PATHS_FILE"

echo "published=$pub skipped=$skip failed=$fail"
[ -s "$WORK/err" ] && { echo "--- errors ---"; tail -20 "$WORK/err"; } || true
