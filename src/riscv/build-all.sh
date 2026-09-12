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
#     ⚠️ PIN gcc 14.3.0 for the committed generated userland
#     (src/riscv/uts/user_elfs.h, user/libc-riscv.a) -- that is the version those
#     bytes were produced with, so pin it for reproducibility.
#     NOTE: a regenerated userland breaking the boot was FIRST blamed on a gcc
#     15.2.0-vs-14.x skew. That was WRONG: gcc 14.3.0 fails identically. The real
#     cause was three pre-existing KERNEL bugs that any userland rebuild exposed
#     (second-fork COW dropping PTE_COW in hat_riscv.c, the copy_lofault redirect
#     ignoring SPP in trap.c, and this_cpu() masking rather than validating in
#     proc.c) -- all now fixed. Pin the version for reproducibility, not because
#     the compiler was at fault.
#     (a) stock riscv64-unknown-elf-gcc 14.3.0 (the R-P64 virtio_gpu harness used
#         this; fastest to obtain -- nix: nixpkgs#pkgsCross.riscv64-embedded.gcc,
#         or a distro riscv64-elf-gcc). Set RISCV_GCC to its bin dir.
#         ⚠️ nixpkgs installs this as riscv64-NONE-elf-*, not
#         riscv64-unknown-elf-*. Both spellings now work (see the probe below),
#         so no symlink farm is needed. The exact invocation that is known to
#         work on the dev box:
#           RISCV_GCC=/nix/store/<hash>-riscv64-none-elf-gcc-wrapper-14.3.0/bin \
#             bash src/riscv/build-all.sh rp64
#         Resolve <hash> with:
#           ls -d /nix/store/*-riscv64-none-elf-gcc-wrapper-14.3.0/bin | tail -1
#     (b) the solnix riscv64-solaris cross gcc (gcc-sol-cfg3) for a full
#         Solaris-ABI userland. Build once from src/riscv/gcc/ (documented there);
#         this is what a native K1 daily-driver eventually wants.
set -euo pipefail

PHASE="${1:-rp64}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"        # solnix repo root
SRC="$REPO/src/riscv"

# TOOLCHAIN PREFIX: accept EITHER spelling.
#
# This script asked for riscv64-unknown-elf-* only. nixpkgs
# pkgsCross.riscv64-embedded -- the toolchain the header itself recommends and
# the one every gate script under uts/ defaults to -- installs
# riscv64-none-elf-*. The mismatch is not a build failure but a `no gcc at ...`
# exit, which reads as "toolchain missing" and sent one run off building a
# symlink farm. Both prefixes name the same bare-metal ELF target, so probe.
# TC= overrides for a third spelling (e.g. riscv64-elf from a distro package).
: "${RISCV_GCC:?set RISCV_GCC to a riscv64 gcc bin dir (see header)}"
if [ -n "${TC:-}" ]; then
	PREFIXES="$TC"
else
	PREFIXES="riscv64-unknown-elf riscv64-none-elf riscv64-elf"
fi
GCC=""
for p in $PREFIXES; do
	if [ -x "$RISCV_GCC/$p-gcc" ]; then
		TC="$p"; GCC="$RISCV_GCC/$p-gcc"; LD="$RISCV_GCC/$p-ld"
		break
	fi
done
[ -n "$GCC" ] || {
	echo "no riscv64 gcc in $RISCV_GCC"
	echo "  tried prefixes: $PREFIXES"
	echo "  contents: $(ls "$RISCV_GCC" 2>/dev/null | head -5 | tr '\n' ' ')"
	echo "  set TC=<prefix> if yours is spelled differently"
	exit 1
}
echo "  toolchain prefix: $TC"

CFLAGS="-march=rv64gc_zifencei -mabi=lp64d -mcmodel=medany -ffreestanding \
	-fno-stack-protector -fno-pie -O2 -Wall -Wno-unused"

# KERNEL OBJECT LIST -- EXPLICIT, NOT A GLOB.
#
# This was `for c in uts/*.c`, and the glob made the script unrunnable: uts/
# also holds three files that are NOT part of the freestanding kernel and
# cannot compile without the full illumos uts header tree (68 headers absent
# here -- sys/stream.h, sys/regset.h, sys/sysmacros.h, ...):
#
#   asy_nsuart.c  vendored 8250/16550 STREAMS driver (needs sys/stream.h)
#   fpu.c         needs sys/regset.h
#   sendsig.c     needs sys/sysmacros.h
#
# They are staged for a later phase; the live console driver is uart.c. A glob
# also silently picks up any future staged file, so the list is explicit and
# matches uts/build-scanout.sh -- the build that is actually gated. Keep the two
# in step: if a source is added to one, add it to the other.
KSRCS="sbi trap hat_riscv timer plic aia fdt cmo vm_page kmem proc as elf
	syscall uart sdhci uproc unixsock virtio vioblk blkfs vionet rootfs
	fp port startup main"
KASM="image_header fpsave locore trap swtch copy"
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
	# .S first: riscv.ld wants .text.image_header at byte 0 of .text so the
	# same kernel can also be booti'd by U-Boot on real silicon.
	for b in $KASM; do
		o="$OUT/$b.o"
		[ "$b" = trap ] && o="$OUT/trap_asm.o"   # trap.S vs trap.c collide
		$GCC $CFLAGS -I"$SRC/uts" -c "$SRC/uts/$b.S" -o "$o"
		objs="$objs $o"
	done
	for b in $KSRCS; do
		o="$OUT/$b.o"
		$GCC $CFLAGS -I"$SRC/uts" -c "$SRC/uts/$b.c" -o "$o"
		objs="$objs $o"
	done
	# R-P64: the scanout seam. BOTH objects are required -- uproc.c calls
	# fb_open/fb_close/fb_ioctl/fb_mmap, so linking virtio_gpu.c without fb.c
	# leaves four undefined symbols.
	local RP64="$REPO/src/riscv-port/rp64/kernel"
	if [ "$PHASE" = "rp64" ] && [ -f "$RP64/virtio_gpu.c" ]; then
		echo "  + R-P64 virtio_gpu.c + fb.c (2D display / /dev/fb)"
		for b in virtio_gpu fb; do
			$GCC $CFLAGS -DGPU_IDENTITY_MAP -I"$SRC/uts" -I"$RP64" \
				-c "$RP64/$b.c" -o "$OUT/$b.o"
			objs="$objs $OUT/$b.o"
		done
	fi
	# THE LINKER SCRIPT IS riscv.ld. This said unix.ld, which does not exist
	# and never has (git has only uts/riscv.ld). The defect was LATENT: the
	# glob above died on asy_nsuart.c first, so the link was never reached.
	# The `2>/dev/null || <link with no -T>` fallback does not silently ship a
	# bad kernel -- MEASURED: it exits 1, because riscv.ld is what defines
	# __bss_end / _image_text_offset / _image_size. What it DOES do is discard
	# the one useful line ("cannot open linker script file .../unix.ld") and
	# replace it with a pile of undefined-reference errors pointing at
	# __bss_end -- a wrong-cause diagnostic for a missing-file problem.
	# No fallback: a link that needs riscv.ld must fail saying so.
	$LD -T "$SRC/uts/riscv.ld" -o "$OUT/unix.elf" $objs
	echo "  unix.elf: $(wc -c < "$OUT/unix.elf")B"
	# Assert the layout, or a wrong-address link looks like a pass. 0x80200000
	# is riscv.ld's default KBASE (qemu-virt / K1); the K3 relink lives in
	# uts/build-k3-payload.sh, which passes --defsym KBASE/KDRAM_BASE.
	local ent
	ent=$("$RISCV_GCC/$TC-readelf" -h "$OUT/unix.elf" | awk '/Entry point/ {print $4}')
	case $ent in
	0x80200040) echo "  entry $ent (riscv.ld default KBASE) OK" ;;
	*) echo "  FAIL entry $ent, want 0x80200040 -- wrong linker script?"; return 1 ;;
	esac
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
