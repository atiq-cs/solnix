#!/bin/bash
# bh-aa64f-b1.sh : aa64f boot 1 = aa64e boot-2 tree + b1-01..b1-06.  Rebuild unix, rootnex, ena.
exec >/build/b1-aa64f.log 2>&1
set -x; date
G=/aarch64/arm64-gate/illumos-gate
cd $G || exit 1
P=$G/proto/root_aarch64
U=usr/src/uts
B=/build/aa64f-b1base
FILES="armv8/ml/exceptions.S armv8/os/mp_startup.c armv8/os/machdep.c armv8/os/trap.c armv8/io/rootnex.c common/io/ena/ena_tx.c"
# save the boot-2 state once; restore it on every run so this script is idempotent
mkdir -p $B
for f in $FILES; do b=$B/$(basename $f); [ -f $b ] || cp $U/$f $b; cp $b $U/$f; done
for p in 01-mp-startup-daif 02-entry-unmask-a 03-eret-mask-a 04-daif-samples 05-mapping-attr-print 06-kernel-serror-print; do
  python3 /build/patches/b1-$p.py $G || { echo "PATCH_FAIL $p"; exit 3; }
done
( for f in $FILES; do diff -u $B/$(basename $f) $U/$f; done ) > /build/aa64f-b1.diff
wc -l /build/aa64f-b1.diff
export PATH=/usr/gnu/bin:/opt/onbld/bin:/usr/bin:/usr/sbin:/bin:/opt/ooce/bin
export LOGNAME=root MAILTO=root
./usr/src/tools/scripts/bldenv -d -t -T aarch64 /aarch64/arm64-gate/env/aarch64 <<'INNER'
set -x
cd $SRC/uts/aarch64/ena && dmake -e install; echo "=== ENA_RC=$? ==="
cd $SRC/uts/armv8/rootnex && dmake -e install; echo "=== ROOTNEX_RC=$? ==="
cd $SRC/uts/armv8/unix && dmake -e install; echo "=== UNIX_RC=$? ==="
INNER
for m in platform/armv8/kernel/aarch64/unix kernel/aarch64/genunix kernel/drv/aarch64/ena platform/armv8/kernel/drv/aarch64/rootnex kernel/drv/aarch64/nvme platform/armv8/kernel/drv/aarch64/gicv3_its kernel/drv/aarch64/ecam kernel/misc/aarch64/pcierc; do
  echo "$(digest -a sha256 $P/$m | cut -c1-8) $m"
done
echo "unix KSERR $(strings $P/platform/armv8/kernel/aarch64/unix | grep -c AA64F-KSERR) DAIF $(strings $P/platform/armv8/kernel/aarch64/unix | grep -c AA64F-DAIF) rootnex MAP $(strings $P/platform/armv8/kernel/drv/aarch64/rootnex | grep -c AA64F-MAP) ena LLQ $(strings $P/kernel/drv/aarch64/ena | grep -c AA64F-LLQ)"
echo "=== B1_AA64F_DONE $(date) ==="
