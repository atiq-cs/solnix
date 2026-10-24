#!/usr/bin/env bash
# build-unix.sh — build the illumos riscv64 `unix` S-mode payload and boot it
# under OpenSBI on qemu-system-riscv64 -machine virt (R-P2 gate).
#
# SUCCESS = the SunOS/solnix-riscv64 banner prints (proves OpenSBI -> S-mode
# illumos entry -> SBI console -> banner).
#
# Toolchain: bare-metal riscv64 cross (freestanding, no libc). Default prefix
# riscv64-none-elf (nixpkgs pkgsCross.riscv64-embedded). Override with TC=.
#
# ANTI-WEDGE: the qemu run is `timeout 120` and NEVER foreground-waits forever;
# it captures the console to a log then returns.
set -euo pipefail
cd "$(dirname "$0")"

TC="${TC:-riscv64-none-elf}"
CC="${CC:-${TC}-gcc}"
LD="${LD:-${TC}-ld}"
OBJDUMP="${OBJDUMP:-${TC}-objdump}"
QEMU="${QEMU:-qemu-system-riscv64}"
OUT="${OUT:-unix}"
LOG="${LOG:-unix-qemu-boot.log}"

# Freestanding kernel flags: no libc, no builtins that assume a hosted env,
# medany code model (kernel at 0x8020_0000 needs medany, not medlow), rv64imac.
# Freestanding kernel flags. rv64gc + lp64d (HARD float): the kernel links
# fpsave.S (fsd/fld, needs the F/D extensions to assemble) for the per-process
# FP context switch, and the embedded userland (fptest/newlibtest) is hard-float
# lp64d — the kernel ABI must match. zifencei: ld.so.1's I-cache coherence
# (fence.i) on the first-map path. Mirrors build-all.sh / build-scanout.sh.
CFLAGS="-march=rv64gc_zifencei -mabi=lp64d -mcmodel=medany \
	-ffreestanding -nostdlib -fno-stack-protector -fno-pic -Iriscv64 \
	-Wall -Wextra -O2 -g ${EXTRA_CFLAGS:-}"

echo "== compile (freestanding, $TC) =="
"$CC" $CFLAGS -c image_header.S -o image_header.o
"$CC" $CFLAGS -c locore.S    -o locore.o
"$CC" $CFLAGS -c trap.S      -o trap_asm.o
"$CC" $CFLAGS -c swtch.S     -o swtch.o
"$CC" $CFLAGS -c copy.S      -o copy.o
"$CC" $CFLAGS -c fpsave.S    -o fpsave.o
"$CC" $CFLAGS -c sbi.c       -o sbi.o
"$CC" $CFLAGS -c trap.c      -o trap.o
"$CC" $CFLAGS -c hat_riscv.c -o hat_riscv.o
"$CC" $CFLAGS -c timer.c     -o timer.o
"$CC" $CFLAGS -c plic.c      -o plic.o
"$CC" $CFLAGS -c aia.c       -o aia.o
"$CC" $CFLAGS -c cmo.c       -o cmo.o
"$CC" $CFLAGS -c fp.c        -o fp.o
"$CC" $CFLAGS -c port.c      -o port.o
"$CC" $CFLAGS -c unixsock.c  -o unixsock.o
"$CC" $CFLAGS -c fdt.c       -o fdt.o
"$CC" $CFLAGS -c vm_page.c   -o vm_page.o
"$CC" $CFLAGS -c kmem.c      -o kmem.o
"$CC" $CFLAGS -c proc.c      -o proc.o
"$CC" $CFLAGS -c as.c        -o as.o
"$CC" $CFLAGS -c elf.c       -o elf.o
"$CC" $CFLAGS -c syscall.c   -o syscall.o
"$CC" $CFLAGS -c uart.c      -o uart.o
"$CC" $CFLAGS -c sdhci.c     -o sdhci.o
"$CC" $CFLAGS -c uproc.c     -o uproc.o
"$CC" $CFLAGS -c virtio.c    -o virtio.o
"$CC" $CFLAGS -c vioblk.c    -o vioblk.o
"$CC" $CFLAGS -c blkfs.c     -o blkfs.o
"$CC" $CFLAGS -c vionet.c    -o vionet.o
. ./lwip-objs.sh		# rvsrv: lwIP + inet.c -> $LWIPOBJS
"$CC" $CFLAGS -c gmac.c      -o gmac.o
"$CC" $CFLAGS -c k3i2c.c     -o k3i2c.o
"$CC" $CFLAGS -c k3spi.c     -o k3spi.o
"$CC" $CFLAGS -c k3dma.c     -o k3dma.o
"$CC" $CFLAGS -c k3pwm.c     -o k3pwm.o
"$CC" $CFLAGS -c k3usb.c     -o k3usb.o
"$CC" $CFLAGS -c k3pcie.c    -o k3pcie.o
"$CC" $CFLAGS -c k3efuse.c   -o k3efuse.o
"$CC" $CFLAGS -c k3rtc.c     -o k3rtc.o
"$CC" $CFLAGS -c k3misc.c    -o k3misc.o
"$CC" $CFLAGS -c k3ufs.c     -o k3ufs.o
"$CC" $CFLAGS -c k3dev.c     -o k3dev.o
"$CC" $CFLAGS -c rootfs.c    -o rootfs.o
"$CC" $CFLAGS -c startup.c   -o startup.o
"$CC" $CFLAGS -c main.c      -o main.o

# R-P64 scanout seam. virtio_gpu.c + fb.c live in src/riscv-port/rp64/kernel/
# (not uts/); uproc.c calls fb_open/fb_close/fb_ioctl/fb_mmap and startup.c
# calls virtio_gpu_init/fb_init/fb_selftest, so BOTH must be linked or the
# kernel has undefined fb_*/virtio_gpu_* symbols. -DGPU_IDENTITY_MAP: the uts
# kernel reaches device MMIO through the identity/direct map (same as build-all).
RP64="$(cd "$(dirname "$0")/../../riscv-port/rp64/kernel" && pwd)"
"$CC" $CFLAGS -DGPU_IDENTITY_MAP -I. -I"$RP64" -c "$RP64/virtio_gpu.c" -o virtio_gpu.o
"$CC" $CFLAGS -DGPU_IDENTITY_MAP -I. -I"$RP64" -c "$RP64/fb.c"         -o fb.o

echo "== link (riscv.ld @ 0x80200000) =="
"$LD" -T riscv.ld -o "$OUT" image_header.o locore.o trap_asm.o swtch.o fpsave.o \
	sbi.o trap.o hat_riscv.o timer.o plic.o aia.o cmo.o fp.o port.o unixsock.o \
	fdt.o vm_page.o kmem.o proc.o \
	as.o elf.o syscall.o uart.o sdhci.o uproc.o copy.o \
	virtio.o vioblk.o blkfs.o vionet.o $LWIPOBJS rootfs.o startup.o main.o \
	gmac.o k3i2c.o k3spi.o k3dma.o k3pwm.o k3usb.o k3pcie.o k3efuse.o \
	k3rtc.o k3misc.o k3ufs.o k3dev.o \
	virtio_gpu.o fb.o

echo "== image info =="
file "$OUT" || true
"$OBJDUMP" -h "$OUT" 2>/dev/null | sed -n '1,20p' || true
echo "-- entry / first instrs --"
"$OBJDUMP" -d "$OUT" 2>/dev/null | sed -n '/<_start>:/,/ret/p' | head -30 || true

echo "== boot under OpenSBI (qemu virt, -smp 4, default -bios, 120s timeout) =="
# -bios default => qemu's bundled OpenSBI (fw_dynamic); -kernel loads our ELF
# as the S-mode payload (OpenSBI jumps to 0x80200000 = _start). -smp 4 gives
# the R-P4 SMP bring-up 3 secondary harts to start via SBI HSM.
#
# R-P6..R-P64: attach the virtio devices the embedded gates exercise:
#   hd0  (disk.img)   the R-P6 MBR test disk (vioblk sector-0 read)
#   fs0  (rootfs.img) the ustar on-disk root FS (/sbin/init + /bin/* off disk)
#   data0(data.img)   the writable SNFS data disk (R-P12 on-disk write/sync)
#   virtio-net        discovery + ARP TX gate
#   virtio-gpu        the R-P64 scanout device -> /dev/fb (fbtest + miniwl).
#     WITHOUT it the kernel correctly skips /dev/fb and the fbtest/miniwl gates
#     report "no framebuffer" — attach it so the full display path is exercised.
# qemu populates virtio-mmio slots in REVERSE (first -device -> highest slot).
DISK="${DISK:-disk.img}"
if [ ! -f "$DISK" ]; then
	echo "== creating a 1 MiB test disk with an MBR 0x55aa signature =="
	dd if=/dev/zero of="$DISK" bs=512 count=2048 2>/dev/null
	printf 'SOLNIX-RISCV-ROOTFS-R-P6\0' | dd of="$DISK" bs=1 seek=0 conv=notrunc 2>/dev/null
	printf '\x55\xaa' | dd of="$DISK" bs=1 seek=510 conv=notrunc 2>/dev/null
fi
FSIMG="${FSIMG:-rootfs.img}"
DATAIMG="${DATAIMG:-data.img}"
FSARGS=""
[ -f "$FSIMG" ] && FSARGS="-drive file=$FSIMG,if=none,id=fs0,format=raw -device virtio-blk-device,drive=fs0"
DATAARGS=""
[ -f "$DATAIMG" ] && DATAARGS="-drive file=$DATAIMG,if=none,id=data0,format=raw -device virtio-blk-device,drive=data0"
VIRTIO_ARGS="-global virtio-mmio.force-legacy=false \
	-drive file=$DISK,if=none,id=hd0,format=raw \
	-device virtio-blk-device,drive=hd0 \
	$FSARGS $DATAARGS \
	-netdev user,id=n0 -device virtio-net-device,netdev=n0 \
	-device virtio-gpu-device"
: > "$LOG"
timeout 120 "$QEMU" -machine "${MACHINE:-virt}" -smp "${SMP:-4}" -nographic -bios default \
	-kernel "$OUT" $VIRTIO_ARGS 2>&1 | tee "$LOG" || true
echo "== done; console captured to $LOG =="
