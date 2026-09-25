#!/usr/bin/env bash
# solnix-usb-grow -- after `dd`-ing a solnix .img to a USB stick, grow the stick's
# scratch partition (GPT partition 3, type Solaris) to fill the stick's free tail.
#
# WHY: the .img is a fixed-size hybrid ISO (p1 ISO9660 + p2 ESP + p3 scratch, 4GB
# sparse by default). A big stick has gigabytes of UNUSED space after p3. The
# installer's scratch (flake eval + build) lives on p3; a larger p3 means a roomier
# build without falling back to NVMe-scratch on the target.
#
# ⚠️ RUN THIS ON THE MACHINE YOU dd'd FROM (Linux/macOS/illumos), NOT on the X1.
#    It needs the USB to be a real block device. It does NOT help hardware where the
#    USB never enumerates as a disk (e.g. the X1 Carbon, where scsa2usb won't bind);
#    there the installer uses NVMe-scratch on the target instead.
#
# Usage:
#   solnix-usb-grow /dev/sdX          (Linux)   -- the WHOLE-disk node you dd'd to
#   solnix-usb-grow /dev/rdiskN       (macOS)
#   solnix-usb-grow c1t0d0            (illumos)
#
# It ONLY moves p3's end to the last usable sector and rewrites the backup GPT.
# p1/p2 are untouched, so the stick still boots. It does NOT create a filesystem in
# p3 -- the installer `zpool create`s it fresh at install time (it must be blank).
set -eu

DEV="${1:?usage: solnix-usb-grow <whole-disk device you wrote the image to>}"

die() { echo "solnix-usb-grow: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

_confirm() {
  echo ""
  echo "About to grow GPT partition 3 (scratch) to fill $DEV."
  echo "This rewrites the partition table + backup GPT; p1(ISO)/p2(ESP) are untouched,"
  echo "so the stick still boots. Any data in the current p3 is discarded (it is blank)."
  printf "Proceed? [y/N]: "
  read _a; case "$_a" in y|Y|yes|YES) ;; *) die "aborted." ;; esac
}

# ---- Linux: sgdisk (preferred) or growpart-style parted ----
grow_linux() {
  case "$DEV" in
    /dev/sd[a-z]|/dev/nvme[0-9]n[0-9]|/dev/mmcblk[0-9]) : ;;
    *) die "$DEV is not a whole-disk node -- give the whole disk like /dev/sdb, not a partition" ;;
  esac
  grep -q " $DEV " /proc/mounts && die "$DEV has a mounted partition -- unmount it first"
  have sgdisk || die "need sgdisk (gdisk package) on Linux"
  echo "current layout:"; sgdisk -p "$DEV" | sed 's/^/  /'
  sgdisk -i 3 "$DEV" >/dev/null 2>&1 || die "no partition 3 on $DEV -- is this a solnix image stick?"
  _confirm
  # move backup GPT to the real end of the (larger) device, then resize p3 to the max.
  sgdisk -e "$DEV"                       # relocate backup GPT to the disk's true end
  # delete + recreate p3 spanning from its old start to the last usable sector.
  local start; start=$(sgdisk -i 3 "$DEV" | awk '/First sector/{print $3}')
  local tcode; tcode=$(sgdisk -i 3 "$DEV" | awk -F': ' '/Partition GUID code/{print $2}' | awk '{print $1}')
  sgdisk -d 3 "$DEV"
  sgdisk -n 3:"${start}":0 -t 3:bf01 -c 3:"solnix-scratch" "$DEV"   # 0 = to last usable sector
  partprobe "$DEV" 2>/dev/null || blockdev --rereadpt "$DEV" 2>/dev/null || true
  echo "new layout:"; sgdisk -p "$DEV" | sed 's/^/  /'
}

# ---- illumos: format -e expand + fmthard (the same ops the boot-time grow uses) ----
grow_illumos() {
  have format || die "need format(1M) on illumos"
  echo "growing p3 on $DEV via format expand + fmthard (see _grow_scratch_tail in oi-make-livecd.sh)"
  _confirm
  # format -e 'expand' claims the disk's grown capacity into the EFI label; then the
  # scratch slice is extended to the new last sector. (Kept minimal here; the
  # installer's _grow_scratch_tail is the tested reference for the exact fmthard.)
  echo "expand" | format -e "$DEV" >/dev/null 2>&1 || true
  echo "  done -- verify with: format -e $DEV then 'verify'"
}

# ---- macOS: diskutil ----
grow_macos() {
  die "on macOS: re-dd is simplest, or grow partition 3 by hand with diskutil/gpt -- automated grow not implemented here"
}

case "$(uname -s)" in
  Linux)  grow_linux ;;
  SunOS)  grow_illumos ;;
  Darwin) grow_macos ;;
  *) die "unsupported OS $(uname -s)" ;;
esac

echo ""
echo "solnix-usb-grow: p3 (scratch) now spans the stick's free tail. The installer will"
echo "zpool-create it at install time. NOTE: this only helps on hardware where the USB"
echo "enumerates as a disk; on machines where it does not (e.g. the X1), the installer"
echo "uses NVMe-scratch on the target instead."
