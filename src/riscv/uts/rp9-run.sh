#!/usr/bin/env bash
# rp9-run.sh — boot the R-P9 kernel + drive the shell, non-interactive +
# self-terminating. ANTI-WEDGE: qemu under `timeout 120`, bounded stdin, never
# foreground-waits. Console captured to $LOG. Optional -d int trap trace via
# QEMU_DBG=1.
set -euo pipefail
cd "$(dirname "$0")"

QEMU="${QEMU:-qemu-system-riscv64}"
OUT="${OUT:-unix}"
LOG="${LOG:-rp9.log}"
DISK="${DISK:-disk.img}"
FSIMG="${FSIMG:-rootfs.img}"
SMP="${SMP:-4}"

# gate 4: a second virtio-blk carrying the tar rootfs image (if present).
FSARGS=""
if [ -f "$FSIMG" ]; then
	FSARGS="-drive file=$FSIMG,if=none,id=fs0,format=raw -device virtio-blk-device,drive=fs0"
fi

VIRTIO_ARGS="-global virtio-mmio.force-legacy=false \
	-drive file=$DISK,if=none,id=hd0,format=raw \
	-device virtio-blk-device,drive=hd0 \
	$FSARGS \
	-netdev user,id=n0 -device virtio-net-device,netdev=n0"

DBG=""
[ "${QEMU_DBG:-0}" = "1" ] && DBG="-d int -D ${LOG%.log}-int.log"

: > "$LOG"
{
	sleep 10
	for cmd in "help" "echo hello world" "xecho hi there" "hello" "cat" "exit"; do
		for ((i=0; i<${#cmd}; i++)); do
			printf '%s' "${cmd:$i:1}"
			sleep 0.04
		done
		printf '\n'
		sleep 2
	done
	sleep 3
} | timeout 120 "$QEMU" -machine virt -smp "$SMP" -nographic -bios default \
	-kernel "$OUT" $VIRTIO_ARGS $DBG > "$LOG" 2>&1 || true

echo "== rp9 run done; console captured to $LOG =="
