#!/usr/bin/env bash
# rp7-run.sh — boot the R-P7 kernel and feed the interactive userland /sbin/init
# scripted console input (a few chars, then 'q' to make init exit), so the run
# is non-interactive and self-terminating. ANTI-WEDGE: timeout 60 + input EOF;
# never foreground-waits. Console captured to the given log (default rp7.log).
#
# Uses the already-built ./unix (build-unix.sh built it). Run standalone (no
# nix shell needed — only qemu).
set -euo pipefail
cd "$(dirname "$0")"

QEMU="${QEMU:-qemu-system-riscv64}"
OUT="${OUT:-unix}"
LOG="${LOG:-rp7.log}"
DISK="${DISK:-disk.img}"
SMP="${SMP:-4}"
INPUT="${INPUT:-Xy!q}"		# chars init should echo, then 'q' to exit

VIRTIO_ARGS="-global virtio-mmio.force-legacy=false \
	-drive file=$DISK,if=none,id=hd0,format=raw \
	-device virtio-blk-device,drive=hd0 \
	-netdev user,id=n0 -device virtio-net-device,netdev=n0"

: > "$LOG"
# Feed INPUT (one char at a time with small gaps) on stdin; qemu -nographic
# routes stdin to the guest UART RX. `printf` then a sleep keeps the pipe open
# long enough for the guest to consume, then EOF. timeout bounds the whole run.
{
	# give the kernel time to reach the interactive prompt before typing
	sleep 8
	# emit each char slowly so the guest's polled read sees them one by one
	for ((i=0; i<${#INPUT}; i++)); do
		printf '%s' "${INPUT:$i:1}"
		sleep 0.5
	done
	sleep 3
} | timeout 60 "$QEMU" -machine virt -smp "$SMP" -nographic -bios default \
	-kernel "$OUT" $VIRTIO_ARGS > "$LOG" 2>&1 || true

echo "== rp7 run done; console captured to $LOG =="
