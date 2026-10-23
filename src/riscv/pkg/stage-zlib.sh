#!/usr/bin/env bash
# stage-zlib.sh <stage-dir> -- the zlib check root: upstream example + minigzip, a
# GNU-gzip-made input, and a negative control whose gzip trailer CRC is zeroed.
set -euo pipefail
S="$1"; OUT="${OUT:-$HOME/scratch/rvpkg/out}"
mkdir -p "$S/sbin" "$S/bin" "$S/etc"
cp "$OUT/pkginit" "$S/sbin/init"; cp "$OUT/example" "$OUT/minigzip" "$S/bin/"
for i in $(seq 1 200); do
	case $i in 1) echo "solnix riscv64 zlib interop line 1: the quick brown fox";;
	200) echo "line 200: jumps over the lazy dog";; *) echo "line $i: filler $i $i $i";; esac
done | gzip -9n > "$S/etc/hello.txt.gz"
cp "$S/etc/hello.txt.gz" "$S/etc/badcrc.txt.gz"
sz=$(wc -c < "$S/etc/badcrc.txt.gz")
printf '\0\0\0\0' | dd of="$S/etc/badcrc.txt.gz" bs=1 seek=$((sz-8)) conv=notrunc status=none
