#!/bin/bash
# bh-b2.sh : boot-2 kernel = boot-1 observers + IORT-routed ITS choice in dboot. Rebuild unix only.
exec >/build/b2-aa64c.log 2>&1
set -x; date
G=/aarch64/arm64-gate/illumos-gate
cd $G || exit 1
P=$G/proto/root_aarch64
digest -a sha256 $P/platform/armv8/kernel/aarch64/unix usr/src/uts/armv8/dboot/dboot_synth_fdt.c
cp usr/src/uts/armv8/dboot/dboot_synth_fdt.c /build/dboot_synth_fdt.c.obs
cp $P/platform/armv8/kernel/aarch64/unix /build/unix.b1
python3 /build/patches/aa64c-iort-its.py $G; echo IORTITS_RC=$?
diff -u /build/dboot_synth_fdt.c.obs usr/src/uts/armv8/dboot/dboot_synth_fdt.c > /build/aa64c-iort-its.diff
export PATH=/usr/gnu/bin:/opt/onbld/bin:/usr/bin:/usr/sbin:/bin:/opt/ooce/bin
export LOGNAME=root MAILTO=root
./usr/src/tools/scripts/bldenv -d -t -T aarch64 /aarch64/arm64-gate/env/aarch64 <<'INNER'
set -x
cd $SRC/uts/armv8/unix && dmake -e install; echo "=== UNIX_RC=$? ==="
INNER
digest -a sha256 $P/platform/armv8/kernel/aarch64/unix $P/kernel/drv/aarch64/nvme $P/platform/armv8/kernel/drv/aarch64/gicv3_its $P/kernel/drv/aarch64/ecam $P/kernel/misc/aarch64/pcierc
strings $P/platform/armv8/kernel/aarch64/unix | grep -c 'solnix,acpi-iort'
echo "=== B2_DONE $(date) ==="
