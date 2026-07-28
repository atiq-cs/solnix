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
"$CC" $CFLAGS -c sbi.c       -o sbi.o
"$CC" $CFLAGS -c trap.c      -o trap.o
"$CC" $CFLAGS -c hat_riscv.c -o hat_riscv.o
"$CC" $CFLAGS -c timer.c     -o timer.o
"$CC" $CFLAGS -c main.c      -o main.o

echo "== link (riscv.ld @ 0x80200000) =="
"$LD" -T riscv.ld -o "$OUT" locore.o trap_asm.o sbi.o trap.o \
	hat_riscv.o timer.o main.o

echo "== image info =="
file "$OUT" || true
"$OBJDUMP" -h "$OUT" 2>/dev/null | sed -n '1,20p' || true
echo "-- entry / first instrs --"
"$OBJDUMP" -d "$OUT" 2>/dev/null | sed -n '/<_start>:/,/ret/p' | head -30 || true

echo "== boot under OpenSBI (qemu virt, default -bios, 120s timeout) =="
# -bios default => qemu's bundled OpenSBI (fw_dynamic); -kernel loads our ELF
# as the S-mode payload (OpenSBI jumps to 0x80200000 = _start).
: > "$LOG"
timeout 120 "$QEMU" -machine virt -nographic -bios default \
	-kernel "$OUT" 2>&1 | tee "$LOG" || true
echo "== done; console captured to $LOG =="
