#!/usr/bin/bash
# sv9libc-build.sh <A|B> <fresh dir>  (zone lixu, as gburd, run under nohup; no root)
# A = OI illumos-gate 31d3d510 + Fix A (memset_s wrapper) only: the timing run and the 5-symbol control.
# B = 31d3d510 + illumos 16452/16506/16151+16505 backports + OI's ILLUMOS_0.40 numbering + vdprintf.o + Fix A: the reconstruction.
# Builds ONLY the 64-bit libc (lib/libc/sparcv9/libc.so.1) and the six sparcv9 symcap.o it links, with bldenv +t of the env
# file (= OI's oi-userland transforms of usr/src/tools/env/illumos.sh), onbld 0.5.11-2025.0.0.21764, gcc-10, Sun as, system ld.
# $ROOT is seeded from the hosted proto (OI 2025.0.0.21764 headers), the zone's /usr/platform/sun4{u,v}/include (system/header,
# same version) and the 7 unpackaged headers libc includes, copied from the tree where `dmake install_h` would put them.
set -euo pipefail
V=${1:?A|B}; D=${2:?fresh dir}; S=/var/tmp/sv9libc-src
case $V in A|B|B3) ;; *) echo "bad variant" >&2; exit 2;; esac
[ -e "$D" ] && { echo "FATAL: $D exists (use a fresh name)" >&2; exit 2; }
log() { echo "$(date -u +%FT%TZ) $*"; }
mkdir -p "$D"; cd "$D"
log "start variant $V in $D"
gzip -dc $S/ig-31d3d510-src.tar.gz | /usr/gnu/bin/tar xf -
/usr/gnu/bin/tar xf $S/overlay-$V.tar
WS=$D/ws; ROOT=$WS/proto/root_sparc
mkdir -p "$ROOT" "$ROOT/usr/platform"
gzip -dc /var/tmp/proto-root_sparcv9.tar.gz | (cd "$ROOT" && /usr/gnu/bin/tar xf - --strip-components=1)
# + head/tzfile.h: `head` install_h puts it in $ROOT, but OI's system/header (so the proto) does not ship it
cp -p $WS/usr/src/head/priv_utils.h $WS/usr/src/lib/libc/port/gen/getxby_door.h $WS/usr/src/head/tzfile.h "$ROOT/usr/include/"
cp -p $WS/usr/src/uts/common/sys/libc_kernel.h $WS/usr/src/uts/sparc/sys/synch32.h $WS/usr/src/uts/common/sys/u8_textprep_data.h \
	$WS/usr/src/uts/common/sys/ucred.h "$ROOT/usr/include/sys/"
(cd /usr/platform && /usr/gnu/bin/tar cf - sun4u/include sun4v/include) | (cd "$ROOT/usr/platform" && /usr/gnu/bin/tar xf -)
digest -a sha256 $WS/usr/src/lib/libc/port/gen/memset_s.c $WS/usr/src/lib/libc/port/mapfile-vers
log "tree ready"
cp -p $S/sv9libc.env $S/inner.sh "$D/"
export SV9WS=$WS SV9VER=illumos-31d3d510d0 SHELL=/usr/bin/bash
cd "$WS"
nice -n 19 /opt/onbld/bin/bldenv +t "$D/sv9libc.env" "/usr/bin/bash $D/inner.sh"
rc=$?
log "end rc=$rc"
