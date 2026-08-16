#!/usr/bin/env bash
# Reconstruct the full rp36 working dir by overlaying every phase's kernel/user/
# ldso in ascending order (latest file wins) -- git only stored per-phase deltas.
set -e
R=/root/riscv-port
mkdir -p $R/rp36/kernel $R/rp36/user $R/rp36/ldso

for d in rp22 rp23 rp24 rp25 rp26 rp27 rp28 rp29 rp30 rp31 rp32 rp33 rp34 rp35; do
  [ -d $R/$d/kernel ] && cp -f $R/$d/kernel/* $R/rp36/kernel/ 2>/dev/null || true
  [ -d $R/$d/user   ] && cp -f $R/$d/user/*   $R/rp36/user/   2>/dev/null || true
  [ -d $R/$d/ldso   ] && cp -f $R/$d/ldso/*   $R/rp36/ldso/   2>/dev/null || true
done
echo "OVERLAY_DONE"
echo "kernel files: $(ls $R/rp36/kernel | wc -l)"
echo "user files:   $(ls $R/rp36/user | wc -l)"
echo "ldso files:   $(ls $R/rp36/ldso | wc -l)"
