#!/usr/bin/env bash
# rp10-run.sh — boot the R-P10 kernel + drive login/shell, non-interactive +
# self-terminating. ANTI-WEDGE: qemu under `timeout 120`, bounded stdin, never
# foreground-waits. Console captured to $LOG. Optional -d int trace via
# QEMU_DBG=1 (used to check preemption re-entrancy).
set -euo pipefail
cd "$(dirname "$0")"

QEMU="${QEMU:-qemu-system-riscv64}"
OUT="${OUT:-unix}"
LOG="${LOG:-rp10.log}"
DISK="${DISK:-disk.img}"
FSIMG="${FSIMG:-rootfs.img}"
SMP="${SMP:-4}"

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
	sleep 12
	# 1) log in at the getty/login prompt (any name -> drop to shell).
	printf 'root\n'; sleep 3
	# 2) drive the shell (proves libc printf/malloc via the sh path).
	for cmd in "help" "echo hello world" "xecho hi there" "hello" "cat" "cat /etc/inittab" "exit"; do
		for ((i=0; i<${#cmd}; i++)); do
			printf '%s' "${cmd:$i:1}"
			sleep 0.03
		done
		printf '\n'
		sleep 2
	done
	# 3) exiting the shell returns to the getty login prompt (respawn).
	sleep 2
	printf 'operator\n'; sleep 2
	printf 'exit\n'; sleep 2
	sleep 2
} | timeout 120 "$QEMU" -machine virt -smp "$SMP" -nographic -bios default \
	-kernel "$OUT" $VIRTIO_ARGS $DBG > "$LOG" 2>&1 || true

echo "== rp10 run done; console captured to $LOG =="
