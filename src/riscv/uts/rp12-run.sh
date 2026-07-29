#!/usr/bin/env bash
# rp12-run.sh — boot the R-P12 kernel: pipes + on-disk writable FS (SNFS over a
# 3rd virtio-blk data disk with a block cache) + FDT device summary. Drives the
# passwd login + a shell `echo hello | cat` pipeline. ANTI-WEDGE: qemu under
# `timeout 120`, detached (nohup->log, bounded sleep+kill), never foreground.
set -euo pipefail
cd "$(dirname "$0")"

QEMU="${QEMU:-qemu-system-riscv64}"
OUT="${OUT:-unix}"
LOG="${LOG:-rp12.log}"
DISK="${DISK:-disk.img}"        # R-P6 test disk (MBR magic; skipped by data-attach)
FSIMG="${FSIMG:-rootfs.img}"    # ustar read-only rootfs
DATAIMG="${DATAIMG:-data.img}"  # R-P12 writable SNFS data disk
SMP="${SMP:-4}"

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
# The R-P12 gates (pipes, on-disk FS) run at init before any input. Then login.
{
	sleep 18
	printf 'root\n'; sleep 3
	printf 'echo hello | cat\n'; sleep 3
	printf 'help\n'; sleep 2
	printf 'exit\n'; sleep 2
	sleep 2
} | timeout 120 "$QEMU" -machine virt -smp "$SMP" -nographic -bios default \
	-kernel "$OUT" $VIRTIO_ARGS $DBG > "$LOG" 2>&1 &
QPID=$!
sleep 75
kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true
echo "== rp12 run done; console captured to $LOG =="
