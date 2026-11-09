#!/usr/bin/env bash
# oi-pull.sh — robustly realise a store path (+closure) from the solnix cache on
# a builder running Nix 2.3.16, whose S3/http substituter flakes ("Error 0") on
# whole-closure fetches. Strategy: resolve the full closure from narinfo
# References, then realise ONE path at a time with per-path retries so a single
# flaky read can't abort the whole closure. Run this ON the builder.
#
#   oi-pull.sh <store-path> [<store-path> ...]
set -u
export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:$PATH
export NIX_CONF_DIR=/nix-tools/etc/nix
CACHE=https://cache.solnix.io
KEY="cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8="

# BFS the closure via narinfo References (hash -> full path from StorePath line)
declare -A seen
queue=()
for p in "$@"; do queue+=("$(basename "$p" | cut -d- -f1)"); done
order=()
while [ "${#queue[@]}" -gt 0 ]; do
  h="${queue[0]}"; queue=("${queue[@]:1}")
  [ -n "${seen[$h]:-}" ] && continue
  ni=$(curl -fsS "$CACHE/$h.narinfo" 2>/dev/null) || { echo "WARN no narinfo $h"; continue; }
  seen[$h]=1; order+=("$h")
  refs=$(printf '%s\n' "$ni" | awk -F': ' '/^References:/{print $2}')
  for r in $refs; do rh="${r%%-*}"; [ "$rh" = "$h" ] && continue; queue+=("$rh"); done
done

# realise leaves-first isn't required (nix pulls deps), but per-path retry is:
fail=0
for h in "${order[@]}"; do
  path=$(ls -d /nix/store/$h-* 2>/dev/null | head -1)
  if [ -n "$path" ] && nix-store --verify-path "$path" >/dev/null 2>&1; then continue; fi
  # need full path: from StorePath line
  full=$(curl -fsS "$CACHE/$h.narinfo" | awk '/^StorePath:/{print $2}')
  ok=0
  for i in 1 2 3 4 5; do
    if nix-store --realise "$full" --option substituters "$CACHE" \
         --option trusted-public-keys "$KEY" --option require-sigs true \
         --add-root /var/tmp/gcroots/"$h" --indirect >/dev/null 2>&1; then ok=1; break; fi
    sleep 2
  done
  if [ "$ok" = 1 ]; then echo "OK   $(basename "$full")"; else echo "FAIL $(basename "$full")"; fail=$((fail+1)); fi
done
echo "=== pull done, failures=$fail ==="
exit "$fail"
