#!/usr/bin/env bash
set -euo pipefail
S="$1"; OUT="${OUT:-$HOME/scratch/rvpkg/out}"
mkdir -p "$S/sbin" "$S/bin" "$S/etc"
cp "$OUT/pkginit" "$S/sbin/init"; cp "$OUT/curstest" "$S/bin/"
