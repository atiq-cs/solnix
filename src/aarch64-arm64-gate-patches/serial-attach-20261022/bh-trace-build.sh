#!/bin/bash
# bh-trace-build.sh : apply aa-ecam-trace.py and rebuild + install the ecam module (DEBUG cross aarch64)
exec >/build/build-trace.log 2>&1
set -x; date
G=/aarch64/arm64-gate/illumos-gate
cd $G || exit 1
cp usr/src/uts/aarch64/io/pciex/ecam/ecam.c /build/ecam.c.pre-trace
python3 /build/patches/aa-ecam-trace.py $G; echo TRACE_RC=$?
git diff usr/src/uts/aarch64/io/pciex/ecam/ecam.c > /build/ecam-fix+diag+trace.diff
OLD=$(digest -a sha256 $G/proto/root_aarch64/kernel/drv/aarch64/ecam)
export PATH=/usr/gnu/bin:/opt/onbld/bin:/usr/bin:/usr/sbin:/bin:/opt/ooce/bin
export LOGNAME=root MAILTO=root
./usr/src/tools/scripts/bldenv -d -t -T aarch64 /aarch64/arm64-gate/env/aarch64 <<'INNER'
set -x
cd $SRC/uts/aarch64/ecam && dmake -e install; echo "=== ECAM_RC=$? ==="
INNER
NEW=$(digest -a sha256 $G/proto/root_aarch64/kernel/drv/aarch64/ecam)
echo "OLD=$OLD NEW=$NEW"
strings $G/proto/root_aarch64/kernel/drv/aarch64/ecam | grep -E '^\[E[<>]'
echo "=== TRACE_BUILD_DONE $(date) ==="
