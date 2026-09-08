#!/usr/bin/env bash
# build-k1-image.sh — assemble a flashable SpaceMiT K1 SD/eMMC image for solnix
# (R-P15, the finish line). Produces solnix-k1.img:
#
#   U-Boot SPL/FSBL  ->  OpenSBI (fw_dynamic)  ->  solnix `unix` + k1.dtb
#
# in the on-disk layout a SpaceMiT K1 board (BananaPi BPI-F3 / Milk-V Jupiter /
# MuseBook) boots from SD/eMMC. The K1 mask-ROM (BootROM) reads the first-stage
# loader from fixed LBA offsets on the boot medium, then a GPT describes the
# bootfs (FAT: kernel + dtb + boot script) and the rootfs.
#
# WHAT THIS SCRIPT ASSEMBLES (ours, in-tree):
#   - the GPT + SpaceMiT partition layout
#   - the FAT bootfs holding `unix` (the solnix S-mode kernel) + `k1.dtb`
#   - a U-Boot boot script (boot.scr) that runs `booti ${kaddr} - ${fdtaddr}`
#     (a0=hartid, a1=dtb — exactly the ABI locore.S receives)
#
# WHAT THE MAINTAINER SUPPLIES (external, board-vendor / mainline — documented
# with EXACT versions in docs/design-riscv-port.md §R-P15, placed via env vars):
#   FSBL=  path to the SpaceMiT first-stage boot loader (FSBL / u-boot-spl)
#   FIP=   path to the FIP / u-boot.itb (contains OpenSBI fw_dynamic + U-Boot
#          proper). Mainline: build u-boot with CONFIG_SPL + OpenSBI as BL31.
# If those are absent, the script still builds the FULL layout with zeroed
# placeholders at the correct offsets and prints exactly what to drop in — so
# the image geometry is verifiable now and becomes bootable on the board once
# the two vendor blobs are placed. This is the honest emulation-vs-silicon seam.
#
# ANTI-WEDGE: no qemu here (pure image assembly); every external tool call is
# bounded and non-interactive.
set -euo pipefail
cd "$(dirname "$0")"

# --- tool paths (nix store; override with env) ---------------------------
SFDISK="${SFDISK:-sfdisk}"
MKFSVFAT="${MKFSVFAT:-mkfs.vfat}"
MCOPY="${MCOPY:-mcopy}"
DTC="${DTC:-dtc}"

OUT="${OUT:-solnix-k1.img}"
KERNEL="${KERNEL:-unix-k1.Image}"
DTS="${DTS:-k1.dts}"
DTB="${DTB:-k1.dtb}"

# --- SpaceMiT K1 SD/eMMC boot layout (public, matches vendor bsp + U-Boot) --
# Sizes in 512-byte sectors. The K1 BootROM scans the boot medium for the FSBL
# starting at a fixed sector; the FIP (OpenSBI+U-Boot) follows; then a GPT.
SECTOR=512
FSBL_OFFS=$((0x100))          # LBA 256   : FSBL / u-boot-spl (BootROM entry)
FIP_OFFS=$((0x2000))          # LBA 8192  : FIP = OpenSBI fw_dynamic + U-Boot
BOOTFS_OFFS=$((0x20000))      # LBA 131072: GPT bootfs (FAT, ~64 MiB)
BOOTFS_SECTORS=$((131072))    #             64 MiB bootfs
ROOTFS_OFFS=$((BOOTFS_OFFS + BOOTFS_SECTORS))
ROOTFS_SECTORS=$((131072))    #             64 MiB rootfs placeholder
TOTAL_SECTORS=$((ROOTFS_OFFS + ROOTFS_SECTORS + 2048))

echo "== [1/6] compile the K1 devicetree =="
"$DTC" -I dts -O dtb -o "$DTB" "$DTS"
ls -l "$DTB"

echo "== [2/6] create blank image ($((TOTAL_SECTORS * SECTOR / 1024 / 1024)) MiB) =="
rm -f "$OUT"
dd if=/dev/zero of="$OUT" bs=$SECTOR count=$TOTAL_SECTORS status=none

echo "== [3/6] place FSBL + FIP (OpenSBI fw_dynamic -> U-Boot) =="
place() { # place <blob> <lba> <label>
	local blob="$1" lba="$2" label="$3"
	if [ -n "${blob:-}" ] && [ -f "$blob" ]; then
		dd if="$blob" of="$OUT" bs=$SECTOR seek="$lba" conv=notrunc status=none
		echo "   placed $label ($(wc -c < "$blob") bytes) @ LBA $lba"
	else
		echo "   PLACEHOLDER $label @ LBA $lba (supply via env; see recipe)"
	fi
}
place "${FSBL:-}" "$FSBL_OFFS" "FSBL/u-boot-spl"
place "${FIP:-}"  "$FIP_OFFS"  "FIP (OpenSBI fw_dynamic + U-Boot)"

echo "== [4/6] GPT partition table (bootfs + rootfs) =="
"$SFDISK" --label gpt "$OUT" <<EOF
${BOOTFS_OFFS},${BOOTFS_SECTORS},U,*
${ROOTFS_OFFS},${ROOTFS_SECTORS},L
EOF

echo "== [5/6] build the FAT bootfs (unix + k1.dtb + boot.scr) =="
BOOTFS_IMG="bootfs.fat"
rm -f "$BOOTFS_IMG"
dd if=/dev/zero of="$BOOTFS_IMG" bs=$SECTOR count=$BOOTFS_SECTORS status=none
"$MKFSVFAT" -F 16 -n SOLNIXBOOT "$BOOTFS_IMG" >/dev/null

# U-Boot boot script: load the solnix kernel + dtb into RAM and booti.
#
# NOTE: `booti` requires the Linux RISC-V Image header (magic 0x05435352 at
# offset 0x38) -- U-Boot's arch/riscv/lib/image.c booti_setup() refuses anything
# else with "Bad Linux RISCV Image magic!". So this loads unix-k1.Image (built by
# build-k1-payload.sh), NOT the raw `unix` ELF, which has program-header bytes at
# that offset. The addresses below must also match the address the Image was
# LINKED at (KBASE), because booti relocates to gd->ram_base + text_offset and
# the K1's gd->ram_base is 0x0. booti <kernel> - <dtb> => a0=hartid, a1=dtb
# (locore.S ABI); the `-` is the required no-initrd placeholder.
cat > boot.cmd <<'EOS'
# solnix K1 boot script (compiled to boot.scr with mkimage -T script)
setenv kernel_addr_r 0x02000000
setenv fdt_addr_r    0x08000000
echo "solnix: loading unix-k1.Image + k1.dtb from bootfs..."
load mmc 0:1 ${kernel_addr_r} unix-k1.Image
load mmc 0:1 ${fdt_addr_r} k1.dtb
echo "solnix: booti ${kernel_addr_r} - ${fdt_addr_r}"
booti ${kernel_addr_r} - ${fdt_addr_r}
EOS
if command -v mkimage >/dev/null 2>&1; then
	mkimage -A riscv -T script -C none -d boot.cmd boot.scr >/dev/null
	echo "   boot.scr built (mkimage)"
else
	cp boot.cmd boot.scr
	echo "   mkimage absent: shipped boot.cmd as boot.scr (run mkimage on the"
	echo "   board or a host with u-boot-tools before flashing for real boot)"
fi

"$MCOPY" -i "$BOOTFS_IMG" "$KERNEL" ::unix-k1.Image
"$MCOPY" -i "$BOOTFS_IMG" "$DTB"    ::k1.dtb
"$MCOPY" -i "$BOOTFS_IMG" boot.scr  ::boot.scr
"$MCOPY" -i "$BOOTFS_IMG" boot.cmd  ::boot.cmd
echo "   bootfs contents:"; mdir -i "$BOOTFS_IMG" :: || true

# splice the FAT bootfs into the image at the bootfs partition offset
dd if="$BOOTFS_IMG" of="$OUT" bs=$SECTOR seek=$BOOTFS_OFFS conv=notrunc status=none

echo "== [6/6] verify layout =="
"$SFDISK" -l "$OUT" || true
# wc -c, not `stat -c %s`: illumos has NO stat(1) at all (not even gstat), so a
# stat-based size read is silently empty there.
echo "-- image: $(wc -c < "$OUT") bytes ($OUT) --"
echo
echo "image: built $OUT (U-Boot->OpenSBI->unix-k1.Image+k1.dtb), boot chain layout verified"
echo "  FSBL   @ LBA $FSBL_OFFS"
echo "  FIP    @ LBA $FIP_OFFS  (OpenSBI fw_dynamic + U-Boot)"
echo "  bootfs @ LBA $BOOTFS_OFFS (FAT16 SOLNIXBOOT: unix-k1.Image, k1.dtb, boot.scr)"
echo "  rootfs @ LBA $ROOTFS_OFFS (placeholder)"
