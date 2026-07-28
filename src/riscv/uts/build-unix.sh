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
CFLAGS="-march=rv64imac_zicsr -mabi=lp64 -mcmodel=medany \
	-ffreestanding -nostdlib -fno-stack-protector -fno-pic \
	-Wall -Wextra -O2 -g"

echo "== compile (freestanding, $TC) =="
"$CC" $CFLAGS -c locore.S    -o locore.o
"$CC" $CFLAGS -c trap.S      -o trap_asm.o
"$CC" $CFLAGS -c swtch.S     -o swtch.o
"$CC" $CFLAGS -c copy.S      -o copy.o
"$CC" $CFLAGS -c sbi.c       -o sbi.o
"$CC" $CFLAGS -c trap.c      -o trap.o
"$CC" $CFLAGS -c hat_riscv.c -o hat_riscv.o
"$CC" $CFLAGS -c timer.c     -o timer.o
"$CC" $CFLAGS -c plic.c      -o plic.o
"$CC" $CFLAGS -c fdt.c       -o fdt.o
"$CC" $CFLAGS -c vm_page.c   -o vm_page.o
"$CC" $CFLAGS -c kmem.c      -o kmem.o
"$CC" $CFLAGS -c proc.c      -o proc.o
"$CC" $CFLAGS -c as.c        -o as.o
"$CC" $CFLAGS -c elf.c       -o elf.o
"$CC" $CFLAGS -c syscall.c   -o syscall.o
"$CC" $CFLAGS -c uart.c      -o uart.o
"$CC" $CFLAGS -c uproc.c     -o uproc.o
"$CC" $CFLAGS -c virtio.c    -o virtio.o
"$CC" $CFLAGS -c vioblk.c    -o vioblk.o
"$CC" $CFLAGS -c vionet.c    -o vionet.o
"$CC" $CFLAGS -c rootfs.c    -o rootfs.o
"$CC" $CFLAGS -c startup.c   -o startup.o
"$CC" $CFLAGS -c main.c      -o main.o

echo "== link (riscv.ld @ 0x80200000) =="
"$LD" -T riscv.ld -o "$OUT" locore.o trap_asm.o swtch.o sbi.o trap.o \
	hat_riscv.o timer.o plic.o fdt.o vm_page.o kmem.o proc.o \
	as.o elf.o syscall.o uart.o uproc.o copy.o \
	virtio.o vioblk.o vionet.o rootfs.o startup.o main.o

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
# R-P6: attach a virtio-blk disk (disk.img) so vioblk can read sector 0, and a
# virtio-net device so discovery finds it. qemu populates virtio-mmio slots in
# REVERSE (first -device -> highest slot 0x10008000 / IRQ 8).
DISK="${DISK:-disk.img}"
if [ ! -f "$DISK" ]; then
	echo "== creating a 1 MiB test disk with an MBR 0x55aa signature =="
	dd if=/dev/zero of="$DISK" bs=512 count=2048 2>/dev/null
	printf 'SOLNIX-RISCV-ROOTFS-R-P6\0' | dd of="$DISK" bs=1 seek=0 conv=notrunc 2>/dev/null
	printf '\x55\xaa' | dd of="$DISK" bs=1 seek=510 conv=notrunc 2>/dev/null
fi
VIRTIO_ARGS="-global virtio-mmio.force-legacy=false \
	-drive file=$DISK,if=none,id=hd0,format=raw \
	-device virtio-blk-device,drive=hd0 \
	-netdev user,id=n0 -device virtio-net-device,netdev=n0"
: > "$LOG"
timeout 120 "$QEMU" -machine virt -smp "${SMP:-4}" -nographic -bios default \
	-kernel "$OUT" $VIRTIO_ARGS 2>&1 | tee "$LOG" || true
echo "== done; console captured to $LOG =="
