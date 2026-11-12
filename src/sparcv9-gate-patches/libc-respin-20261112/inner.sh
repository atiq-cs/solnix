#!/usr/bin/bash
# inner.sh: runs inside bldenv (PATH, ROOT, SRC, MAKEFLAGS=e from the env file)
set -euo pipefail
log() { echo "$(date -u +%FT%TZ) $*"; }
# onbld make (dmake) is 32-bit C++ with NEEDED libgcc_s.so.1 and a dead RUNPATH (/opt/gcc/4.4.4/lib); the zone has no
# /usr/lib/libgcc_s.so.1 (installing compat links would put it on every builder's default path). _32 reaches only 32-bit
# processes (make, cw); the 64-bit ld and the libc link never read it.
export LD_LIBRARY_PATH_32=/usr/gcc/10/lib  # dmake (C++) only; gcc 4.4.4 objects never link libgcc_s
log "inner: ROOT=$ROOT SRC=$SRC VERSION=$VERSION RELEASE_DATE=$RELEASE_DATE ONBLD_TOOLS=${ONBLD_TOOLS:-unset} BUILD_LD=$BUILD_LD"
which cw dmake ctfconvert ctfmerge genoffsets as ld gcc 2>&1 || true
L=$SRC/lib/libc
# as lib/libc/Makefile: all_h (assym.h) before the capabilities subdirs (sun4v smt_pause.s includes it)
log "assym.h"
(cd $L/sparcv9 && dmake assym.h)
for d in sun4u sun4u-opl sun4u-us3-hwcap1 sun4u-us3-hwcap2 sun4v-hwcap1 sun4v-hwcap2; do
	log "symcap $d"
	(cd $L/capabilities/$d/sparcv9 && dmake all)
done
cd $L/sparcv9
log "libc.so.1"
dmake libc.so.1
log "libc.so.1 done"
if elfdump -r libc.so.1 | grep -w environ; then echo "Error: Invalid reference to environ" >&2; exit 1; fi
digest -a sha256 libc.so.1
ls -la libc.so.1
