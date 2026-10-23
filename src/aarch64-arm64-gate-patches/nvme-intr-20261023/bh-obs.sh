#!/bin/bash
# bh-obs.sh : apply aa64c observers, rebuild nvme, gicv3_its, unix (dboot is linked into unix). DEBUG cross aarch64.
exec >/build/obs-aa64c.log 2>&1
set -x; date
G=/aarch64/arm64-gate/illumos-gate
cd $G || exit 1
P=$G/proto/root_aarch64
# start from clean sources (idempotent re-run)
git checkout -- usr/src/uts/common/io/nvme/nvme.c usr/src/uts/armv8/io/gicv3_its.c
cp /build/dboot_synth_fdt.c.pre usr/src/uts/armv8/dboot/dboot_synth_fdt.c
digest -a sha256 usr/src/uts/common/io/nvme/nvme.c usr/src/uts/armv8/io/gicv3_its.c usr/src/uts/armv8/dboot/dboot_synth_fdt.c
python3 /build/patches/aa64c-observers.py $G; echo OBS_RC=$?
git diff usr/src/uts/common/io/nvme/nvme.c usr/src/uts/armv8/io/gicv3_its.c > /build/aa64c-observers-tracked.diff
diff -u /build/dboot_synth_fdt.c.pre usr/src/uts/armv8/dboot/dboot_synth_fdt.c > /build/aa64c-dboot-iort.diff
export PATH=/usr/gnu/bin:/opt/onbld/bin:/usr/bin:/usr/sbin:/bin:/opt/ooce/bin
export LOGNAME=root MAILTO=root
./usr/src/tools/scripts/bldenv -d -t -T aarch64 /aarch64/arm64-gate/env/aarch64 <<'INNER'
set -x
cd $SRC/uts/aarch64/nvme && dmake -e install; echo "=== NVME_RC=$? ==="
cd $SRC/uts/armv8/gicv3_its && dmake -e install; echo "=== ITS_RC=$? ==="
cd $SRC/uts/armv8/unix && dmake -e install; echo "=== UNIX_RC=$? ==="
INNER
digest -a sha256 $P/platform/armv8/kernel/aarch64/unix $P/kernel/drv/aarch64/nvme $P/platform/armv8/kernel/drv/aarch64/gicv3_its $P/kernel/drv/aarch64/ecam $P/kernel/misc/aarch64/pcierc
find $P -name gicv3_its -newer /build/base-aa64c.log
strings $P/kernel/drv/aarch64/nvme | grep -c -E 'possible missed interrupt|admin intr type'
strings $P/platform/armv8/kernel/drv/aarch64/gicv3_its | grep -c -E 'MAPTI %s|IORT'
strings $P/kernel/drv/aarch64/nvme | grep -c '^!'
strings $P/platform/armv8/kernel/aarch64/unix | grep -c 'solnix,acpi-iort'
echo "=== OBS_DONE $(date) ==="
