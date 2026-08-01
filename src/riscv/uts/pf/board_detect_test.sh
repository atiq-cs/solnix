#!/usr/bin/env bash
# board_detect_test.sh -- R-P16 runnable check for the runtime board detector.
# Compiles the REAL fdt.c natively with console stubs and asserts the exact
# platform decision startup.c makes at boot:
#   real K1 boot DTB (k1.dtb)  -> fdt_k1_summary()==1 -> live MMIO
#   qemu-virt boot DTB          -> fdt_k1_summary()==0 -> faithful model
# The qemu-virt DTB is dumped from qemu (timeout-wrapped); the K1 DTB is the
# committed k1.dtb. Proves the branch the in-qemu boot cannot (a pure-K1 DTB
# hangs OpenSBI on qemu). Exit 0 = PASS.
set -euo pipefail
cd "$(dirname "$0")/.."   # src/riscv/uts

QEMU="${QEMU:-qemu-system-riscv64}"
VIRT_DTB="${VIRT_DTB:-/tmp/solnix-virt.dtb}"

[ -f k1.dtb ] || { echo "k1.dtb missing (dtc -I dts -O dtb k1.dts)"; exit 1; }

echo "== dump qemu-virt boot DTB (timeout 60) =="
timeout 60 "$QEMU" -machine "virt,aia=aplic-imsic,dumpdtb=$VIRT_DTB" \
	-smp 4 -nographic -bios none >/dev/null 2>&1 || true
[ -f "$VIRT_DTB" ] || { echo "failed to dump qemu-virt DTB"; exit 1; }

echo "== build + run host board-detect check =="
cc -DBOARD_DETECT_HOST_TEST -I. pf/board_detect_test.c -o /tmp/solnix-bdt
/tmp/solnix-bdt k1.dtb "$VIRT_DTB"
