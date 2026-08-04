#!/usr/bin/env bash
# oi-local-publish.sh — sign + publish store paths that already live in the LOCAL
# nix store (e.g. cross-built on the dev-box) to the solnix.io S3 cache. Same
# sops/sign/nix-copy/arch-manifest flow as oi-fleet-publish.sh, minus the SSH
# export/import (the paths are already local, so no builder host is needed).
# Local nix (2.34) has S3 support, so we copy straight to S3 — no temp-store bridge.
#
#   SYSTEM=sparcv9-solaris ./scripts/oi-local-publish.sh <paths-file>
#     paths-file: one /nix/store/... path per line (extra TAB cols ignored)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO"

PATHS_FILE="${1:?usage: SYSTEM=<sys> oi-local-publish.sh <paths-file>}"
SYSTEM="${SYSTEM:-x86_64-solaris}"
ARCH_MANIFEST="$REPO/docs/registry/arch-manifest.tsv"; touch "$ARCH_MANIFEST"

SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE
SOPS() { nix run nixpkgs#sops -- "$@"; }

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
  nix store sign -k "$WORK/sign.key" --recursive "$SP" 2>>"$WORK/err" || { echo "  FAIL sign"; fail=$((fail+1)); continue; }
  nix copy --to "$S3" "$SP" 2>>"$WORK/err" || { echo "  FAIL copy"; fail=$((fail+1)); continue; }
  grep -q "^$hash	" "$ARCH_MANIFEST" || printf '%s\t%s\t%s\n' "$hash" "$SP" "$SYSTEM" >> "$ARCH_MANIFEST"
  pub=$((pub+1))
done 3< "$PATHS_FILE"

if [ "$pub" -gt 0 ]; then
  LC_ALL=C sort -u -o "$ARCH_MANIFEST" "$ARCH_MANIFEST"
  aws --endpoint-url https://s3.solnix.io s3 cp "$ARCH_MANIFEST" s3://solnix-cache/arch-manifest.tsv \
    --content-type text/tab-separated-values 2>>"$WORK/err" || echo "  WARN: arch-manifest upload failed"
fi

echo "=== published=$pub skipped=$skip failed=$fail ==="
[ "$fail" = 0 ] || { echo "--- errors ---"; tail -20 "$WORK/err" 2>/dev/null; }
