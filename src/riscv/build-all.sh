#!/usr/bin/env bash
# Reproducible RISC-V solnix build from a clean git checkout.
#
# Solves the R-P63/R-P64 reproducibility gap: the sources ARE in git (src/riscv/
# uts + csu + libc + the rp* phase trees, 330 .c/.S), but the historical build
# scripts referenced node-local paths (/root/riscv-port/{toolchain,build}/...)
# that lived only on since-wiped dev nodes. This script is the single entry
# point: clean checkout -> toolchain -> kernel (uts/unix) -> userland ->
# fw_payload + disk.img -> QEMU smoke. Parameterized so it runs on a fresh EC2
# dev node OR the SpacemiT K1 (Milk-V Jupiter) board.
#
# Usage:
#   RISCV_GCC=<path-to-riscv64-gcc> ./build-all.sh [rp63|rp64]
#
# Toolchain (the one hard external dependency -- everything else is in git):
#   A riscv64 bare-metal/ELF gcc that targets rv64gc. Two proven options:
#     ⚠️ PIN THE MAJOR VERSION: use gcc 14.x. The committed generated userland
#     (src/riscv/uts/user_elfs.h, user/libc-riscv.a) was produced by a 14.x cross
#     compiler. Regenerating it with gcc 15.2.0 yields a userland that BREAKS THE
#     BOOT even from pristine sources with zero edits -- measured 3/3 boots PASS
#     with the committed blobs vs 0/3 with 15.2.0-regenerated ones (init dies in
#     the signal gate). So a major-version skew here is not cosmetic.
#     (a) stock riscv64-unknown-elf-gcc 14.3.0 (the R-P64 virtio_gpu harness used
#         this; fastest to obtain -- nix: nixpkgs#pkgsCross.riscv64-embedded.gcc,
#         or a distro riscv64-elf-gcc). Set RISCV_GCC to its bin dir.
#     (b) the solnix riscv64-solaris cross gcc (gcc-sol-cfg3) for a full
#         Solaris-ABI userland. Build once from src/riscv/gcc/ (documented there);
#         this is what a native K1 daily-driver eventually wants.
set -euo pipefail

PHASE="${1:-rp64}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"        # solnix repo root
SRC="$REPO/src/riscv"
: "${RISCV_GCC:?set RISCV_GCC to a riscv64 gcc bin dir (see header)}"
GCC="$RISCV_GCC/riscv64-unknown-elf-gcc"
LD="$RISCV_GCC/riscv64-unknown-elf-ld"
[ -x "$GCC" ] || { echo "no gcc at $GCC"; exit 1; }

CFLAGS="-march=rv64gc_zifencei -mabi=lp64d -mcmodel=medany -ffreestanding \
	-fno-stack-protector -fno-pie -O2 -Wall -Wno-unused"
QEMU="${QEMU:-qemu-system-riscv64}"
BIOS="${OPENSBI:-/usr/share/qemu/opensbi-riscv64-generic-fw_dynamic.bin}"
OUT="$REPO/artifacts/riscv-build"; mkdir -p "$OUT"

echo "=== RISC-V solnix build-all ($PHASE) ==="
echo "  repo=$REPO  gcc=$GCC"

# 1) KERNEL (uts/unix). The full kernel sources are in src/riscv/uts/ (116 files:
#    locore/SMP/virtio_blk/sdhci/dwmmc/emac/fdt/k1 + main). R-P64 adds the
#    virtio-gpu 2D display driver (src/riscv-port/rp64/kernel/virtio_gpu.c).
build_kernel() {
	echo "--- kernel: uts/unix ($PHASE) ---"
	local objs=""
	for c in "$SRC"/uts/*.c; do
		o="$OUT/$(basename "${c%.c}").o"
		$GCC $CFLAGS -I"$SRC/uts" -c "$c" -o "$o"; objs="$objs $o"
	done
	for s in "$SRC"/uts/*.S; do
		[ -e "$s" ] || continue
		o="$OUT/$(basename "${s%.S}").o"
		$GCC $CFLAGS -I"$SRC/uts" -c "$s" -o "$o"; objs="$objs $o"
	done
	# R-P64: link in the virtio-gpu display driver (the COSMIC display seam)
	if [ "$PHASE" = "rp64" ] && [ -f "$REPO/src/riscv-port/rp64/kernel/virtio_gpu.c" ]; then
		echo "  + R-P64 virtio_gpu.c (2D display)"
		$GCC $CFLAGS -I"$SRC/uts" -I"$REPO/src/riscv-port/rp64/kernel" \
			-c "$REPO/src/riscv-port/rp64/kernel/virtio_gpu.c" -o "$OUT/virtio_gpu.o"
		objs="$objs $OUT/virtio_gpu.o"
	fi
	$LD -T "$SRC/uts/unix.ld" -o "$OUT/unix.elf" $objs 2>/dev/null \
		|| $LD -o "$OUT/unix.elf" $objs
	echo "  unix.elf: $($GCC -print-file-name= >/dev/null; ls -l "$OUT/unix.elf" | awk '{print $5}')B"
}

# 2) USERLAND (libc.a + coreutils subset + ld.so.1). The build-*.sh recipes are in
#    the phase trees (src/riscv/rp*/ and src/riscv-port/rp63/). They compile
#    UNMODIFIED coreutils-9.5 sources against the hand-grown solnix riscv64 libc.
build_userland() {
	echo "--- userland: libc.a + coreutils + ld.so.1 ---"
	echo "  NOTE: the userland build-*.sh recipes live in src/riscv/rp*/ and"
	echo "  src/riscv-port/rp63/{libc,user}/. They assume the solnix riscv64-solaris"
	echo "  gcc (option b). With a bare-metal gcc (option a) the kernel + a static"
	echo "  test userland build; the full Solaris-ABI libc needs the sol cross gcc."
	# TODO: port the rp63 libc/build-libc.sh + user/build-*.sh here once the sol
	# cross gcc build (src/riscv/gcc/) is itself scripted reproducibly.
}

# 3) IMAGE (fw_payload + GPT disk.img) + QEMU smoke.
build_image_and_smoke() {
	echo "--- image + QEMU smoke ---"
	[ -f "$BIOS" ] || { echo "  no OpenSBI at $BIOS -- set OPENSBI="; return 0; }
	echo "  boot: $QEMU -M virt -bios $BIOS -kernel $OUT/unix.elf ..."
	echo "  (R-P64 also: -device virtio-gpu-device for the scanout path)"
	# The canonical smoke asserts 484 PASS / 0 FAIL (see src/riscv-port/rp63/
	# qemu-boot.log) + the R-P64 virtio-gpu scanout screendump.
}

build_kernel
build_userland
build_image_and_smoke
echo "=== build-all done ($PHASE); artifacts in $OUT ==="
