#!/bin/bash
# bh-aa64e-obs.sh : apply aa64e observers on top of the reproduced aa64c boot-2 base; rebuild unix genunix wc ena; print shas.
exec >/build/obs-aa64e.log 2>&1
set -x; date
G=/aarch64/arm64-gate/illumos-gate
cd $G || exit 1
P=$G/proto/root_aarch64
U=usr/src/uts
FILES="$U/armv8/os/machdep.c $U/armv8/os/fakebop.c $U/armv8/os/mp_startup.c $U/common/os/main.c $U/common/io/wscons.c $U/common/io/ena/ena.c $U/common/io/ena/ena_dma.c"
DB=$U/armv8/dboot/dboot_synth_fdt.c
# idempotent: restore the base (git for tracked, banked copy for dboot)
git checkout -- $U/armv8/os/machdep.c $U/armv8/os/mp_startup.c $U/common/os/main.c $U/common/io/wscons.c $U/common/io/ena/ena.c $U/common/io/ena/ena_dma.c
git diff --quiet -- $U/armv8/os/fakebop.c || echo "fakebop has base edits (kept)"
[ -f /build/fakebop.c.base ] || cp $U/armv8/os/fakebop.c /build/fakebop.c.base
cp /build/fakebop.c.base $U/armv8/os/fakebop.c
[ -f /build/dboot_synth_fdt.c.b2 ] || cp $DB /build/dboot_synth_fdt.c.b2
cp /build/dboot_synth_fdt.c.b2 $DB
digest -a sha256 /build/dboot_synth_fdt.c.b2 /build/fakebop.c.base
mkdir -p /build/aa64e-base; for f in $FILES; do cp $f /build/aa64e-base/$(basename $f); done
python3 /build/patches/aa64e-observers.py $G $G/$DB; echo OBS_RC=$?
for f in $FILES; do diff -u /build/aa64e-base/$(basename $f) $f; done > /build/aa64e-observers-tracked.diff
diff -u /build/dboot_synth_fdt.c.b2 $DB > /build/aa64e-dboot-gtdt.diff
wc -l /build/aa64e-observers-tracked.diff /build/aa64e-dboot-gtdt.diff
export PATH=/usr/gnu/bin:/opt/onbld/bin:/usr/bin:/usr/sbin:/bin:/opt/ooce/bin
export LOGNAME=root MAILTO=root
./usr/src/tools/scripts/bldenv -d -t -T aarch64 /aarch64/arm64-gate/env/aarch64 <<'INNER'
set -x
cd $SRC/uts/aarch64/genunix && dmake -e install; echo "=== GENUNIX_RC=$? ==="
cd $SRC/uts/aarch64/wc && dmake -e install; echo "=== WC_RC=$? ==="
cd $SRC/uts/aarch64/ena && dmake -e install; echo "=== ENA_RC=$? ==="
cd $SRC/uts/armv8/unix && dmake -e install; echo "=== UNIX_RC=$? ==="
INNER
digest -a sha256 $P/platform/armv8/kernel/aarch64/unix $P/kernel/aarch64/genunix $P/kernel/drv/aarch64/wc $P/kernel/drv/aarch64/ena $P/kernel/drv/aarch64/nvme $P/platform/armv8/kernel/drv/aarch64/gicv3_its $P/kernel/drv/aarch64/ecam $P/kernel/misc/aarch64/pcierc
echo "unix AA64E strings: $(strings $P/platform/armv8/kernel/aarch64/unix | grep -c 'AA64E')  gtdt: $(strings $P/platform/armv8/kernel/aarch64/unix | grep -c 'solnix,acpi-gtdt')"
echo "genunix marks: $(strings $P/kernel/aarch64/genunix | grep -c -E 'consconfig next|start_other_cpus next|init forked')"
echo "ena attach str: $(strings $P/kernel/drv/aarch64/ena | grep -c 'AA64E') ena bang: $(strings $P/kernel/drv/aarch64/ena | grep -c '^!failed')"
nm $P/kernel/drv/aarch64/wc | grep -c aa64e_echo_w
echo "=== OBS_AA64E_DONE $(date) ==="
