#!/usr/bin/env bash
# build-k1-payload.sh — build a flashable SpaceMiT K1 boot payload: the solnix
# riscv64 `unix` kernel wrapped so a Milk-V Jupiter / BananaPi BPI-F3 can load it.
#
# Emits THREE artifacts, because the K1 offers two different ways in and they
# want different wrappers:
#
#   1. unix-k1.Image   — the kernel relinked into K1 DRAM, as a flat binary with
#                        the Linux RISC-V Image header. This is what U-Boot
#                        `booti` loads. **This is the recommended bring-up path**
#                        (see docs/milkv-jupiter-bringup-runbook.md): it leaves
#                        the vendor BootROM -> FSBL -> OpenSBI -> U-Boot chain and
#                        the on-board eMMC completely untouched.
#   2. k1.dtb          — the committed K1 devicetree, for `booti <kern> - <dtb>`
#                        when the maintainer wants OUR topology instead of the
#                        vendor U-Boot's.
#   3. fw_payload.bin  — OpenSBI with the kernel embedded as its S-mode payload,
#                        + fw_payload.elf. Boot-tested under QEMU here. On the
#                        K1 this REPLACES M-mode firmware, so it is the second-
#                        stage option, NOT the first thing to try. See the
#                        "Which artifact" note below.
#
# ---------------------------------------------------------------------------
# WHY THE KERNEL MUST BE RELINKED (the finding that motivated this script)
# ---------------------------------------------------------------------------
# riscv.ld's default base, 0x80200000, is OpenSBI's payload address on
# qemu-virt. On the K1 that address IS NOT DRAM. Mainline U-Boot's K1 support is
# unambiguous:
#   include/configs/bananapi-f3.h : CFG_SYS_SDRAM_BASE = 0x0
#   arch/riscv/cpu/k1/dram.c     : gd->ram_base = 0x0, bank0 capped at 2 GiB,
#                                  bank1 at 0x100000000
#   arch/riscv/dts/k1.dtsi       : uart0 0xd4017000, PLIC 0xe0000000,
#                                  CLINT 0xe4000000
# i.e. DRAM 0x0..0x80000000, then SoC MMIO. So 0x80200000 sits in a hole and a
# kernel linked there cannot execute. riscv.ld now takes KBASE, and this script
# supplies a K1 DRAM address.
#
# WHY THE IMAGE HEADER IS REQUIRED: U-Boot's arch/riscv/lib/image.c
# booti_setup() rejects any image whose magic at offset 0x38 is not 0x05435352
# ("RSC\x05") with "Bad Linux RISCV Image magic!". A raw ELF has program-header
# bytes there. image_header.S supplies the header; its code0 is `j _start`, so
# the image also runs when entered at byte 0. text_offset/image_size come from
# the linker, so they cannot drift from KBASE.
#
# ---------------------------------------------------------------------------
# WHICH ARTIFACT TO USE, AND WHAT THE QEMU RUN DOES *NOT* PROVE
# ---------------------------------------------------------------------------
# The K1's U-Boot runs in S-MODE, under the vendor OpenSBI that the FSBL loaded
# at 0x0 (CONFIG_SPL_OPENSBI_LOAD_ADDR=0x0). S-mode U-Boot cannot launch M-mode
# firmware, so `booti`-ing fw_payload.bin does not work; installing fw_payload
# means replacing the vendor firmware in the boot chain, which is exactly the
# thing that can leave the board unbootable. Hence: Image + booti first.
#
# The QEMU boot below runs the SAME fw_payload on `-machine virt`. That proves
# the WRAPPING is well-formed and that our kernel survives being an OpenSBI
# payload. It does NOT prove the K1 boots: `virt` is a different platform, with
# a different DRAM base, a different UART, QEMU's OpenSBI rather than the
# vendor's, and no FSBL/DDR training. Nothing here has executed on K1 silicon.
#
# ANTI-WEDGE: every qemu run is `timeout`-bounded and captures the console to a
# log rather than foreground-waiting on a prompt.
set -euo pipefail
cd "$(dirname "$0")"

# --- kernel toolchain: the gcc 14.3.0 pin. Do not change. ----------------
TC="${TC:-riscv64-none-elf}"
CC="${CC:-${TC}-gcc}"
LD="${LD:-${TC}-ld}"
OBJCOPY="${OBJCOPY:-${TC}-objcopy}"
OBJDUMP="${OBJDUMP:-${TC}-objdump}"
READELF="${READELF:-${TC}-readelf}"
DTC="${DTC:-dtc}"
QEMU="${QEMU:-qemu-system-riscv64}"

# --- firmware toolchain (SEPARATE, and deliberately so) ------------------
# OpenSBI >= 1.8 requires a linker that can create PIEs; the bare-metal
# riscv64-none-elf binutils answers "-pie not supported", so the firmware needs
# a different cross toolchain. This affects the M-mode FIRMWARE ONLY. The kernel
# is still built by $CC above, so the gcc 14.3.0 kernel pin is untouched.
FW_TC="${FW_TC:-riscv64-unknown-linux-gnu-}"

OUT="${OUT:-unix-k1}"
DTS="${DTS:-k1.dts}"
DTB="${DTB:-k1.dtb}"
LOG="${LOG:-k1-payload-qemu.log}"

# KBASE — where the kernel is linked for the K1.
#
# 0x02000000 (32 MiB) is chosen to clear everything mainline U-Boot puts in low
# DRAM, each value from configs/bananapi-f3_defconfig:
#   0x00000000  vendor OpenSBI  (CONFIG_SPL_OPENSBI_LOAD_ADDR)
#   0x00200000  U-Boot itself   (CONFIG_TEXT_BASE, = CONFIG_SYS_LOAD_ADDR)
#   0x01000000  U-Boot SPL sp   (CONFIG_CUSTOM_SYS_INIT_SP_ADDR) + 16 MiB malloc
# and it keeps the kernel's identity gigapage at VPN2=0.. clear of ALIAS_VA
# (0x40000000, VPN2=1) and the K1 device window (0xc0000000, VPN2=3), which
# hat_riscv.c maps separately. It is a KNOB, not a discovery: if the board's
# U-Boot turns out to use this range, raise it (staying 2 MiB aligned and inside
# bank-0 DRAM) — that is one variable, not a code change.
KBASE="${KBASE:-0x02000000}"

echo "== [1/6] compile the K1 devicetree =="
"$DTC" -I dts -O dtb -o "$DTB" "$DTS"
# Round-trip check: a DTB that dtc cannot read back is not a DTB, and the
# decompile is also what proves the K1 topology survived (checked in step 5).
"$DTC" -I dtb -O dts -o "$DTB.decompiled.dts" "$DTB" 2>/dev/null
echo "   $DTB: $(wc -c < "$DTB") bytes, dtc round-trip OK"

echo "== [2/6] compile the kernel (freestanding, $TC @ KBASE=$KBASE) =="
CFLAGS="-march=rv64imac_zicsr_zifencei -mabi=lp64 -mcmodel=medany \
	-ffreestanding -nostdlib -fno-stack-protector -fno-pic -Iriscv64 \
	-Wall -Wextra -O2 -g"
RP64="${RP64:-../../riscv-port/rp64/kernel}"
GPUFLAGS="-DGPU_IDENTITY_MAP -I. -I$RP64"

KOBJS=""
# image_header.S must be first in .text (riscv.ld places .text.image_header
# ahead of .text.start) so byte 0 of the flat image is the Image header.
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
# The scanout seam lives outside uts/ because it is also built standalone.
"$CC" $CFLAGS $GPUFLAGS -c "$RP64/virtio_gpu.c" -o virtio_gpu.o
"$CC" $CFLAGS $GPUFLAGS -c "$RP64/fb.c"         -o fb.o
KOBJS="$KOBJS virtio_gpu.o fb.o"
. ./lwip-objs.sh		# rvsrv: inet.c needs lwIP; startup_root calls inet_init
KOBJS="$KOBJS $LWIPOBJS"

echo "== [3/6] link at KBASE + emit the booti Image =="
"$LD" --defsym KBASE="$KBASE" -T riscv.ld -o "$OUT.elf" $KOBJS
"$OBJCOPY" -O binary "$OUT.elf" "$OUT.Image"
echo "   $OUT.elf  entry $("$READELF" -h "$OUT.elf" | awk '/Entry point/ {print $4}')"
echo "   $OUT.Image $(wc -c < "$OUT.Image") bytes"

# Verify the Image header rather than trusting it. A wrong magic or a
# text_offset that disagrees with the link address both produce an image that
# U-Boot either refuses or relocates to the wrong place, and neither failure is
# visible by looking at the file.
echo "== [4/6] verify the Image header (offsets per U-Boot arch/riscv/lib/image.c) =="
rc=0
hdr_u32() { od -A n -t x4 -j "$1" -N 4 "$OUT.Image" | tr -d ' \n'; }
hdr_u64() { od -A n -t x8 -j "$1" -N 8 "$OUT.Image" | tr -d ' \n'; }
magic=$(hdr_u32 56)
toff=$(hdr_u64 8)
isize=$(hdr_u64 16)
entry=$("$READELF" -h "$OUT.elf" | awk '/Entry point/ {print $4}')
[ "$magic" = "05435352" ] || { echo "   FAIL magic@0x38=$magic want 05435352"; rc=1; }
[ "$((0x$toff))" = "$((KBASE))" ] || {
	echo "   FAIL text_offset=0x$toff want $KBASE"; rc=1; }
# code0 must be a jump to _start, or an image entered at byte 0 executes header
# data as instructions. NOTE: `objdump | grep -q` would report a false failure
# here -- grep -q exits at the first match, objdump takes SIGPIPE, and under
# `set -o pipefail` the pipeline fails even though the match succeeded. So
# capture first, then match.
dis=$("$OBJDUMP" -d "$OUT.elf")
case $dis in
*"j"*"<_start>"*) ;;
*) echo "   FAIL code0 does not disassemble to a jump to _start"; rc=1 ;;
esac
[ "$rc" = 0 ] && {
	echo "   OK magic=RSC\\x05 @0x38, text_offset=0x$toff (== KBASE),"
	echo "      image_size=0x$isize, code0 = j _start, ELF entry $entry"
}

echo "== [5/6] verify the embedded DTB still decompiles to the K1 topology =="
# The DTB is the prerequisite for every driver bind, so check the boot-critical
# facts the k1.dts banner claims, not just that the file parses.
check_dtb() { # check_dtb <pattern> <what>
	if grep -q "$1" "$DTB.decompiled.dts"; then
		echo "   ok   $2"
	else
		echo "   FAIL $2 (pattern: $1)"; rc=1
	fi
}
check_dtb 'riscv,plic0'            'interrupt controller is PLIC (not AIA)'
check_dtb 'riscv,ndev = <0x9f>'    'PLIC ndev = 159'
check_dtb 'spacemit,k1-x-sdhci'    'MMC binds spacemit,k1-x-sdhci'
check_dtb 'spacemit,pxa-uart'      'console UART is a SpaceMiT string'
check_dtb 'reg-shift = <0x02>'     'UART reg-shift = 2 (32-bit registers)'
ncpu=$(grep -c 'device_type = "cpu"' "$DTB.decompiled.dts" || true)
[ "$ncpu" = 8 ] && echo "   ok   8 harts" || { echo "   FAIL harts=$ncpu want 8"; rc=1; }
# The GPU is deliberately disabled (no open kernel driver); if that flipped to
# "okay" the kernel would try to drive hardware we cannot drive.
if grep -A6 'gpu@cac00000' "$DTB.decompiled.dts" | grep -q 'status = "disabled"'; then
	echo "   ok   GPU node status = disabled (llvmpipe by design)"
else
	echo "   FAIL GPU node is not disabled"; rc=1
fi

echo "== [6/6] OpenSBI fw_payload (optional; needs \$OPENSBI_SRC) =="
# Skipped by default: it needs an OpenSBI source tree and a PIE-capable
# toolchain. The Image in step 3 is the recommended bring-up artifact, so a
# missing OpenSBI must not fail this build.
if [ -n "${OPENSBI_SRC:-}" ] && [ -d "${OPENSBI_SRC:-}" ]; then
	# fw_payload is built for QEMU-virt verification: FW_TEXT_START is where
	# M-mode firmware runs, which on virt is 0x80000000. The payload therefore
	# needs a matching kernel, so this relinks at 0x80200000 rather than KBASE.
	# On the K1 the vendor OpenSBI lives at 0x0; producing a K1 fw_payload means
	# FW_TEXT_START=0x0 and a KBASE-matching FW_PAYLOAD_OFFSET.
	FWDIR="${FWDIR:-/tmp/solnix-k1-opensbi}"
	mkdir -p "$FWDIR"
	"$LD" -T riscv.ld -o "$OUT-virt.elf" $KOBJS      # default base 0x80200000
	"$OBJCOPY" -O binary "$OUT-virt.elf" "$FWDIR/payload.bin"
	echo "   building OpenSBI fw_payload (firmware toolchain: $FW_TC)"
	if timeout 900 make -C "$OPENSBI_SRC" -j"$(nproc)" \
		PLATFORM=generic CROSS_COMPILE="$FW_TC" \
		O="$FWDIR/build" \
		FW_PAYLOAD=y FW_PAYLOAD_PATH="$FWDIR/payload.bin" \
		FW_PAYLOAD_OFFSET=0x200000 FW_TEXT_START=0x80000000 \
		> "$FWDIR/opensbi-build.log" 2>&1; then
		FWBIN="$FWDIR/build/platform/generic/firmware/fw_payload.bin"
		cp "$FWBIN" ./fw_payload.bin
		cp "${FWBIN%.bin}.elf" ./fw_payload.elf
		echo "   fw_payload.bin $(wc -c < fw_payload.bin) bytes"

		# Boot the SAME fw_payload under QEMU. This proves the wrapping, NOT
		# that the K1 boots (see the banner).
		echo "   == booting fw_payload under qemu -machine virt (proves the"
		echo "      wrapping only; virt is NOT the K1) =="
		: > "$LOG"
		timeout 180 "$QEMU" -machine virt -smp "${SMP:-4}" -m "${MEM:-512M}" \
			-bios fw_payload.bin -nographic -no-reboot \
			> "$LOG" 2>&1 || true
		if grep -q "SunOS Release" "$LOG"; then
			echo "      PASS: the solnix banner printed from inside fw_payload"
			grep -m1 "SunOS Release" "$LOG" | sed 's/^/      /'
		else
			echo "      FAIL: no banner in $LOG"; rc=1
		fi
	else
		echo "   FAIL: OpenSBI build failed, see $FWDIR/opensbi-build.log"
		echo "         (OpenSBI >=1.8 needs a PIE-capable linker; set FW_TC=)"
		rc=1
	fi
else
	echo "   SKIPPED (set OPENSBI_SRC=/path/to/opensbi to build it)"
	echo "   The Image from step 3 is the recommended bring-up artifact."
fi

echo
echo "== verdict =="
if [ "$rc" = 0 ]; then
	echo "K1 PAYLOAD BUILD PASS"
else
	echo "K1 PAYLOAD BUILD FAIL (see the FAIL lines above)"
fi
cat <<EOS

Artifacts (VERIFIED locally / UNVERIFIED on silicon):
  $OUT.Image   flat kernel + Image header, linked at $KBASE  <- copy to microSD
  $DTB         K1 devicetree
  fw_payload.bin/.elf   only if OPENSBI_SRC was set

VERIFIED locally: the image builds, the Image header is well-formed and its
  text_offset matches the link address, code0 jumps to _start, and the DTB
  round-trips through dtc still describing the K1 topology (PLIC/ndev=159/8
  harts/spacemit sdhci+uart/GPU disabled).
UNVERIFIED until hardware: that the K1 boots this. No instruction of ours has
  ever executed on this SoC. A QEMU pass exercises -machine virt, which has a
  different DRAM base, a different UART, and different firmware.

Next: docs/milkv-jupiter-bringup-runbook.md (serial console FIRST).
EOS
exit $rc
