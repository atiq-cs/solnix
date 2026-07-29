#!/usr/bin/env bash
# rp15-run.sh — boot the R-P15 kernel, ANTI-WEDGE (qemu under `timeout 120`,
# detached nohup->log, bounded sleep+kill, NEVER foreground):
#
#   MODE=virt (default): qemu-virt AIA (-machine virt,aia=aplic-imsic -smp 4).
#     Proves the R-P15 gates in emulation:
#       - hat: K1 device gigapage (0xc0000000) mapped + readback
#       - mmc/sdhci block driver: full CMD0/8/ACMD41/2/3/7 init + CMD17 sector0
#         read, driven against the faithful in-kernel SDHCI+SD model (marked).
#   MODE=k1: adds `-dtb k1.dtb` (documented to hang OpenSBI on qemu — the
#     physical-board DTB path).
set -euo pipefail
cd "$(dirname "$0")"

QEMU="${QEMU:-qemu-system-riscv64}"
OUT="${OUT:-unix}"
MODE="${MODE:-virt}"
LOG="${LOG:-rp15-$MODE.log}"
DISK="${DISK:-disk.img}"
FSIMG="${FSIMG:-rootfs.img}"
DATAIMG="${DATAIMG:-data.img}"
SMP="${SMP:-4}"
MACHINE="${MACHINE:-virt,aia=aplic-imsic}"

DTBARG=""
if [ "$MODE" = "k1" ]; then
	[ -f k1.dtb ] || { echo "k1.dtb missing (dtc -I dts -O dtb k1.dts)"; exit 1; }
	DTBARG="-dtb k1.dtb"
fi

FSARGS=""
[ -f "$FSIMG" ] && FSARGS="-drive file=$FSIMG,if=none,id=fs0,format=raw -device virtio-blk-device,drive=fs0"
DATAARGS=""
[ -f "$DATAIMG" ] && DATAARGS="-drive file=$DATAIMG,if=none,id=data0,format=raw -device virtio-blk-device,drive=data0"

VIRTIO_ARGS="-global virtio-mmio.force-legacy=false \
	-drive file=$DISK,if=none,id=hd0,format=raw \
	-device virtio-blk-device,drive=hd0 \
	$FSARGS $DATAARGS \
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
	-kernel "$OUT" $DTBARG $VIRTIO_ARGS $DBG > "$LOG" 2>&1 &
QPID=$!
sleep 75
kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true
echo "== rp15 ($MODE) run done; console captured to $LOG =="
