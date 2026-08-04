#!/usr/bin/env bash
# oi-fan224-publish.sh — sign + publish solnix package store paths built on a
# Nix-2.24 fleet host to the solnix.io S3 cache. The host's from-source Nix
# 2.24 has NO S3 store scheme, so bridge: SSH `nix-store --export` on the host ->
# import into a LOCAL temp store -> dev-box nix (S3-capable) signs + `nix copy`.
# Idempotent per narinfo via s3api head-object. Records the 2.24 registry rows.
#
#   HOST=root@<ip> ./scripts/oi-fan224-publish.sh <paths-file>
#     paths-file: one /nix/store/... path per line (extra TAB cols ignored)
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO"

PATHS_FILE="${1:?usage: HOST=root@<ip> oi-fan224-publish.sh <paths-file>}"
HOST="${HOST:?set HOST=root@<ip>}"
KEY="${KEY:-$HOME/.ssh/id_ed25519}"
SYSTEM="${SYSTEM:-x86_64-solaris}"
ARCH_MANIFEST="$REPO/docs/registry/arch-manifest.tsv"; touch "$ARCH_MANIFEST"

SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE
SOPS() { nix run nixpkgs#sops -- "$@"; }
SSH() { ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 "$HOST" "$@"; }
HOST_NIX='. /etc/profile.d/nix-illumos.sh;'

S3='s3://solnix-cache?endpoint=s3.solnix.io&region=us-east-1&scheme=https'
eval "$(SOPS --decrypt secrets/s3-cache.yaml \
  | awk -F': ' '/aws_access_key_id|aws_secret_access_key/{print "export "toupper($1)"=\""$2"\""}')"
export AWS_DEFAULT_REGION=us-east-1 AWS_EC2_METADATA_DISABLED=true
[ -n "${AWS_ACCESS_KEY_ID:-}" ] || { echo "FATAL: no S3 creds from sops" >&2; exit 1; }
AWS() { nix run nixpkgs#awscli2 -- "$@"; }

WORK="$(mktemp -d)"
cleanup() { [ -f "$WORK/sign.key" ] && { shred -u "$WORK/sign.key" 2>/dev/null || rm -f "$WORK/sign.key"; }; rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT
TS="$WORK/store"; mkdir -p "$TS"
umask 077
SOPS --decrypt --extract '["cache_signing_key"]' secrets/cache-signing.yaml > "$WORK/sign.key"

pub=0; skip=0; fail=0
while IFS=$'\t' read -r first rest <&3; do
  SP="$first"; [ -n "$SP" ] || continue
  case "$SP" in /nix/store/*) ;; *) continue;; esac
  hash="$(basename "$SP" | cut -d- -f1)"
  if [ -z "${FORCE:-}" ] && AWS --endpoint-url https://s3.solnix.io s3api head-object --bucket solnix-cache --key "$hash.narinfo" >/dev/null 2>&1; then
    echo "skip (cached): $(basename "$SP")"; skip=$((skip+1)); continue
  fi
  echo "=== publish $(basename "$SP") ==="
  if ! SSH "$HOST_NIX nix-store --export \$(nix-store -qR $SP)" </dev/null | nix-store --store "$TS" --import >/dev/null 2>>"$WORK/err"; then
    echo "  FAIL export/import"; fail=$((fail+1)); continue
  fi
  nix store sign --store "$TS" -k "$WORK/sign.key" --recursive "$SP" 2>>"$WORK/err" || { echo "  FAIL sign"; fail=$((fail+1)); continue; }
  nix copy --refresh --store "$TS" --to "$S3" "$SP" 2>>"$WORK/err" || { echo "  FAIL copy"; fail=$((fail+1)); continue; }
  grep -q "^$hash	" "$ARCH_MANIFEST" || printf '%s\t%s\t%s\n' "$hash" "$SP" "$SYSTEM" >> "$ARCH_MANIFEST"
  pub=$((pub+1))
done 3< "$PATHS_FILE"

if [ "$pub" -gt 0 ]; then
  LC_ALL=C sort -u -o "$ARCH_MANIFEST" "$ARCH_MANIFEST"
  AWS --endpoint-url https://s3.solnix.io s3 cp "$ARCH_MANIFEST" s3://solnix-cache/arch-manifest.tsv \
    --content-type text/tab-separated-values 2>>"$WORK/err" || echo "  WARN: arch-manifest upload failed"
fi
echo "=== published=$pub skipped=$skip failed=$fail ==="
[ "$fail" = 0 ] || { echo "--- errors ---"; tail -20 "$WORK/err" 2>/dev/null; }
