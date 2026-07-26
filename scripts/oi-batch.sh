#!/usr/bin/env bash
# oi-batch.sh — build a list of pkg.cc targets sequentially on THIS builder,
# logging each to its own file + a combined batch log. Run detached via nohup.
#   oi-batch.sh <batchname> <pkg.cc> [pkg.cc ...]
export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:/usr/sbin
export NIX_CONF_DIR=/nix-tools/etc/nix
cd /var/tmp/solnix-pkgs/pkgs/illumos
BATCH="${1:?batchname}"; shift
COMBINED="/var/tmp/batch-$BATCH.log"
: > "$COMBINED"
for t in "$@"; do
  log="/var/tmp/build-${t//./_}.log"
  echo "### START $t $(date) ###" | tee -a "$COMBINED"
  if nix-build packages.nix -A "$t" --no-out-link > "$log" 2>&1; then
    sp=$(tail -1 "$log")
    echo "### OK $t -> $sp ###" | tee -a "$COMBINED"
  else
    echo "### FAIL $t (see $log) ###" | tee -a "$COMBINED"
    tail -5 "$log" | tee -a "$COMBINED"
  fi
done
echo "### BATCH $BATCH DONE $(date) ###" | tee -a "$COMBINED"
