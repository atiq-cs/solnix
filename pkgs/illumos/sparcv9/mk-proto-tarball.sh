#!/usr/bin/bash
# mk-proto-tarball.sh <out.tar.gz> (sun's global zone, any user; reads only) -- pack the sparcv9 gate proto from the running
# OpenIndiana: every lib/sparcv9 and usr/lib/sparcv9 *.so*/*.o and every usr/include file or link of the packages at
# illumos-gate's version (SUNWcs's: the osnet consolidation), under ONE top dir proto-root_sparcv9/ (builtin:unpack-channel needs
# exactly one). Sorted names, owner 0, mtime 315532800, gzip -n. Pin the printed sha256 in ./gate.nix and bank the tarball.
set -euo pipefail
o=${1:?usage: mk-proto-tarball.sh <out.tar.gz>}; t=$(mktemp -d /var/tmp/sv9p.XXXXXX); trap 'find "$t" -depth -delete' EXIT
v=$(pkg list -H SUNWcs | nawk '{print $2}')
pkg list -H | nawk -v v="$v" '$2 == v {print $1}' > "$t/pkgs"
pkg contents -H -t file,link -o path $(cat "$t/pkgs") |
	grep -E '^(lib/sparcv9/|usr/lib/sparcv9/)[^/]+\.(so(\.[0-9.]+)?|o)$|^usr/include/' | LC_ALL=C sort -u > "$t/files"
echo "illumos-gate $v: $(wc -l < "$t/pkgs") packages, $(wc -l < "$t/files") paths" >&2
# S: the prefix goes on member names only, never on a relative symlink's target (usr/lib/sparcv9/libc.so -> ../../../lib/...)
(cd / && /usr/gnu/bin/tar --format=gnu --owner=0 --group=0 --numeric-owner --mtime=@315532800 --no-recursion \
	--transform='s,^,proto-root_sparcv9/,S' -T "$t/files" -cf -) | gzip -n -9 > "$o"
digest -a sha256 "$o"
