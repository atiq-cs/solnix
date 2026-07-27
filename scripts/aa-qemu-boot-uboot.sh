#!/bin/sh
# aa-qemu-boot-uboot.sh — boot the aarch64 illumos disk under QEMU virt using
# U-BOOT as -bios (instead of EDK2). This is the harness's own path (run.sh) and
# the KEY difference from the EDK2 attempt: u-boot passes QEMU virt's DEVICETREE
# to the illumos loader, so the kernel sees "Firmware Tables: DeviceTree" (which
# the port supports) instead of "ACPI" (which stalled dboot: "ACPI kernel
# support is a work in progress").
#
# u-boot on QEMU virt auto-runs distro bootcmd -> scans the virtio-blk ESP ->
# bootefi EFI/BOOT/bootaa64.efi (the illumos loader) with the DTB.
set -eu
DISK="${DISK:-/aarch64/out/illumos-disk.img}"
UBOOT="${UBOOT:-/aarch64/out/u-boot-qemu.bin}"
LOG="${LOG:-/aarch64/out/qemu-console-uboot.log}"
SECS="${SECS:-420}"
CPU="${CPU:-cortex-a72}"
MEM="${MEM:-4096}"
QEMU=$(command -v qemu-system-aarch64)

[ -f "$DISK" ]  || { echo "FATAL: no disk $DISK" >&2; exit 2; }
[ -f "$UBOOT" ] || { echo "FATAL: no u-boot $UBOOT" >&2; exit 2; }

echo "qemu   = $QEMU ($("$QEMU" --version 2>&1 | head -1))"
echo "disk   = $DISK"
echo "uboot  = $UBOOT ($(wc -c < "$UBOOT") bytes)"
echo "cpu    = $CPU  mem=$MEM  machine=virt (GICv2, devicetree)  timeout=${SECS}s"
echo "=== booting via u-boot (console -> $LOG) ==="

# GICv2 is the QEMU virt default; do NOT set gic-version=3 (port has no GICv3).
# u-boot as -bios; QEMU provides the DTB to u-boot which forwards it to the loader.
set +e
timeout "$SECS" "$QEMU" \
  -nographic \
  -machine virt \
  -accel tcg,thread=multi \
  -m "$MEM" \
  -smp 2 \
  -cpu "$CPU" \
  -bios "$UBOOT" \
  -netdev user,id=net0 \
  -device virtio-net-device,netdev=net0 \
  -device virtio-blk-device,drive=hd0 \
  -drive file="$DISK",format=raw,id=hd0,if=none \
  -d guest_errors 2>&1 | tee "$LOG"
RC=$?
set -e
echo "=== qemu exited rc=$RC (124 = timeout) ==="
echo "--- console log size: $(wc -c < "$LOG") bytes ---"
echo "QEMU-UBOOT-BOOT-COMPLETE"
