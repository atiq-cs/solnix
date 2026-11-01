#!/bin/bash
# bh-aa64g-k.sh : aa64g kernel = git HEAD + the fixes, no diagnostics.  Idempotent: every edited
# file is first reset to its clean base (git HEAD, or the banked fix-only base), then patched.
#   fixes kept: per-RC ITS (p1), console UART after consconfig (p2/p3), ecam on_trap (p4 base),
#   kernel SError trap cases (p5 base), memlist arena (p6 base), b1-01..03, b2-01, bridge windows
#   (pci_boot.c, untouched), boot_uart/efipart/kobj/dboot_* (untouched base edits).
exec >/build/k-aa64g.log 2>&1
set -x; date
G=/aarch64/arm64-gate/illumos-gate; U=usr/src/uts; P=$G/proto/root_aarch64; Q=/build/patches
cd $G || exit 1
git checkout -- $U/armv8/os/machdep.c $U/armv8/os/mp_startup.c $U/common/os/main.c $U/common/io/wscons.c \
  $U/common/io/ena/ena.c $U/common/io/ena/ena_dma.c $U/common/io/nvme/nvme.c $U/armv8/io/gicv3_its.c \
  $U/armv8/io/rootnex.c $U/common/io/ena/ena_tx.c || exit 1
[ -f /build/aa64g-ecam.c.base ] || cp $U/aarch64/io/pciex/ecam/ecam.c /build/aa64g-ecam.c.base   # fix + trace (bh tree)
cp /build/aa64g-ecam.c.base $U/aarch64/io/pciex/ecam/ecam.c
cp /build/aa64e-b2base/trap.c $U/armv8/os/trap.c; cp /build/aa64e-b2base/exceptions.S $U/armv8/ml/exceptions.S
cp /build/fakebop.c.base $U/armv8/os/fakebop.c; cp /build/dboot_synth_fdt.c.b2 $U/armv8/dboot/dboot_synth_fdt.c
for p in p1-dboot-rc-its p7-dboot-untrace; do python3 $Q/$p.py $G/$U/armv8/dboot/dboot_synth_fdt.c || { echo "PATCH_FAIL $p"; exit 3; }; done
for p in p2-console-uart p3-wscons-notem p4-ecam-untrace p5-trap-untrace p6-fakebop-untrace \
         b1-01-mp-startup-daif b1-02-entry-unmask-a b1-03-eret-mask-a b2-01-storecaching-nc; do
  python3 $Q/$p.py $G || { echo "PATCH_FAIL $p"; exit 3; }
done
git diff > /build/aa64g-gate-tracked.diff; diff -u /build/dboot_synth_fdt.c.b2 $U/armv8/dboot/dboot_synth_fdt.c > /build/aa64g-dboot.diff
wc -l /build/aa64g-gate-tracked.diff /build/aa64g-dboot.diff
export PATH=/usr/gnu/bin:/opt/onbld/bin:/usr/bin:/usr/sbin:/bin:/opt/ooce/bin LOGNAME=root MAILTO=root
./usr/src/tools/scripts/bldenv -d -t -T aarch64 /aarch64/arm64-gate/env/aarch64 <<'INNER'
set -x
for d in aarch64/genunix aarch64/wc aarch64/ena aarch64/nvme aarch64/ecam armv8/gicv3_its armv8/rootnex armv8/unix; do
  ( cd $SRC/uts/$d && dmake -e install ); echo "=== RC $d=$? ==="
done
INNER
for m in platform/armv8/kernel/aarch64/unix kernel/aarch64/genunix kernel/drv/aarch64/wc kernel/drv/aarch64/ena \
  platform/armv8/kernel/drv/aarch64/rootnex kernel/drv/aarch64/nvme platform/armv8/kernel/drv/aarch64/gicv3_its \
  kernel/drv/aarch64/ecam kernel/misc/aarch64/pcierc; do echo "$(digest -a sha256 $P/$m | cut -c1-8) $m"; done
echo "DIAG strings (want 0): $(for m in platform/armv8/kernel/aarch64/unix kernel/aarch64/genunix kernel/drv/aarch64/wc kernel/drv/aarch64/ena platform/armv8/kernel/drv/aarch64/rootnex kernel/drv/aarch64/nvme platform/armv8/kernel/drv/aarch64/gicv3_its kernel/drv/aarch64/ecam; do strings $P/$m; done | grep -c -E 'AA64[EF]|AAECAM|\[IORT\]|MAPTI|A6KCON|A6MEM|A6GIC|A6CRS|\[E>|solnix,acpi')"
echo "=== K_AA64G_DONE $(date) ==="
