#!/usr/bin/env bash
# stage-sbase.sh <stage-dir> -- the sbase check root: sbase-box + small input files.
set -euo pipefail
S="$1"; OUT="${OUT:-$HOME/scratch/rvpkg/out}"
mkdir -p "$S/sbin" "$S/bin" "$S/etc"
cp "$OUT/pkginit" "$S/sbin/init"; cp "$OUT/sbase-box" "$S/bin/"
printf '%s\n' cherry banana apple date banana elderberry fig grape bandana > "$S/etc/words"
printf '%s\n' 10 9 100 33 2 7 > "$S/etc/nums"
printf '%s\n' a a b c c c a > "$S/etc/dups"
printf '%s\n' 'root:x:0:0:Super-User:/root:/bin/dash' 'operator:x:2:5:Operator:/:/bin/dash' > "$S/etc/passwd"
