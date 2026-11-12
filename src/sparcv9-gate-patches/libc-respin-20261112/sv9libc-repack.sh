#!/usr/bin/bash
# sv9libc-repack.sh <orig proto tar.gz> <new libc.so.1 | -> <out.tar.gz> <fresh workdir>
# Re-pack the sparcv9 proto with lib/sparcv9/libc.so.1 replaced (or unchanged with "-": the control, which must reproduce
# the original byte for byte). Same member list and order as the original (mk-proto-tarball.sh: sorted, no dir entries),
# GNU tar --format=gnu, owner/group 0, mtime 315532800, gzip -n -9.
set -euo pipefail
O=$1; L=$2; OUT=$3; W=$4
[ -e "$W" ] && { echo "FATAL: $W exists" >&2; exit 2; }
mkdir -p "$W"; cd "$W"
gzip -dc "$O" | /usr/gnu/bin/tar xpf -
gzip -dc "$O" | /usr/gnu/bin/tar tf - > members.txt
if [ "$L" != "-" ]; then
	cp "$L" proto-root_sparcv9/lib/sparcv9/libc.so.1.new
	chmod 0755 proto-root_sparcv9/lib/sparcv9/libc.so.1.new
	mv proto-root_sparcv9/lib/sparcv9/libc.so.1.new proto-root_sparcv9/lib/sparcv9/libc.so.1
fi
/usr/gnu/bin/tar --format=gnu --owner=0 --group=0 --numeric-owner --mtime=@315532800 --no-recursion -T members.txt -cf - | gzip -n -9 > "$OUT"
digest -a sha256 "$OUT"
