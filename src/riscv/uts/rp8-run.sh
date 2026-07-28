#!/usr/bin/env bash
# rp8-run.sh — boot the R-P8 kernel and drive the interactive shell with
# scripted console input, non-interactively + self-terminating.
#
# ANTI-WEDGE: qemu is run under `timeout` and fed a bounded input script then
# EOF; it NEVER foreground-waits forever. Console captured to $LOG.
#
# Input script drives the shell: after init runs its gates and execs /bin/sh,
# we type a few commands (help, echo, hello, cat) then 'exit' so the shell exits
# -> init exits -> reaped -> single-user stub. The whole run is bounded.
set -euo pipefail
cd "$(dirname "$0")"

QEMU="${QEMU:-qemu-system-riscv64}"
OUT="${OUT:-unix}"
LOG="${LOG:-rp8.log}"
DISK="${DISK:-disk.img}"
SMP="${SMP:-4}"

VIRTIO_ARGS="-global virtio-mmio.force-legacy=false \
	-drive file=$DISK,if=none,id=hd0,format=raw \
	-device virtio-blk-device,drive=hd0 \
	-netdev user,id=n0 -device virtio-net-device,netdev=n0"

: > "$LOG"
# Feed the shell input on stdin (qemu -nographic routes stdin -> guest UART RX).
# Give the kernel time to reach the shell prompt, then type commands slowly so
# the guest's polled console read sees them one line at a time.
{
	sleep 10
	for cmd in "help" "echo hello world" "hello" "cat" "exit"; do
		# type the command char by char, then a newline
		for ((i=0; i<${#cmd}; i++)); do
			printf '%s' "${cmd:$i:1}"
			sleep 0.05
		done
		printf '\n'
		sleep 2
	done
	sleep 3
} | timeout 120 "$QEMU" -machine virt -smp "$SMP" -nographic -bios default \
	-kernel "$OUT" $VIRTIO_ARGS > "$LOG" 2>&1 || true

echo "== rp8 run done; console captured to $LOG =="
