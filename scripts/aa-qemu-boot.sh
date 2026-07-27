#!/bin/sh
# aa-qemu-boot.sh — boot the assembled aarch64 illumos disk under QEMU virt and
# capture the serial console. Mirrors richlowe/arm64-gate qemu-setup/run.sh but:
#  - uses EDK2 AAVMF UEFI firmware as -bios (u-boot from the cross build is not
#    required; QEMU-virt UEFI runs EFI/BOOT/bootaa64.efi = the illumos loader),
#  - user networking (no illumos VNIC dependency) but keeps a virtio NIC present
#    (the port assumes a NIC in the devicetree),
#  - GICv2 (QEMU virt default) NOT GICv3 (the port has no GICv3) — do NOT pass
#    gic-version=3,
#  - times out after N seconds (TCG boot is slow + verbose); the point is to
#    capture how far the kernel gets, not to reach a login.
#
# SUCCESS = the aarch64 illumos kernel starts + reaches any recognizable illumos
# milestone (SmartFirmware/loader banner, krtld, genunix, unix copyright, panic
# after krtld, single-user). Captured to the log.
set -eu
DISK="${DISK:-/aarch64/out/illumos-disk.img}"
LOG="${LOG:-/aarch64/out/qemu-console.log}"
SECS="${SECS:-300}"
CPU="${CPU:-cortex-a72}"
MEM="${MEM:-4096}"
QEMU=$(command -v qemu-system-aarch64)

[ -f "$DISK" ] || { echo "FATAL: no disk $DISK" >&2; exit 2; }
[ -n "$QEMU" ] || { echo "FATAL: no qemu-system-aarch64" >&2; exit 2; }

# Locate the EDK2/AAVMF aarch64 UEFI code firmware shipped with the qemu pkg.
BIOS=""
for c in \
  /usr/share/qemu/edk2-aarch64-code.fd \
  /usr/share/qemu/AAVMF_CODE.fd \
  "$(dirname "$QEMU")/../share/qemu/edk2-aarch64-code.fd" \
  /usr/lib/qemu/edk2-aarch64-code.fd ; do
  [ -f "$c" ] && { BIOS="$c"; break; }
done
# Some qemu builds keep firmware under a versioned share dir; search as a fallback.
[ -z "$BIOS" ] && BIOS=$(find /usr /opt -name 'edk2-aarch64-code.fd' 2>/dev/null | head -1 || true)
[ -z "$BIOS" ] && BIOS=$(find /usr /opt -name 'AAVMF_CODE.fd' 2>/dev/null | head -1 || true)

echo "qemu   = $QEMU ($("$QEMU" --version 2>&1 | head -1))"
echo "disk   = $DISK"
echo "bios   = ${BIOS:-<none found; will try u-boot then -bios-less>}"
echo "cpu    = $CPU  mem=$MEM  machine=virt (GICv2)  timeout=${SECS}s"

# u-boot from the cross build, if it finished, is the harness's preferred -bios.
UBOOT=/aarch64/gate/arm64-gate/build/u-boot-qemu/u-boot.bin

set +e
if [ -n "$BIOS" ]; then
  FW_ARG="-bios $BIOS"
elif [ -f "$UBOOT" ]; then
  FW_ARG="-bios $UBOOT"
  echo "bios   = $UBOOT (u-boot from cross build)"
else
  # No UEFI firmware: fall back to QEMU's built-in and let virt provide it.
  FW_ARG=""
  echo "WARN: no explicit firmware; relying on QEMU default"
fi

echo "=== booting (console -> $LOG) ==="
# -nographic routes the first serial (PL011) to stdout; capture with tee.
# virtio-blk holds the disk; virtio-net keeps a NIC in the devicetree (user net).
timeout "$SECS" "$QEMU" \
  -nographic \
  -machine virt \
  -accel tcg,thread=multi \
  -m "$MEM" \
  -smp 2 \
  -cpu "$CPU" \
  $FW_ARG \
  -netdev user,id=net0 \
  -device virtio-net-device,netdev=net0 \
  -device virtio-blk-device,drive=hd0 \
  -drive file="$DISK",format=raw,id=hd0,if=none \
  -d guest_errors 2>&1 | tee "$LOG"
RC=$?
set -e
echo "=== qemu exited rc=$RC (124 = timeout, expected under TCG) ==="
echo "--- console log size: $(wc -c < "$LOG") bytes ---"
echo "QEMU-BOOT-COMPLETE"
