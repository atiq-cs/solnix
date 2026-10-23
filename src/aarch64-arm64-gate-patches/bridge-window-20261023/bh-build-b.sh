#!/bin/bash
# bh-build-b.sh : pci_boot keep-fw-windows + ecam trace(+mute); rebuild pcierc + ecam (DEBUG cross aarch64)
exec >/build/build-aa64b.log 2>&1
set -x; date
G=/aarch64/arm64-gate/illumos-gate
cd $G || exit 1
P=$G/proto/root_aarch64
digest -a sha256 $P/platform/armv8/kernel/aarch64/unix $P/kernel/drv/aarch64/ecam $P/kernel/misc/aarch64/pcierc
git status --short usr/src/uts/aarch64/io/pciex/
patch -p1 --dry-run < /build/patches/pci_boot-keep-fw-windows.diff && patch -p1 < /build/patches/pci_boot-keep-fw-windows.diff; echo PATCH_RC=$?
python3 /build/patches/aa-ecam-trace.py $G; echo TRACE_RC=$?
python3 /build/patches/aa-ecam-trace-mute.py $G; echo MUTE_RC=$?
git diff usr/src/uts/aarch64/io/pciex/ > /build/aa64b-gate.diff
export PATH=/usr/gnu/bin:/opt/onbld/bin:/usr/bin:/usr/sbin:/bin:/opt/ooce/bin
export LOGNAME=root MAILTO=root
./usr/src/tools/scripts/bldenv -d -t -T aarch64 /aarch64/arm64-gate/env/aarch64 <<'INNER'
set -x
cd $SRC/uts/aarch64/pcierc && dmake -e install; echo "=== PCIERC_RC=$? ==="
cd $SRC/uts/aarch64/ecam && dmake -e install; echo "=== ECAM_RC=$? ==="
INNER
digest -a sha256 $P/platform/armv8/kernel/aarch64/unix $P/kernel/drv/aarch64/ecam $P/kernel/misc/aarch64/pcierc
strings $P/kernel/drv/aarch64/ecam | grep -E '^\[E[<>~]'
strings $P/kernel/misc/aarch64/pcierc | grep -c 'FWINIT.*ignored'
echo "=== AA64B_BUILD_DONE $(date) ==="
