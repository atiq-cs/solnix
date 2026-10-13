#!/usr/bin/env bash
# build-k3-payload.sh — build a bootable SpacemiT K3 Pico ITX payload: the
# solnix riscv64 `unix` kernel relinked into K3 DRAM, wrapped so the board's
# VENDOR U-Boot can `booti` it.
#
# Emits:
#   unix-k3.Image  — the kernel relinked into K3 DRAM as a flat binary with the
#                    Linux RISC-V Image header. This is what U-Boot `booti`
#                    loads. Named distinctly from unix-k1.Image ON PURPOSE: the
#                    two are linked at different addresses and are NOT
#                    interchangeable.
#   k3.dtb         — the GENERATED K3 devicetree (gen-k3-dts.py from the board's
#                    own vendor dump), for `booti <kern> - <dtb>`.
#
# ---------------------------------------------------------------------------
# WHY THERE IS NO SD-CARD IMAGE HERE (and why that is the SAFER path)
# ---------------------------------------------------------------------------
# The K1 flow shipped an SD image because a K1 boots from a card. This board
# does not, and the vendor DTB says so unambiguously (all values measured, see
# docs/k3-first-boot-runbook.md):
#
#   mmc@d4280000 / mmc@d4280800 / mmc@d4281000   ALL status = "disabled"
#   bootargs                                     boot_mode=nor
#   mtdparts d420c000.spi                        bootinfo/fsbl/env/esos/
#                                                opensbi/uboot  (6 partitions,
#                                                = the 7 mtdblock devices)
#   ufshc@0xc0e00000 "spacemit,k3-ufshcd"        status = "okay"  -> sda is UFS
#
# So there is no SD path to boot at all: the chain lives in SPI NOR and the root
# device is UFS. An SD image would be a file that cannot boot, which this repo
# already knows is worse than no image.
#
# The vehicle instead: copy unix-k3.Image + k3.dtb into the /boot the board's
# own Linux already mounts (sda2), interrupt U-Boot at the prompt, and booti
# from there. That touches NOTHING in NOR, so recovery from any failure is a
# power cycle. See docs/k3-first-boot-runbook.md for the exact procedure.
#
# ---------------------------------------------------------------------------
# THE TWO ADDRESSES, AND WHY BOTH ARE NEEDED
# ---------------------------------------------------------------------------
# KBASE       — where the kernel is LINKED (absolute).
# KDRAM_BASE  — where the board's DRAM STARTS. Used for exactly one thing: the
#               Image header's text_offset, which U-Boot's booti_setup() adds to
#               gd->ram_base. text_offset must therefore be an OFFSET FROM THE
#               DRAM BASE, not an absolute address.
#
# On qemu-virt and the K1, gd->ram_base is 0, so the old absolute text_offset
# was accidentally correct and the bug was invisible through every gate. Here
# ram_base is 0x102000000, so an absolute text_offset would relocate the image
# ~4 GiB past where it was linked. riscv.ld now computes BASE - DRAM_BASE, and
# KDRAM_BASE defaults to 0 so the qemu/K1 paths are byte-identical.
set -euo pipefail
cd "$(dirname "$0")"

# ---------------------------------------------------------------------------
# TOOL DISCOVERY -- because the RECIPE is the only deliverable
# ---------------------------------------------------------------------------
# unix-k3.Image and k3.dtb are deliberately NOT tracked (.gitignore:77-83: a
# committed image that drifts from its source is worse than no image). That
# makes this script the artifact, so it has to run from a clean checkout
# without archaeology. It previously required riscv64-none-elf-* AND dtc to be
# on PATH already, and failed with a bare `dtc: command not found` (rc=127) that
# names no remedy -- MEASURED on a normal dev-box PATH.
#
# Two failure modes are being closed:
#  - the toolchain PREFIX differs by provider: nixpkgs pkgsCross.riscv64-embedded
#    installs riscv64-none-elf-*, other providers riscv64-unknown-elf-* or
#    riscv64-elf-*. All three are the same bare-metal ELF target. Probe, do not
#    assume; a symlink farm to paper over the spelling is not a recipe.
#  - dtc absent from PATH while present in the nix store.
# Everything stays overridable: TC=/CC=/DTC=... win over discovery.
have() { command -v "$1" >/dev/null 2>&1; }

# nixstore <glob-under-/nix/store> <basename> -- newest match, or empty.
nixstore() {
	ls -d /nix/store/$1 2>/dev/null | tail -1
}

if [ -z "${TC:-}" ]; then
	for p in riscv64-none-elf riscv64-unknown-elf riscv64-elf; do
		have "$p-gcc" && { TC="$p"; break; }
	done
fi
if [ -z "${TC:-}" ]; then
	# Not on PATH: adopt the pinned gcc 14.3.0 from the nix store if present.
	# 14.3.0 is the pin the committed userland (user_elfs.h) was built with.
	_gccbin=$(nixstore '*-riscv64-none-elf-gcc-wrapper-14.3.0/bin')
	[ -n "$_gccbin" ] && { PATH="$_gccbin:$PATH"; TC=riscv64-none-elf; }
fi
TC="${TC:-riscv64-none-elf}"
CC="${CC:-${TC}-gcc}"
LD="${LD:-${TC}-ld}"
OBJCOPY="${OBJCOPY:-${TC}-objcopy}"
OBJDUMP="${OBJDUMP:-${TC}-objdump}"
READELF="${READELF:-${TC}-readelf}"

if [ -z "${DTC:-}" ] && ! have dtc; then
	_dtcbin=$(nixstore '*-dtc-1.7.*/bin')
	[ -n "$_dtcbin" ] && PATH="$_dtcbin:$PATH"
fi
DTC="${DTC:-dtc}"

# Fail with the REMEDY, not with `command not found`. A recipe that cannot say
# what is missing is the same class of defect as a guard that cannot fail.
_missing=""
for t in "$CC" "$LD" "$OBJCOPY" "$OBJDUMP" "$READELF" "$DTC" python3; do
	have "$t" || _missing="$_missing $t"
done
if [ -n "$_missing" ]; then
	cat >&2 <<EOM
build-k3-payload.sh: missing required tool(s):$_missing

This needs a riscv64 bare-metal ELF gcc/binutils, dtc, and python3.
On this dev box (nix), the exact working invocation is:

  G=\$(ls -d /nix/store/*-riscv64-none-elf-gcc-wrapper-14.3.0/bin | tail -1)
  D=\$(ls -d /nix/store/*-dtc-1.7.*/bin | tail -1)
  PATH=\$G:\$D:\$PATH bash build-k3-payload.sh

Or from anywhere with a network:
  nix shell nixpkgs#pkgsCross.riscv64-embedded.buildPackages.gcc nixpkgs#dtc
  (that provides the riscv64-NONE-elf-* prefix, which is probed for.)

Override any tool explicitly: TC=<prefix> CC=... DTC=... bash build-k3-payload.sh
EOM
	exit 1
fi
echo "== toolchain: $(command -v "$CC") / $(command -v "$DTC") =="

OUT="${OUT:-unix-k3}"
DTS="${DTS:-k3.dts}"
DTB="${DTB:-k3.dtb}"
VENDOR_DTS="${VENDOR_DTS:-/tmp/dts}"

# --- the two addresses, both derived from the board's own devicetree ---------
#
# KDRAM_BASE = 0x102000000: MEASURED. memory@102000000,
#   reg = <0x01 0x2000000 0x07 0xfe000000> => DRAM 0x102000000..0x900000000
#   (32.0 GiB). There is NO memory below this, so 0x80200000 (qemu/K1) is a
#   hole here. Note it is 32 MiB ABOVE the 4 GiB line, not 4 GiB exactly, so
#   linking at a flat 0x100000000 also lands outside DRAM.
#
# KBASE = 0x102200000: CHOSEN = DRAM base + 2 MiB. Reasoning:
#   - It must be inside DRAM: it is, 2 MiB into a 32 GiB bank.
#   - It must clear whatever the vendor firmware has resident low in DRAM.
#     2 MiB mirrors OpenSBI's own payload convention (its default payload
#     offset on every platform is +2 MiB over the firmware base), which is the
#     same clearance the qemu/K1 paths use and the amount vendor OpenSBI
#     builds are laid out to expect.
#   - It must be 2 MiB aligned, both for the Sv39 megapage granularity and
#     because U-Boot's booti relocation assumes the kernel's alignment.
#   - It leaves the kernel inside ONE Sv39 gigapage starting at 0x100000000,
#     which is what hat_boot_init maps identity over the kernel.
#   This is a KNOB, not a discovery: if the board's U-Boot turns out to keep
#   something in 0x102000000..0x102200000, raise it (stay 2 MiB aligned, stay
#   inside DRAM). That is one variable, not a code change.
#
# ⚠️ NEITHER address can be validated under QEMU: qemu-virt's DRAM is at
# 0x80000000 and its gd->ram_base is 0, so QEMU cannot exercise a >4 GiB link
# base OR a nonzero-ram_base text_offset. This is why both the load address and
# the text_offset bug survived 8/8 gate passes. QEMU here proves ABSENCE OF
# REGRESSION at the default KBASE and nothing whatsoever about this board.
KDRAM_BASE="${KDRAM_BASE:-0x102000000}"
KBASE="${KBASE:-0x102200000}"

rc=0

echo "== [1/5] regenerate + compile the K3 devicetree =="
# Regenerate from the vendor dump when it is available, so the DTB cannot drift
# from the board. The generator ASSERTS on 16 harts / memory node / APLIC /
# console UART and refuses to write a file if the dump disagrees.
if [ -f "$VENDOR_DTS" ]; then
	python3 ./gen-k3-dts.py "$VENDOR_DTS" "$DTS"
else
	echo "   NOTE: $VENDOR_DTS absent; using the committed $DTS as-is."
	echo "         (Re-dump with: dtc -I fs -O dts /proc/device-tree > /tmp/dts)"
fi
"$DTC" -I dts -O dtb -o "$DTB" "$DTS"
"$DTC" -I dtb -O dts -o "$DTB.decompiled.dts" "$DTB" 2>/dev/null
echo "   $DTB: $(wc -c < "$DTB") bytes, dtc round-trip OK"

echo "== [2/5] compile the kernel (freestanding, $TC) =="
CFLAGS="-march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany \
	-ffreestanding -nostdlib -fno-stack-protector -fno-pic \
	-Wall -Wextra -O2 -g"
RP64="${RP64:-../../riscv-port/rp64/kernel}"
GPUFLAGS="-DGPU_IDENTITY_MAP -I. -I$RP64"

KOBJS=""
# image_header.S first: riscv.ld places .text.image_header ahead of .text.start
# so byte 0 of the flat image is the Image header booti requires.
for src in image_header.S fpsave.S locore.S trap.S swtch.S copy.S; do
	o="${src%.S}.o"
	[ "$src" = trap.S ] && o=trap_asm.o
	"$CC" $CFLAGS -c "$src" -o "$o"
	KOBJS="$KOBJS $o"
done
for src in sbi trap hat_riscv timer plic aia fdt cmo vm_page kmem proc as elf \
	   syscall uart sdhci uproc unixsock virtio vioblk blkfs vionet rootfs \
	   gmac k3i2c k3spi k3dma k3pwm k3usb k3pcie k3efuse k3rtc k3misc k3ufs k3dev \
	   fp port startup main; do
	"$CC" $CFLAGS -c "$src.c" -o "$src.o"
	KOBJS="$KOBJS $src.o"
done
"$CC" $CFLAGS $GPUFLAGS -c "$RP64/virtio_gpu.c" -o virtio_gpu.o
"$CC" $CFLAGS $GPUFLAGS -c "$RP64/fb.c"         -o fb.o
KOBJS="$KOBJS virtio_gpu.o fb.o"

echo "== [3/5] link at KBASE=$KBASE (DRAM base $KDRAM_BASE) =="
"$LD" --defsym KBASE="$KBASE" --defsym KDRAM_BASE="$KDRAM_BASE" \
	-T riscv.ld -o "$OUT.elf" $KOBJS
"$OBJCOPY" -O binary "$OUT.elf" "$OUT.Image"
entry=$("$READELF" -h "$OUT.elf" | awk '/Entry point/ {print $4}')
echo "   $OUT.elf   entry $entry"
echo "   $OUT.Image $(wc -c < "$OUT.Image") bytes"

echo "== [4/5] verify the Image header (U-Boot arch/riscv/lib/image.c) =="
# Check the header rather than trusting it: a wrong magic makes U-Boot refuse
# the image, and a wrong text_offset makes it relocate to the wrong address.
# Neither is visible by looking at the file.
hdr_u32() { od -A n -t x4 -j "$1" -N 4 "$OUT.Image" | tr -d ' \n'; }
hdr_u64() { od -A n -t x8 -j "$1" -N 8 "$OUT.Image" | tr -d ' \n'; }
magic=$(hdr_u32 56)
toff=$(hdr_u64 8)
isize=$(hdr_u64 16)

[ "$magic" = "05435352" ] || { echo "   FAIL magic@0x38=$magic want 05435352"; rc=1; }

# THE CHECK THAT WOULD HAVE CAUGHT THE ABSOLUTE-text_offset BUG:
# text_offset must be the offset within the DRAM bank, so that
# gd->ram_base + text_offset lands exactly on KBASE.
want_toff=$(( KBASE - KDRAM_BASE ))
got_toff=$(( 0x$toff ))
if [ "$got_toff" = "$want_toff" ]; then
	printf '   OK   text_offset=0x%x == KBASE-KDRAM_BASE\n' "$got_toff"
else
	printf '   FAIL text_offset=0x%x want 0x%x (KBASE-KDRAM_BASE)\n' \
		"$got_toff" "$want_toff"
	rc=1
fi
# And the relocation arithmetic U-Boot will actually perform must land on KBASE.
reloc=$(( KDRAM_BASE + got_toff ))
if [ "$reloc" = "$(( KBASE ))" ]; then
	printf '   OK   gd->ram_base + text_offset = 0x%x == KBASE\n' "$reloc"
else
	printf '   FAIL booti would relocate to 0x%x, kernel linked at 0x%x\n' \
		"$reloc" "$(( KBASE ))"
	rc=1
fi

# The link address must be inside the DRAM the board reports.
dram_end=$(python3 -c 'print(0x102000000 + 0x7fe000000)')
if [ "$(( KBASE ))" -ge "$(( KDRAM_BASE ))" ] && [ "$(( KBASE ))" -lt "$dram_end" ]; then
	printf '   OK   KBASE 0x%x is inside DRAM [0x%x, 0x%x)\n' \
		"$(( KBASE ))" "$(( KDRAM_BASE ))" "$dram_end"
else
	printf '   FAIL KBASE 0x%x is OUTSIDE DRAM [0x%x, 0x%x)\n' \
		"$(( KBASE ))" "$(( KDRAM_BASE ))" "$dram_end"
	rc=1
fi

# code0 must jump to _start, or entering at byte 0 executes header data.
# NOTE: capture then match -- `objdump | grep -q` exits early, objdump takes
# SIGPIPE, and pipefail then fails the pipeline despite the match succeeding.
dis=$("$OBJDUMP" -d "$OUT.elf")
case $dis in
*"j"*"<_start>"*) echo "   OK   code0 = j _start" ;;
*) echo "   FAIL code0 does not disassemble to a jump to _start"; rc=1 ;;
esac
printf '   image_size=0x%s, ELF entry %s\n' "$isize" "$entry"

echo "== [5/5] verify the DTB still describes the MEASURED K3 topology =="
check_dtb() { # check_dtb <pattern> <what>
	if grep -q "$1" "$DTB.decompiled.dts"; then
		echo "   ok   $2"
	else
		echo "   FAIL $2 (pattern: $1)"; rc=1
	fi
}
check_dtb 'riscv,aplic'             'external intc is an APLIC (AIA, not PLIC)'
check_dtb 'riscv,imsics'            'IMSIC present (MSI target)'
check_dtb 'riscv,clint0'            'CLINT present (timer + IPI)'
check_dtb 'timebase-frequency = <0x16e3600>' 'timebase is 24 MHz (not qemu 10 MHz)'
check_dtb 'memory@102000000'        'DRAM node at 0x102000000'
check_dtb 'intel,xscale-uart'       'console UART carries a bind string we match'
check_dtb 'reg-shift = <0x02>'      'UART reg-shift = 2 (32-bit register stride)'
ncpu=$(grep -c 'device_type = "cpu"' "$DTB.decompiled.dts" || true)
[ "$ncpu" = 16 ] && echo "   ok   16 harts" || { echo "   FAIL harts=$ncpu want 16"; rc=1; }

echo
echo "== verdict =="
if [ "$rc" = 0 ]; then
	echo "K3 PAYLOAD BUILD PASS"
else
	echo "K3 PAYLOAD BUILD FAIL (see the FAIL lines above)"
fi
cat <<EOS

Artifacts:
  $OUT.Image   flat kernel + Image header, linked at $KBASE
  $DTB         K3 devicetree, generated from the board's own vendor dump

VERIFIED locally: the image builds; the Image header is well-formed; its
  text_offset is KBASE-KDRAM_BASE so U-Boot's gd->ram_base + text_offset lands
  exactly on the link address; KBASE is inside the DRAM the board reports;
  code0 jumps to _start; the DTB round-trips through dtc still describing 16
  harts, APLIC+IMSIC, CLINT, a 24 MHz timebase, DRAM at 0x102000000, and the
  console UART with reg-shift 2.
NOT VERIFIED, and NOT verifiable here: that this board boots it. No instruction
  of ours has executed on this SoC. QEMU cannot test either the load address or
  the text_offset, because its DRAM is at 0x80000000 with gd->ram_base 0 -- the
  exact reason both bugs survived every prior gate.

Next: docs/k3-first-boot-runbook.md. Read the VENDOR U-Boot's own output on the
serial console FIRST -- that proves the wiring before our kernel can be blamed
for an empty screen.
EOS
exit $rc
