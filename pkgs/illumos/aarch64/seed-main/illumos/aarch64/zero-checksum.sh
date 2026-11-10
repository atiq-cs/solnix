#!/usr/bin/bash
# aarch64/zero-checksum.sh <dir> <failfile> -- ../zero-checksum.sh (it says why DT_CHECKSUM -> 0), without elfedit:
# illumos elfedit segfaults on ANY edit of a GNU-stripped aarch64 ELF (.SUNW_ldynsym sh_link 0; measured on dixa,
# dixa4 2026-10-31), and nix-src.nix strips before mk-src-pkg zeroes. dd writes 8 zero bytes over the entry's
# d_un (an Elf64_Dyn is d_tag 8 bytes + d_un 8 bytes), then elfdump must read the value back as 0.
set -u
find "$1" -type f | while read -r f; do
  i=$(/usr/bin/elfdump -d "$f" 2>/dev/null | awk '$2=="CHECKSUM"{gsub(/[][]/, "", $1); print $1; exit}')
  [ -n "$i" ] || continue
  o=$(/usr/bin/elfdump -c -N .dynamic "$f" 2>/dev/null | awk '/sh_offset:/{print $2; exit}')
  [ -n "$o" ] || { echo "zero checksum $f: no .dynamic section" >> "$2"; continue; }
  chmod u+w "$f"; dd if=/dev/zero of="$f" bs=1 seek=$((o + 16 * i + 8)) count=8 conv=notrunc 2>/dev/null
  /usr/bin/elfdump -d "$f" 2>/dev/null | awk '$2=="CHECKSUM"{exit ($3 != "0")}' || echo "zero checksum $f: still set" >> "$2"
done
