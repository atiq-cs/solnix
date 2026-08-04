#!/usr/bin/env bash
# qemu-boot-test.sh — timeout-wrapped, bounded QEMU boot proof for a solnix
# raw disk image OR ISO. Serial console captured to a log; a fresh target copy
# is made each run (never reuse a mutated disk). -cpu Haswell gives xsave the
# illumos kernel needs. Reports the captured console for the gate checks.
#
#   qemu-boot-test.sh disk  <image.img>  <seconds> [bios|uefi] [logfile]
#   qemu-boot-test.sh iso    <image.iso>  <seconds> [bios|uefi] [logfile] [target.img]
#
# For an ISO with an auto-install marker, pass a blank target.img so the ISO's
# live installer installs to it (the ISO's SOLNIX_AUTOINSTALL flow), then this
# harness can be re-run against that target as a disk.
set -uo pipefail

MODE="${1:?usage: qemu-boot-test.sh disk|iso <image> <seconds> [bios|uefi] [log] [target]}"
IMG="${2:?image path}"
SECS="${3:-180}"
FW="${4:-bios}"
LOG="${5:-/tmp/solnix-qemu-$MODE.log}"
TARGET="${6:-}"

OVMF_CODE="${OVMF_CODE:-/nix/store/0wbr8qhmbddqd419hfapj3pkzn71xrq1-OVMF-202402-fd/FV/OVMF_CODE.fd}"
OVMF_VARS="${OVMF_VARS:-/nix/store/0wbr8qhmbddqd419hfapj3pkzn71xrq1-OVMF-202402-fd/FV/OVMF_VARS.fd}"

: > "$LOG"
WORK="$(mktemp -d /tmp/solnix-qemu.XXXXXX)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

common=( -M q35 -cpu Haswell -m 4096 -smp 2 -nographic -serial "file:$LOG" -no-reboot )
[ "$FW" = uefi ] && { cp "$OVMF_VARS" "$WORK/vars.fd"; common+=( -drive "if=pflash,format=raw,unit=0,readonly=on,file=$OVMF_CODE" -drive "if=pflash,format=raw,unit=1,file=$WORK/vars.fd" ); }

echo "=== qemu $MODE boot: img=$IMG fw=$FW timeout=${SECS}s log=$LOG ===" >&2

if [ "$MODE" = disk ]; then
  # fresh copy of the disk each attempt (never mutate the artifact)
  cp "$IMG" "$WORK/disk.img"
  timeout --foreground "$SECS" qemu-system-x86_64 "${common[@]}" \
    -drive "file=$WORK/disk.img,format=raw,if=none,id=d0" \
    -device virtio-blk-pci,drive=d0 >/dev/null 2>&1 || true
elif [ "$MODE" = iso ]; then
  args=( -cdrom "$IMG" -boot d )
  if [ -n "$TARGET" ]; then
    cp "$TARGET" "$WORK/target.img" 2>/dev/null || qemu-img create -f raw "$WORK/target.img" 8G >/dev/null
    args+=( -drive "file=$WORK/target.img,format=raw,if=none,id=t0" -device virtio-blk-pci,drive=t0 )
  fi
  timeout --foreground "$SECS" qemu-system-x86_64 "${common[@]}" "${args[@]}" >/dev/null 2>&1 || true
  # if a target was installed to, keep it for a follow-up disk boot
  [ -n "$TARGET" ] && cp "$WORK/target.img" "$TARGET.installed" 2>/dev/null || true
else
  echo "unknown MODE=$MODE" >&2; exit 2
fi

echo "=== console log ($LOG) tail ===" >&2
tail -80 "$LOG" 2>/dev/null
echo "=== gate-check grep ===" >&2
grep -iE 'solnix|current-system|nix-store|EDITION|multi-user|console login|login:|core file' "$LOG" 2>/dev/null | tail -30
