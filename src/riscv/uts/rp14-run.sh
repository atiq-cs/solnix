#!/usr/bin/env bash
# rp14-run.sh — boot the R-P14 kernel two ways, both ANTI-WEDGE (qemu under
# `timeout 120`, detached nohup->log, bounded sleep+kill, NEVER foreground):
#
#   MODE=virt (default): qemu-virt AIA (-machine virt,aia=aplic-imsic -smp 4).
#     The kernel finds the qemu default DTB (no K1 devices) and PROVES the K1
#     drivers — the dw-apb-uart 8250 console + reg-shift math, the SDHCI probe
#     plan — against the virt hardware.
#   MODE=k1: same machine but `-dtb k1.dtb` hands the kernel a REAL SpaceMiT K1
#     board devicetree (compiled from k1.dts). The kernel discovers the K1's
#     mem/dw-apb-uart/sdhci/aplic/imsic and binds the K1 devices — the physical
#     board's boot path, in emulation. (a1=DTB is exactly U-Boot's booti ABI.)
set -euo pipefail
cd "$(dirname "$0")"

QEMU="${QEMU:-qemu-system-riscv64}"
OUT="${OUT:-unix}"
MODE="${MODE:-virt}"
LOG="${LOG:-rp14-$MODE.log}"
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
echo "== rp14 ($MODE) run done; console captured to $LOG =="
