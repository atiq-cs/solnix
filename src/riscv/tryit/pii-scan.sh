#!/usr/bin/env bash
# pii-scan.sh <dir-or-file>... -- tryit1: strings (-n 4) over every file, grep for build-host paths and names
# (home dirs, user names, host names, nix store paths, EC2 hostnames). Prints hits; exit 1 if any.
# Also unpacks root.img-style ustar files and the bundle's split disk so the files inside are scanned too.
set -u
PAT='/home/|/Users/|/root/w|gburd|burd\.me|ubuntu|floki|lixr|lixi|dixi|dixa|arnold|ip-172-|ec2-|/nix/store|/tmp/nix|/build/src/ws'
T=$(mktemp -d); hits=0
for a in "$@"; do find "$a" -type f; done | sort > $T/files
while read -r f; do
	case "$f" in */disk/blk000000000.bin) cat "$(dirname "$f")"/blk*.bin > $T/root.tar
		mkdir -p $T/root && tar xf $T/root.tar -C $T/root 2>/dev/null && find $T/root -type f >> $T/inner;; esac
done < $T/files
cat $T/files $T/inner 2>/dev/null | while read -r f; do
	h=$(strings -a -n 4 "$f" | grep -a -E -i "$PAT" | sort -u | head -5)
	[ -z "$h" ] || { echo "HIT $f:"; echo "$h" | sed 's/^/    /'; }
done > $T/out
cat $T/out; n=$(grep -c '^HIT' $T/out); echo "pii-scan: $(cat $T/files $T/inner 2>/dev/null | wc -l) files, $n with hits"
find $T -depth -delete; [ "$n" -eq 0 ]
