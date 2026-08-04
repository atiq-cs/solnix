#!/usr/bin/env bash
# oi-tool.sh — build a declarative tool from packages.nix on a builder, pre-pulling
# its dep closure from the cache first (Nix 2.3.16 S3 flake workaround). Runs ON a
# builder. Emits RESULT<TAB>tool<TAB>OK|FAIL<TAB>storepath|reason.
#
#   oi-tool.sh <tool-attr> [<tool-attr> ...]
# Repo expected at /var/tmp/solnix-repo (packages.nix + mk-userland-pkg.nix +
# scripts/oi-cc-wrapper.sh). Toolchain + dep closures pulled via oi-pull.sh.
set -u
export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:$PATH
export NIX_CONF_DIR=/nix-tools/etc/nix
REPO=/var/tmp/solnix-repo
PKGS=$REPO/pkgs/illumos/packages.nix
CACHE=https://s3.solnix.io/solnix-cache
KEY="cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8="

for tool in "$@"; do
  echo "=== build $tool ==="
  # eval the derivation's input drv to find its dep store paths, then pull them.
  # Simpler: just nix-build with the cache as substituter + per-path retry via oi-pull
  # on failure. Pre-pull the known toolchain first (idempotent).
  drv=$(nix-instantiate "$PKGS" -A "$tool.gcc" 2>/tmp/$tool.eval.err)
  if [ -z "$drv" ]; then
    echo "RESULT	$tool	FAIL	eval ($(tail -1 /tmp/$tool.eval.err))"; continue
  fi
  ok=0
  for i in 1 2 3; do
    if nix-store --realise "$drv" \
         --option substituters "$CACHE" \
         --option trusted-public-keys "$KEY" \
         --option require-sigs true \
         --add-root /var/tmp/gcroots/$tool --indirect \
         >/tmp/$tool.build.log 2>&1; then ok=1; break; fi
    # pull deps referenced in the build log's missing paths, then retry
    grep -oE '/nix/store/[a-z0-9]{32}-[^ ]+' /tmp/$tool.build.log | sort -u | while read p; do
      sh /var/tmp/oi-pull.sh "$p" >/dev/null 2>&1 || true
    done
    sleep 2
  done
  if [ "$ok" = 1 ]; then
    # emit BOTH out and debug outputs (debug is a separate store path).
    outs=$(nix-store -q --outputs "$drv" 2>/dev/null | tr '\n' ' ')
    echo "RESULT	$tool	OK	$outs"
  else
    echo "RESULT	$tool	FAIL	build (see /tmp/$tool.build.log)"
    tail -8 /tmp/$tool.build.log | sed 's/^/  /'
  fi
done
echo "=== oi-tool done ==="
