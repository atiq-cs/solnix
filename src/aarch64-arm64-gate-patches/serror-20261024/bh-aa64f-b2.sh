#!/bin/bash
# bh-aa64f-b2.sh : aa64f boot 2 = boot 1 (b1-01..06, observers kept) + b2-01 (rootnex STORECACHING -> Normal-NC). Rebuild rootnex.
exec >/build/b2-aa64f.log 2>&1
set -x; date
G=/aarch64/arm64-gate/illumos-gate
cd $G || exit 1
P=$G/proto/root_aarch64
U=usr/src/uts
B=/build/aa64f-b1base
[ -f /build/aa64f-b2base-rootnex.c ] || cp $U/armv8/io/rootnex.c /build/aa64f-b2base-rootnex.c
cp /build/aa64f-b2base-rootnex.c $U/armv8/io/rootnex.c
python3 /build/patches/b2-01-storecaching-nc.py $G || { echo PATCH_FAIL; exit 3; }
diff -u /build/aa64f-b2base-rootnex.c $U/armv8/io/rootnex.c > /build/aa64f-b2.diff; wc -l /build/aa64f-b2.diff
export PATH=/usr/gnu/bin:/opt/onbld/bin:/usr/bin:/usr/sbin:/bin:/opt/ooce/bin
export LOGNAME=root MAILTO=root
./usr/src/tools/scripts/bldenv -d -t -T aarch64 /aarch64/arm64-gate/env/aarch64 <<'INNER'
cd $SRC/uts/armv8/rootnex && dmake -e install; echo "=== ROOTNEX_RC=$? ==="
INNER
for m in platform/armv8/kernel/aarch64/unix kernel/drv/aarch64/ena platform/armv8/kernel/drv/aarch64/rootnex; do
  echo "$(digest -a sha256 $P/$m | cut -c1-8) $m"
done
echo "=== B2_AA64F_DONE $(date) ==="
