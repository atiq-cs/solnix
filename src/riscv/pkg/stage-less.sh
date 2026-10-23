#!/usr/bin/env bash
set -euo pipefail
S="$1"; OUT="${OUT:-$HOME/scratch/rvpkg/out}"
mkdir -p "$S/sbin" "$S/bin" "$S/etc"
cp "$OUT/pkginit" "$S/sbin/init"; cp "$OUT/less" "$S/bin/"
for i in $(seq 1 100); do
	n=$(printf '%03d' "$i")
	case $i in 1) echo "line $n the first line";; 77) echo "line $n searched";;
	100) echo "line $n the last line";; *) echo "line $n filler";; esac
done > "$S/etc/lines.txt"
printf 'short file line %s\n' 1 2 3 > "$S/etc/short.txt"
