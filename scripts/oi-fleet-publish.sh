#!/usr/bin/env bash
# oi-fleet-publish.sh — sign + publish a list of solnix package store paths (built
# on a fleet builder) to the solnix.io S3 cache. Bridges through a LOCAL temp store
# (host Nix 2.3.16 has no S3; docs/cache.md gotcha). Idempotent per narinfo.
#
#   BUILDER_IP=<ip> ./scripts/oi-fleet-publish.sh <paths-file>
#     paths-file: one /nix/store/... path per line (extra cols after TAB ignored)
#   SYSTEM=<x86_64-solaris|aarch64-solaris|sparcv9-solaris> (default x86_64-solaris)
#     tags each newly-published hash in the arch manifest so the site can
#     classify by arch (narinfos carry no system field). See
#     ~/ws/solnix.io/infra/docs/handoff/arch-metadata.md.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO"

PATHS_FILE="${1:?usage: BUILDER_IP=<ip> oi-fleet-publish.sh <paths-file>}"
IP="${BUILDER_IP:?set BUILDER_IP to the builder that holds these paths}"
SYSTEM="${SYSTEM:-x86_64-solaris}"
ARCH_MANIFEST="$REPO/docs/registry/arch-manifest.tsv"; touch "$ARCH_MANIFEST"
RECIPES="$REPO/docs/registry/recipes.tsv"; touch "$RECIPES"
[ -s "$RECIPES" ] || printf 'pname\tversion\turl\tsha256\tbuildsys\tdeps\tflags\tsystem\tout\tdebug\n' > "$RECIPES"

SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE
SOPS() { nix run nixpkgs#sops -- "$@"; }
HOST_NIX="${HOST_NIX:-export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:\$PATH; export NIX_CONF_DIR=/nix-tools/etc/nix;}"

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
  # authoritative presence check via S3 ls (the public narinfo GET flaps 404/503
  # on this endpoint, and nix's own dest-store query caches stale positives which
  # make `nix copy` skip real uploads — see --refresh below).
  # NOTE: `s3 ls` on this backend BOTH false-negatives (re-publishes present
  # objects) AND false-positives (skips genuinely-absent ones). The authoritative
  # per-object check is `s3api head-object` (no list pagination). Use it, and
  # allow FORCE=1 to skip the presence check entirely.
  if [ -z "${FORCE:-}" ] && aws --endpoint-url https://s3.solnix.io s3api head-object --bucket solnix-cache --key "$hash.narinfo" >/dev/null 2>&1; then
    echo "skip (cached): $(basename "$SP")"; skip=$((skip+1)); continue
  fi
  echo "=== publish $(basename "$SP") ==="
  if ! ./scripts/oi-ssh.sh "$IP" "$HOST_NIX nix-store --export \$(nix-store -qR $SP)" </dev/null | nix-store --store "$TS" --import >/dev/null 2>>"$WORK/err"; then
    echo "  FAIL export/import"; fail=$((fail+1)); continue
  fi
  nix store sign --store "$TS" -k "$WORK/sign.key" --recursive "$SP" 2>>"$WORK/err" || { echo "  FAIL sign"; fail=$((fail+1)); continue; }
  # --refresh: bypass nix's stale positive dest-store lookup on this flaky endpoint
  # (without it nix reports "copying 0 paths" and the object never lands in S3).
  nix copy --refresh --store "$TS" --to "$S3" "$SP" 2>>"$WORK/err" || { echo "  FAIL copy"; fail=$((fail+1)); continue; }
  # arch manifest: tag this hash with its system so the site can classify by arch
  grep -q "^$hash	" "$ARCH_MANIFEST" || printf '%s\t%s\t%s\n' "$hash" "$SP" "$SYSTEM" >> "$ARCH_MANIFEST"
  # recipe harvest: packages built by oi-clib/xbuild carry $SP/.solnix-recipe
  # (a RECIPE<TAB>... row). Record it with the resolved out path so future
  # "fully-Nix" rebuilds have the exact args. Debug roots carry no recipe.
  if RECLINE=$(./scripts/oi-ssh.sh "$IP" "$HOST_NIX cat $SP/.solnix-recipe 2>/dev/null" </dev/null 2>/dev/null) && [ -n "$RECLINE" ]; then
    ROW=$(printf '%s' "$RECLINE" | sed 's/^RECIPE\t//')
    RPNAME=$(printf '%s' "$ROW" | cut -f1); RVER=$(printf '%s' "$ROW" | cut -f2)
    # resolve the out column (10th field, blank on the package copy) to $SP
    ROW=$(printf '%s' "$ROW" | awk -F'\t' -v OFS='\t' -v o="$SP" '{$9=o; print}')
    grep -q "^$RPNAME	$RVER	" "$RECIPES" || printf '%s\n' "$ROW" >> "$RECIPES"
  fi
  pub=$((pub+1))
done 3< "$PATHS_FILE"

# publish the updated arch manifest so the site can fetch it (needs awscli2 in PATH;
# if absent, upload manually: nix-shell -p awscli2 --run 'aws --endpoint-url https://s3.solnix.io s3 cp docs/registry/arch-manifest.tsv s3://solnix-cache/arch-manifest.tsv')
if [ "$pub" -gt 0 ]; then
  LC_ALL=C sort -u -o "$ARCH_MANIFEST" "$ARCH_MANIFEST"
  if command -v aws >/dev/null 2>&1; then
    aws --endpoint-url https://s3.solnix.io s3 cp "$ARCH_MANIFEST" s3://solnix-cache/arch-manifest.tsv \
      --content-type text/tab-separated-values 2>>"$WORK/err" || echo "  WARN: arch-manifest upload failed"
  else
    echo "  NOTE: aws not in PATH; arch-manifest.tsv updated locally, upload it manually (see comment above)"
  fi
fi

echo "=== published=$pub skipped=$skip failed=$fail ==="
[ "$fail" = 0 ] || { echo "--- errors ---"; tail -20 "$WORK/err" 2>/dev/null; }
