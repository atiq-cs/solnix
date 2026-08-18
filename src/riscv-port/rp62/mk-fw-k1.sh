#!/usr/bin/env bash
#
# mk-fw-k1.sh -- R-P62: build a K1 (Milk-V Jupiter) addressed OpenSBI firmware
# that lands the solnix kernel at physical 0x80200000, its non-PIE link base.
#
# WHY: the solnix kernel is a fully-linked non-PIE image (kernel.lds PADDR =
# 0x80200000; the solaris-target binutils has no -pie, so there are no
# R_RISCV_RELATIVE relocs to apply at runtime).  Its stored absolute pointers
# (vnode-ops vtables, dispatch tables) resolve to the link base, so it MUST run
# at 0x80200000.  Proven under qemu: a fw_payload built with a different
# FW_PAYLOAD_OFFSET (kernel at 0x80400000) boots through mlsetup but faults the
# instant it calls through a vtable pointer (scause=0xc at the LINKED VA whose
# physical is unmapped) -- that is the on-HW boot blocker.
#
# K1 memory: DRAM is memory@0, base 0x0, 8 GiB (0x0 .. 0x2_0000_0000).  So
# 0x80200000 (2 GiB in) is valid K1 DRAM.  The kernel's DTB-driven discovery
# (RAM base/size, PLIC/CLINT/UART/SDHCI MMIO, hart count) adapts to the K1 map,
# so the SAME binary boots qemu-virt (DRAM@0x80000000) and the K1 (DRAM@0x0);
# only the load base must be 0x80200000 in both.
#
# TWO conventions (build both):
#   (A) fw_payload  -- OpenSBI + embedded kernel as one ELF.  For the K1 build
#       OpenSBI at DRAM base 0x0 (FW_TEXT_START=0x0) and embed the kernel at
#       FW_PAYLOAD_OFFSET=0x80200000 so the payload byte 0 lands at phys
#       0x80200000.  fw_next_addr returns `lla payload_bin` (PC-relative), so
#       OpenSBI jumps the kernel to exactly 0x80200000.
#   (B) fw_dynamic  -- OpenSBI + the vendor next-stage convention: the K1
#       u-boot SPL loads OpenSBI (fw_dynamic) + the kernel separately and passes
#       the kernel's address (0x80200000) via struct fw_dynamic_info in a2.  Use
#       this with the vendor u-boot; the kernel binary is unix.bin loaded at
#       0x80200000 by u-boot's `booti`/`go`.
#
# Crib: OpenSBI docs/firmware/fw_payload.md + fw_dynamic.md; the SpacemiT K1
# platform (platform/generic/spacemit/k1.c) + arch/riscv/boot/dts/spacemit/
# k1-x.dtsi (DRAM @ 0x0, 8 GiB).
set -e
export PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:/usr/gnu/bin:$PATH
R=/root/riscv-port
O=$R/rp62/opensbi
K=$R/rp62/kernel
export PATH=$R/rp62/opensbi-xtools:$PATH
export CROSS_COMPILE=riscv64-unknown-elf-

[ -f "$K/unix.bin" ] || { echo "mk-fw-k1: $K/unix.bin missing -- run build-kernel.sh first"; exit 1; }

cd $O

# ---- (A) K1 fw_payload: OpenSBI@0x0, kernel embedded so it lands at 0x80200000
# NOTE: FW_PAYLOAD embeds the kernel at FW_TEXT_START + FW_PAYLOAD_OFFSET and
# reaches it PC-relative (R_RISCV_PCREL_HI20, +-2 GiB range).  So OpenSBI and the
# kernel must be within 2 GiB.  We CANNOT put OpenSBI at 0x0 and the kernel at
# 0x80200000 (2 GiB+2 MiB apart -> "relocation truncated to fit").  Instead put
# OpenSBI at 0x80000000 (valid K1 DRAM, 2 GiB in) + offset 0x200000 so the kernel
# lands at 0x80200000 -- identical to the qemu-virt fw_payload, and 0x80000000 is
# a valid K1 DRAM address (DRAM spans 0x0..0x2_0000_0000), so the SAME fw_payload
# build works on the K1.  (For a K1 that must run OpenSBI at DRAM base 0x0, use
# the fw_dynamic path (B) below -- u-boot loads OpenSBI@0x0 + kernel@0x80200000
# separately, no PC-relative embed.)
echo "=== R-P62: building the K1 fw_payload (OpenSBI@0x80000000, kernel@0x80200000; 0x80000000 is valid K1 DRAM) ==="
gmake distclean >/dev/null 2>&1 || true
gmake -j4 PLATFORM=generic FW_PAYLOAD=y \
     FW_TEXT_START=0x80000000 \
     FW_PAYLOAD_PATH=$K/unix.bin \
     FW_PAYLOAD_OFFSET=0x200000 \
     > $R/rp62/opensbi-build-k1.log 2>&1 \
  || { echo "  FAIL (see rp62/opensbi-build-k1.log)"; tail -20 $R/rp62/opensbi-build-k1.log; exit 1; }
cp build/platform/generic/firmware/fw_payload.elf $R/rp62/fw_payload_k1.elf
FWENTRY=$(riscv64-unknown-elf-readelf -h $R/rp62/fw_payload_k1.elf | awk -F: '/Entry point/{print $2}' | tr -d ' ')
echo "  OK fw_payload_k1.elf: OpenSBI entry=$FWENTRY (0x80000000 = 2 GiB into K1 DRAM), kernel embedded at +0x200000 -> phys 0x80200000 (== the kernel link base)"

# ---- (B) K1 fw_dynamic: OpenSBI dynamic-info firmware (u-boot passes next addr)
echo "=== R-P62: building the K1 fw_dynamic (u-boot loads kernel@0x80200000, passes it in a2) ==="
gmake distclean >/dev/null 2>&1 || true
gmake -j4 PLATFORM=generic FW_DYNAMIC=y \
     FW_TEXT_START=0x0 \
     > $R/rp62/opensbi-build-k1-dyn.log 2>&1 \
  || { echo "  FAIL (see rp62/opensbi-build-k1-dyn.log)"; tail -20 $R/rp62/opensbi-build-k1-dyn.log; exit 1; }
cp build/platform/generic/firmware/fw_dynamic.elf $R/rp62/fw_dynamic_k1.elf
echo "  OK fw_dynamic_k1.elf (OpenSBI@0x0 dynamic-info; u-boot SPL loads unix.bin at 0x80200000 + passes struct fw_dynamic_info in a2)"

echo "=== R-P62 K1 firmware built:"
ls -l $R/rp62/fw_payload_k1.elf $R/rp62/fw_dynamic_k1.elf
echo
echo "ON-HARDWARE recipe (Milk-V Jupiter, SpacemiT K1):"
echo "  (A) fw_payload_k1.elf goes on the boot medium where the K1 BROM/SPL"
echo "      expects OpenSBI (loaded at 0x80000000, 2 GiB into K1 DRAM); OpenSBI
#      jumps the embedded kernel"
echo "      to phys 0x80200000 (PC-relative payload_bin)."
echo "  (B) or use the vendor u-boot: load fw_dynamic_k1.elf + unix.bin (at"
echo "      0x80200000), u-boot passes the kernel addr via fw_dynamic_info(a2)."
echo "  Either way the kernel lands at 0x80200000 (valid K1 DRAM) = its link"
echo "  base; the DTB the firmware passes drives the K1 map (PLIC@0xe0000000,"
echo "  SDHCI@0xd4280000, pxa-uart@0xd4017000, 8 harts, 8 GiB)."
