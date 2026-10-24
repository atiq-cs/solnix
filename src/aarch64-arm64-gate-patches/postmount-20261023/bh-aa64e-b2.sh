#!/bin/bash
# bh-aa64e-b2.sh : boot-2 kernel = boot-1 observers + aa64e-b2.py (UNEXPECTED regs, trap ring, ena rx sizing). Rebuild unix + ena.
exec >/build/b2-aa64e.log 2>&1
set -x; date
G=/aarch64/arm64-gate/illumos-gate
cd $G || exit 1
P=$G/proto/root_aarch64
U=usr/src/uts
# start from the boot-1 tree: re-run the boot-1 script's restore + observer apply (idempotent), but without its build
for f in armv8/ml/exceptions.S armv8/os/trap.c; do git diff --quiet -- $U/$f && echo "$f clean" || echo "$f HAS BASE EDITS"; done
mkdir -p /build/aa64e-b2base
[ -f /build/aa64e-b2base/exceptions.S ] || cp $U/armv8/ml/exceptions.S /build/aa64e-b2base/exceptions.S
[ -f /build/aa64e-b2base/trap.c ] || cp $U/armv8/os/trap.c /build/aa64e-b2base/trap.c
cp /build/aa64e-b2base/exceptions.S $U/armv8/ml/exceptions.S; cp /build/aa64e-b2base/trap.c $U/armv8/os/trap.c
cp $U/armv8/os/machdep.c /build/aa64e-b2base/machdep.c.b1 2>/dev/null
cp /build/aa64e-base/machdep.c $U/armv8/os/machdep.c; cp /build/aa64e-base/ena.c $U/common/io/ena/ena.c
cp /build/aa64e-base/fakebop.c $U/armv8/os/fakebop.c; cp /build/aa64e-base/mp_startup.c $U/armv8/os/mp_startup.c
cp /build/aa64e-base/main.c $U/common/os/main.c; cp /build/aa64e-base/wscons.c $U/common/io/wscons.c; cp /build/aa64e-base/ena_dma.c $U/common/io/ena/ena_dma.c
cp /build/dboot_synth_fdt.c.b2 $U/armv8/dboot/dboot_synth_fdt.c
python3 /build/patches/aa64e-observers.py $G $G/$U/armv8/dboot/dboot_synth_fdt.c; echo OBS_RC=$?
python3 /build/patches/aa64e-b2.py $G; echo B2_RC=$?
F="$U/armv8/ml/exceptions.S $U/armv8/os/trap.c $U/armv8/os/machdep.c $U/common/io/ena/ena.c $U/armv8/os/fakebop.c $U/armv8/os/mp_startup.c $U/common/os/main.c $U/common/io/wscons.c $U/common/io/ena/ena_dma.c"
B=/build/aa64e-b2base
( diff -u $B/exceptions.S $U/armv8/ml/exceptions.S; diff -u $B/trap.c $U/armv8/os/trap.c
  for f in machdep.c ena.c fakebop.c mp_startup.c main.c wscons.c ena_dma.c; do diff -u /build/aa64e-base/$f $(echo $F | tr ' ' '\n' | grep "/$f\$"); done ) > /build/aa64e-b2-tracked.diff
diff -u /build/dboot_synth_fdt.c.b2 $U/armv8/dboot/dboot_synth_fdt.c > /build/aa64e-b2-dboot.diff
wc -l /build/aa64e-b2-tracked.diff /build/aa64e-b2-dboot.diff
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
echo "unix UNEXP: $(strings $P/platform/armv8/kernel/aarch64/unix | grep -c 'AA64E-UNEXP')  ena sizing: $(strings $P/kernel/drv/aarch64/ena | grep -c 'rx sizing')"
nm $P/platform/armv8/kernel/aarch64/unix | grep -c "aa64e_unexpected\|aa64e_trap_rec"
echo "=== B2_AA64E_DONE $(date) ==="
