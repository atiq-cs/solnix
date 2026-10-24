#!/usr/bin/env bash
set -euo pipefail
S="$1"; OUT="${OUT:-$HOME/scratch/rvpkg/out}"
mkdir -p "$S/sbin" "$S/bin" "$S/etc"
cp "$OUT/pkginit" "$S/sbin/init"; cp "$OUT/hello" "$OUT/sigtest" "$OUT/sigtest-nc" "$OUT/fstest" "$OUT/pipetest" "$OUT/brktest" "$OUT/zhog" "$OUT/uptrtest" "$S/bin/"
printf "%s\n" cherry banana apple date banana elderberry fig grape bandana > "$S/etc/words"
