#!/usr/bin/env bash
# stage-login.sh <stage-dir> -- rvlogin kernel-piece tests (rndtest, sidtest, nbtest, ptytest) + dropbear when built.
set -euo pipefail
S="$1"; OUT="${OUT:-$HOME/scratch/rvlogin/out}"
mkdir -p "$S/sbin" "$S/bin" "$S/etc"
cp "$OUT/pkginit" "$S/sbin/init"
for b in rndtest sidtest nbtest ptytest ctytest ptyglue intwait; do [ -f "$OUT/$b" ] && cp "$OUT/$b" "$S/bin/"; done
true
