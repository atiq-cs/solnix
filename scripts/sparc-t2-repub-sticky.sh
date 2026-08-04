#!/usr/bin/env bash
# sparc-t2-repub-sticky.sh — re-publish specific store paths that the flapping
# S3 backend dropped after an initial 200. Uploads ONLY that path's narinfo +
# its nar (not a --recursive of the whole cache, which under sustained writes
# dropped the newest objects), then verifies over a LONGER window (~90s) and
# RE-UPLOADS up to 3 times if the object drops. Append-only.
#   ./scripts/sparc-t2-repub-sticky.sh <store-path> ...
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
AWS=(aws --endpoint-url https://s3.solnix.io --region us-east-1)

WORK="$(mktemp -d)"
cleanup() { [ -f "$WORK/sign.key" ] && { shred -u "$WORK/sign.key" 2>/dev/null || rm -f "$WORK/sign.key"; }; rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT
TS="$WORK/store"; CACHE="$WORK/cache"; mkdir -p "$TS" "$CACHE"; umask 077
sops --decrypt --extract '["cache_signing_key"]' secrets/cache-signing.yaml > "$WORK/sign.key"
printf 'StoreDir: /nix/store\nWantMassQuery: 1\nPriority: 30\n' > "$CACHE/nix-cache-info"

# upload this path's OWN narinfo + nar files from the file cache to S3.
upload_one() {
  local h="$1"
  # the narinfo
  [ -f "$CACHE/$h.narinfo" ] && "${AWS[@]}" s3 cp "$CACHE/$h.narinfo" "s3://solnix-cache/$h.narinfo" >/dev/null
  # its nar (URL referenced in the narinfo)
  local narref
  narref="$(awk -F': ' '/^URL:/{print $2}' "$CACHE/$h.narinfo" 2>/dev/null)"
  if [ -n "$narref" ] && [ -f "$CACHE/$narref" ]; then
    "${AWS[@]}" s3 cp "$CACHE/$narref" "s3://solnix-cache/$narref" >/dev/null
  fi
}

stuck() { # 200 across a ~90s window
  local h="$1" ok=0
  for i in $(seq 1 6); do
    local c; c="$(curl -s -o /dev/null -w '%{http_code}' "https://s3.solnix.io/solnix-cache/$h.narinfo" || echo 000)"
    [ "$c" = "200" ] && ok=$((ok+1)) || ok=0
    sleep 15
    [ "$ok" -ge 4 ] && return 0
  done
  return 1
}

for SP in "${PATHS[@]}"; do
  h="$(basename "$SP" | cut -d- -f1)"
  echo "=== $SP ==="
  ssh "$SUN" "$HOST_NIX nix-store --export \$(nix-store -qR $SP)" \
    | nix-store --store "$TS" --import >/dev/null
  nix store sign --store "$TS" -k "$WORK/sign.key" --recursive "$SP" >/dev/null
  nix copy --refresh --store "$TS" --to "file://$CACHE?compression=xz" "$SP" >/dev/null 2>&1
  ok=0
  for attempt in 1 2 3; do
    upload_one "$h"
    if stuck "$h"; then echo "  STICKY-90s $SP (attempt $attempt)"; ok=1; break
    else echo "  dropped, re-upload (attempt $attempt)"; fi
  done
  [ "$ok" = 1 ] || echo "  STILL-NOT-STICKY $SP"
done
echo "=== done ==="
