#!/usr/bin/env bash
# rp11-run.sh — boot the R-P11 kernel + drive passwd login/shell, non-interactive
# + self-terminating. ANTI-WEDGE: qemu under `timeout 120`, detached via nohup,
# bounded stdin, never foreground-waits. Console captured to $LOG. Optional
# -d int trace via QEMU_DBG=1.
set -euo pipefail
cd "$(dirname "$0")"

QEMU="${QEMU:-qemu-system-riscv64}"
OUT="${OUT:-unix}"
LOG="${LOG:-rp11.log}"
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
# stdin driver: the R-P11 gates (signals/fs/concurrent) run first without input;
# then login_console prompts. Log in as root (from /etc/passwd), run a few
# commands, exit -> re-prompt as operator, exit.
{
	sleep 18
	printf 'root\n'; sleep 3
	for cmd in "help" "echo hello world" "cat /etc/passwd" "exit"; do
		printf '%s\n' "$cmd"; sleep 2
	done
	sleep 1
	printf 'operator\n'; sleep 2
	printf 'exit\n'; sleep 2
	printf 'nosuchuser\n'; sleep 2
	sleep 2
} | timeout 120 "$QEMU" -machine virt -smp "$SMP" -nographic -bios default \
	-kernel "$OUT" $VIRTIO_ARGS $DBG > "$LOG" 2>&1 &
QPID=$!
# Detached: wait bounded, then ensure it is gone (never a foreground wedge).
sleep 90
kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true
echo "== rp11 run done; console captured to $LOG =="
