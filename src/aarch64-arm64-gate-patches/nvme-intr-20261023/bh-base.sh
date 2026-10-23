#!/bin/bash
# bh-base.sh : reproduce aa64b boot-2 kernel state (pci_boot keep-fw-windows + ecam trace+mute), rebuild pcierc+ecam, print shas
exec >/build/base-aa64c.log 2>&1
set -x; date
G=/aarch64/arm64-gate/illumos-gate
cd $G || exit 1
P=$G/proto/root_aarch64
digest -a sha256 $P/platform/armv8/kernel/aarch64/unix $P/kernel/drv/aarch64/ecam $P/kernel/misc/aarch64/pcierc $P/kernel/drv/aarch64/nvme $P/kernel/drv/aarch64/gicv3_its
digest -a sha256 usr/src/uts/aarch64/io/pciex/ecam/ecam.c usr/src/uts/aarch64/io/pciex/pcierc/pci_boot.c usr/src/uts/common/io/nvme/nvme.c usr/src/uts/armv8/io/gicv3_its.c usr/src/uts/armv8/dboot/dboot_synth_fdt.c
patch -p1 --dry-run < /build/patches/pci_boot-keep-fw-windows.diff && patch -p1 < /build/patches/pci_boot-keep-fw-windows.diff; echo PATCH_RC=$?
python3 /build/patches/aa-ecam-trace.py $G; echo TRACE_RC=$?
python3 /build/patches/aa-ecam-trace-mute.py $G; echo MUTE_RC=$?
export PATH=/usr/gnu/bin:/opt/onbld/bin:/usr/bin:/usr/sbin:/bin:/opt/ooce/bin
export LOGNAME=root MAILTO=root
./usr/src/tools/scripts/bldenv -d -t -T aarch64 /aarch64/arm64-gate/env/aarch64 <<'INNER'
set -x
cd $SRC/uts/aarch64/pcierc && dmake -e install; echo "=== PCIERC_RC=$? ==="
cd $SRC/uts/aarch64/ecam && dmake -e install; echo "=== ECAM_RC=$? ==="
INNER
digest -a sha256 $P/platform/armv8/kernel/aarch64/unix $P/kernel/drv/aarch64/ecam $P/kernel/misc/aarch64/pcierc
echo "=== BASE_DONE $(date) ==="
