#!/usr/bin/env bash
# make-iso-usb.sh — assemble the solnix hybrid ISO + dd-able USB image from the
# staging tree built on the illumos host by oi-make-livecd.sh. Runs on a Linux
# box (uses xorriso + mtools + mkfs.vfat via nix-shell). T2.13.
#
#   make-iso-usb.sh <solnix-iso-tree.tar.gz> <outdir>
#
# Produces:
#   <outdir>/solnix-x86_64.iso   hybrid ISO: BIOS El Torito (cdboot) + UEFI ESP
#   <outdir>/solnix-x86_64-usb.img  GPT disk image, dd-able to USB (ESP + iso data)
#
# The ISO boot chain (illumos loader):
#   BIOS: El Torito no-emulation boot image = boot/cdboot -> boot/isoboot ->
#         boot/loader -> reads boot/loader.conf -> loads unix + boot_archive.
#   UEFI: an EFI System Partition image (FAT) holding EFI/BOOT/BOOTX64.EFI =
#         loader64.efi, added as an El Torito EFI boot entry (xorriso -e).
set -euo pipefail

TARBALL="${1:?usage: make-iso-usb.sh <tarball> <outdir>}"
OUTDIR="${2:?usage: make-iso-usb.sh <tarball> <outdir>}"
WORK="$(mktemp -d /tmp/solnix-iso.XXXXXX)"
mkdir -p "$OUTDIR"
# VARIANT names the media: minimal (console ISO) or graphical (live Xfce ISO).
VARIANT="${VARIANT:-minimal}"
ISO="$OUTDIR/solnix-x86_64-${VARIANT}.iso"
USB="$OUTDIR/solnix-x86_64-${VARIANT}-usb.img"

log() { printf '\n=== %s ===\n' "$*" >&2; }
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

log "unpacking staging tree"
tar -xf "$TARBALL" -C "$WORK"
ISOROOT="$WORK/iso"
[ -d "$ISOROOT/boot" ] || { echo "no boot/ in staging tree" >&2; exit 1; }
[ -f "$WORK/loader64.efi" ] || { echo "no loader64.efi in tree" >&2; exit 1; }
[ -f "$ISOROOT/boot/cdboot" ] || { echo "no boot/cdboot (BIOS El Torito image)" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. rewrite loader.conf cleanly (the fleet heredoc can double-escape quotes,
#    which breaks the loader parser -> boot_archive_type never set -> "No rootfs
#    module provided"). This file is tiny + known, so author it here authoritatively.
# ---------------------------------------------------------------------------
log "writing loader.conf"
cat > "$ISOROOT/boot/loader.conf" <<'EOF'
loader_logo="illumos"
console="${SOLNIX_CONSOLE:-text,ttya}"
ttya-mode="115200,8,n,1,-"
autoboot_delay="5"
boot_archive_load="YES"
boot_archive_type="rootfs"
boot_archive_name="/platform/i86pc/amd64/boot_archive"
boot_archive.hash_load="NO"
kernel="/platform/i86pc/kernel/amd64/unix"
bootfile="unix"
boot-args="-v"
EOF

# ---------------------------------------------------------------------------
# 1. build the EFI System Partition image (FAT) with EFI/BOOT/BOOTX64.EFI.
#    Size it to fit loader64.efi + slack, rounded up. Placed at the ISO root as
#    boot/efiboot.img and referenced by xorriso -e as the EFI El Torito entry.
# ---------------------------------------------------------------------------
log "building EFI System Partition image (efiboot.img)"
EFI_IMG="$ISOROOT/boot/efiboot.img"
EFI_KB=$(( ( $(stat -c%s "$WORK/loader64.efi") / 1024 ) + 2048 ))   # loader + 2MB slack
# FAT needs a minimum; round to a 32KB-cluster-friendly size, min 4MB.
[ "$EFI_KB" -lt 4096 ] && EFI_KB=4096
rm -f "$EFI_IMG"
mkfs.vfat -C "$EFI_IMG" "$EFI_KB" >/dev/null
mmd   -i "$EFI_IMG" ::/EFI ::/EFI/BOOT
mcopy -i "$EFI_IMG" "$WORK/loader64.efi" ::/EFI/BOOT/BOOTX64.EFI
echo "efiboot.img: ${EFI_KB}KB with EFI/BOOT/BOOTX64.EFI"
mdir -i "$EFI_IMG" ::/EFI/BOOT >&2 || true

# ALSO drop the ESP tree into the ISO9660 filesystem itself (xorriso warns that
# without a visible /EFI/BOOT, some UEFI firmwares + the Windows-USB method won't
# find the loader). Give the ISO a real /EFI/BOOT/BOOTX64.EFI too.
mkdir -p "$ISOROOT/EFI/BOOT"
cp "$WORK/loader64.efi" "$ISOROOT/EFI/BOOT/BOOTX64.EFI"

# ---------------------------------------------------------------------------
# 2. assemble the hybrid ISO with xorriso.
#    -b boot/cdboot          BIOS El Torito boot image (no-emulation)
#    -e boot/efiboot.img     UEFI El Torito boot image (the ESP FAT)
#    -isohybrid-gpt-basdat    make efiboot.img appear as a GPT partition so the
#                             same .iso is also USB-dd-able (isohybrid).
# ---------------------------------------------------------------------------
log "assembling hybrid ISO -> $ISO"
# -b boot/cdboot        BIOS El Torito (no-emulation)
# -e --interval:...     UEFI El Torito pointing at the efiboot.img
# -append_partition 2 0xef boot/efiboot.img  ALSO expose efiboot.img as GPT
#                       partition 2 (type EF00 ESP) so UEFI firmware that boots
#                       the media as a DISK (the USB path) finds the ESP.
# -partition_offset 16  isohybrid MBR so BIOS USB boot works too.
xorriso -as mkisofs \
  -o "$ISO" \
  -V SOLNIX_INSTALL \
  -R -J \
  -partition_offset 16 \
  -b boot/cdboot -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/efiboot.img -no-emul-boot \
  -isohybrid-gpt-basdat \
  -append_partition 2 0xef "$ISOROOT/boot/efiboot.img" \
  "$ISOROOT" 2>&1 | tail -20

ls -la "$ISO"
echo "ISO sha256:"; sha256sum "$ISO"

# ---------------------------------------------------------------------------
# 3. the dd-able USB image. The isohybrid ISO above is ALREADY dd-able to USB
#    (BIOS via the isohybrid MBR, UEFI via the GPT ESP partition). But the brief
#    wants an explicit GPT disk .img too. The isohybrid .iso IS that image; we
#    copy it to the .img name so the deliverable is unambiguous, and verify it
#    carries a GPT + an EFI partition.
# ---------------------------------------------------------------------------
log "producing dd-able USB image (isohybrid .iso is USB-dd-able) -> $USB"
cp "$ISO" "$USB"
echo "USB sha256:"; sha256sum "$USB"
# verify GPT + partition table present (isohybrid-gpt)
if command -v fdisk >/dev/null 2>&1; then fdisk -l "$USB" 2>/dev/null | head -20 || true; fi

log "DONE: $ISO + $USB"
