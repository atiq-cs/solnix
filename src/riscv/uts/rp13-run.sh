#!/usr/bin/env bash
# rp13-run.sh — boot the R-P13 kernel under the AIA interrupt model
# (-machine virt,aia=aplic-imsic): APLIC + IMSIC MSI external IRQs, FDT-driven
# driver attach, physical-hart SMP (secondaries in the shared-runq dispatcher).
# Drives the R-P12 login/pipeline regression too. ANTI-WEDGE: qemu under
# `timeout 120`, detached (nohup->log, bounded sleep+kill), never foreground.
set -euo pipefail
cd "$(dirname "$0")"

QEMU="${QEMU:-qemu-system-riscv64}"
OUT="${OUT:-unix}"
LOG="${LOG:-rp13.log}"
DISK="${DISK:-disk.img}"
FSIMG="${FSIMG:-rootfs.img}"
DATAIMG="${DATAIMG:-data.img}"
SMP="${SMP:-4}"
# AIA machine: qemu routes wired IRQs via S-mode APLIC (0x0d000000) as MSIs to
# per-hart S-mode IMSIC files (0x28000000). K1/K3 uses this exact model.
MACHINE="${MACHINE:-virt,aia=aplic-imsic}"

FSARGS=""
[ -f "$FSIMG" ] && FSARGS="-drive file=$FSIMG,if=none,id=fs0,format=raw -device virtio-blk-device,drive=fs0"
DATAARGS=""
[ -f "$DATAIMG" ] && DATAARGS="-drive file=$DATAIMG,if=none,id=data0,format=raw -device virtio-blk-device,drive=data0"

VIRTIO_ARGS="-global virtio-mmio.force-legacy=false \
	-drive file=$DISK,if=none,id=hd0,format=raw \
	-device virtio-blk-device,drive=hd0 \
	$FSARGS \
	$DATAARGS \
	-netdev user,id=n0 -device virtio-net-device,netdev=n0"

DBG=""
[ "${QEMU_DBG:-0}" = "1" ] && DBG="-d int -D ${LOG%.log}-int.log"

: > "$LOG"
{
	sleep 18
	printf 'root\n'; sleep 3
	printf 'echo hello | cat\n'; sleep 3
	printf 'exit\n'; sleep 2
	sleep 2
} | timeout 120 "$QEMU" -machine "$MACHINE" -smp "$SMP" -nographic -bios default \
	-kernel "$OUT" $VIRTIO_ARGS $DBG > "$LOG" 2>&1 &
QPID=$!
sleep 75
kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true
echo "== rp13 run done; console captured to $LOG =="
