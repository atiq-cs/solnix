#!/bin/bash
exec >>/var/log/aa-applypatches.log 2>&1
set -x
echo "=== APPLY PATCHES START $(date) ==="
GATE=/aarch64/arm64-gate/illumos-gate
P=/build/patches
cd $GATE
# clean slate on arm64-gate branch
git checkout -q arm64-gate
git clean -fdq usr/src 2>/dev/null
git checkout -q usr/src 2>/dev/null

RC=0
# 1. cumulative (efipart hunks, Makefile.files, dboot.h, dboot_conf_acpi, dboot_machdep, fakebop BOP/BCONS, kobj)
gpatch -p1 -f < $P/a6-cumulative-all-legs.patch 2>&1 || { echo "CUMULATIVE FAILED"; RC=1; }

# 2. drop in the full solnix dboot_synth_fdt.c (the GICv3/CRS/SSDT synth file)
cp $P/dboot_synth_fdt.c $GATE/usr/src/uts/armv8/dboot/dboot_synth_fdt.c
echo "dboot_synth_fdt.c dropped: $(wc -l < $GATE/usr/src/uts/armv8/dboot/dboot_synth_fdt.c) lines"

# 3. drop in the full patched efipart.c (overrides cumulative efipart hunks consistently)
cp $P/efipart.c $GATE/usr/src/boot/efi/libefi/efipart.c
echo "efipart.c dropped: $(wc -l < $GATE/usr/src/boot/efi/libefi/efipart.c) lines"

# 4. boot_uart.c: fr-poll bounded, THEN drain-drop (final = TXFF cap 10000, no TXFE drain)
gpatch -p1 -f < $P/boot_uart-frpoll-only.patch 2>&1 || { echo "FRPOLL FAILED"; RC=1; }
gpatch -p1 -f < $P/a6-boot-uart-drop-txfe-drain.patch 2>&1 || { echo "DRAINDROP FAILED"; RC=1; }

# 5. mem arena + gcc14 CERRWARN (fakebop mem hunks + Makefile.uts + hat/hment)
gpatch -p1 -f < $P/a6-mem-plus-gcc14-build-fixes.patch 2>&1 || { echo "MEMGCC14 FAILED (may conflict with cumulative fakebop)"; RC=1; }

# 6. build-host fixes (Makefile.master + pkg/Makefile)
gpatch -p1 -f < $P/a6-kcon-build-host-fixes.patch 2>&1 || { echo "BUILDHOST FAILED"; RC=1; }

echo "=== APPLY RC=$RC ==="
# verify the drain-drop final state in boot_uart.c
echo "--- boot_uart_putchar TXFF cap + TXFE drain presence ---"
grep -c "cap < 10000u" $GATE/usr/src/uts/armv8/boot/boot_uart.c
grep -c "TXFE" $GATE/usr/src/uts/armv8/boot/boot_uart.c
echo "--- Makefile.files has dboot_synth_fdt.o ---"
grep -c "dboot_synth_fdt.o" $GATE/usr/src/uts/armv8/Makefile.files
echo "--- mem arena bump (128) ---"
grep -c "MMU_PAGESIZE \* 128" $GATE/usr/src/uts/armv8/os/fakebop.c
echo "--- reject files? ---"
find $GATE/usr/src -name "*.rej" 2>/dev/null | head
echo "=== APPLY PATCHES DONE $(date) ==="
