#!/usr/bin/env bash
# mk-k1-sdcard.sh — build a microSD image that vendor U-Boot can `fatload` the
# solnix kernel from. Emits solnix-k1-sd.img: an MBR with ONE FAT32 partition
# holding exactly two files, unix-k1.Image and k1.dtb.
#
# WHY THIS IS DELIBERATELY NOT A BOOTABLE IMAGE
# ---------------------------------------------
# There is NO first-stage loader on this card, on purpose:
#
#   * We do not have the SpaceMiT FSBL/FIP blobs, and shipping a card with
#     ZEROED firmware at the BootROM's offsets is worse than shipping none --
#     it invites the BootROM to read a garbage first stage instead of cleanly
#     falling through to the on-board eMMC.
#   * The on-board eMMC vendor firmware (BootROM -> FSBL -> OpenSBI -> U-Boot)
#     is the KNOWN-GOOD boot chain and the maintainer's only easy way back. It
#     stays untouched. This card is only a place for that firmware to read two
#     files from.
#
# So the intended flow is: eMMC vendor U-Boot boots, the maintainer interrupts
# autoboot, and `fatload`s our kernel off this card into RAM. Nothing is written
# to any storage; the worst outcome is that the board ignores the card, and
# pulling it out restores the previous behaviour exactly.
#
# build-k1-image.sh is the OTHER thing: a full GPT boot layout with FSBL/FIP
# placeholders, for the eventual self-booting-card path. Do not use it for a
# first bring-up.
#
# UNVERIFIED-until-hardware: that the K1 BootROM, finding no valid FSBL on this
# card, falls through to eMMC rather than stopping. That is the safe direction
# (nothing of ours is in the boot chain) but it has not been observed.
#
# Needs no root and no loopback mount: mkfs.vfat + mcopy write the filesystem
# image directly.
set -euo pipefail
cd "$(dirname "$0")"

SFDISK="${SFDISK:-sfdisk}"
MKFSVFAT="${MKFSVFAT:-mkfs.vfat}"
MCOPY="${MCOPY:-mcopy}"
MDIR="${MDIR:-mdir}"

OUT="${OUT:-solnix-k1-sd.img}"
KERNEL="${KERNEL:-unix-k1.Image}"
DTB="${DTB:-k1.dtb}"

SECTOR=512
PART_OFFS=2048				# 1 MiB: conventional, clears the MBR
PART_SECTORS=$((131072))		# 64 MiB: above the FAT32 minimum
TOTAL_SECTORS=$((PART_OFFS + PART_SECTORS))

# Refuse to build from missing or stale inputs. unix-k1.Image is gitignored on
# purpose -- a stale flashable image is worse than none -- so the only correct
# response to an absent one is to send the operator back to the recipe, never to
# silently produce a card with nothing (or something old) on it.
for f in "$KERNEL" "$DTB"; do
	if [ ! -f "$f" ]; then
		echo "ERROR: $f not found." >&2
		echo "Build it first (it is gitignored deliberately):" >&2
		echo "  cd $(pwd)" >&2
		echo "  nix shell nixpkgs#pkgsCross.riscv64-embedded.buildPackages.gcc14 \\" >&2
		echo "            nixpkgs#pkgsCross.riscv64-embedded.buildPackages.binutils \\" >&2
		echo "            nixpkgs#dtc -c bash ./build-k1-payload.sh" >&2
		exit 1
	fi
done

# The Image header is what U-Boot's booti_setup() checks; a card whose kernel
# fails this cannot boot, and the failure on the board ("Bad Linux RISCV Image
# magic!") is indistinguishable from several other problems. Cheaper to catch
# here. Offset 0x38 = 56, per arch/riscv/lib/image.c.
magic=$(od -A n -t x4 -j 56 -N 4 "$KERNEL" | tr -d ' \n')
if [ "$magic" != "05435352" ]; then
	echo "ERROR: $KERNEL has magic@0x38=$magic, want 05435352." >&2
	echo "That is not a booti Image (did you copy unix-k1.elf?)." >&2
	exit 1
fi
echo "== [1/4] $KERNEL: Image magic 0x05435352 OK ($(wc -c < "$KERNEL") bytes) =="

echo "== [2/4] blank image ($((TOTAL_SECTORS * SECTOR / 1024 / 1024)) MiB) + MBR =="
rm -f "$OUT"
dd if=/dev/zero of="$OUT" bs=$SECTOR count=$TOTAL_SECTORS status=none
# MBR, not GPT: vendor U-Boot builds vary in GPT support, and one FAT32 primary
# partition is the most widely readable thing a `fatload mmc N:1` can find.
# Type 0c = FAT32 LBA. Bootable flag set for firmware that looks for it.
"$SFDISK" "$OUT" >/dev/null <<EOF
label: dos
${PART_OFFS},${PART_SECTORS},0c,*
EOF

echo "== [3/4] FAT32 filesystem with the kernel + dtb =="
FS="$(mktemp -u solnix-k1-fat.XXXXXX).img"
dd if=/dev/zero of="$FS" bs=$SECTOR count=$PART_SECTORS status=none
"$MKFSVFAT" -F 32 -n SOLNIX "$FS" >/dev/null
"$MCOPY" -i "$FS" "$KERNEL" ::unix-k1.Image
"$MCOPY" -i "$FS" "$DTB"    ::k1.dtb
"$MDIR" -i "$FS" :: || true
dd if="$FS" of="$OUT" bs=$SECTOR seek=$PART_OFFS conv=notrunc status=none
rm -f "$FS"

echo "== [4/4] verify =="
"$SFDISK" -l "$OUT"
# wc -c, not `stat -c %s`: illumos has no stat(1) at all, so a stat-based size
# gate is silently empty there and the check after it never runs.
echo "-- $OUT: $(wc -c < "$OUT") bytes --"

cat <<EOS

BUILT: $(pwd)/$OUT
  MBR, one FAT32 partition (type 0c) at LBA $PART_OFFS, label SOLNIX
  contents: unix-k1.Image, k1.dtb
  NO first-stage loader -- this card is not self-booting BY DESIGN (see banner).

Write it to a microSD (IDENTIFY THE DEVICE FIRST -- lsblk, confirm the size):

  lsblk
  sudo dd if=$(pwd)/$OUT of=/dev/sdX bs=4M conv=fsync status=progress

/dev/sdX is the WHOLE CARD (sdb, not sdb1). Writing to the wrong device
destroys that disk. Then: docs/milkv-jupiter-first-boot.md.
EOS
