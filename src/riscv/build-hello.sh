#!/usr/bin/env bash
# build-hello.sh — assemble+link the bare-metal riscv64 hello with a riscv64
# cross toolchain, then boot it in qemu-system-riscv64 -machine virt.
#
# Usage:
#   TC=riscv64-unknown-elf ./build-hello.sh        # toolchain prefix (default)
#   QEMU=qemu-system-riscv64 ./build-hello.sh
#
# SUCCESS = qemu prints the hello line and powers off (SiFive test finisher).
set -euo pipefail
cd "$(dirname "$0")"

TC="${TC:-riscv64-unknown-elf}"
AS="${AS:-${TC}-as}"
LD="${LD:-${TC}-ld}"
OBJCOPY="${OBJCOPY:-${TC}-objcopy}"
QEMU="${QEMU:-qemu-system-riscv64}"
OUT="${OUT:-hello.elf}"

echo "== assemble =="
"$AS" -march=rv64imac_zicsr -mabi=lp64 -o hello.o hello.S
echo "== link =="
"$LD" -T hello.ld -o "$OUT" hello.o
echo "== info =="
file "$OUT" || true
"${TC}-objdump" -d "$OUT" 2>/dev/null | head -30 || true

echo "== boot in qemu (10s timeout) =="
# -bios none: no OpenSBI; harts jump straight to our ELF entry at 0x80000000.
timeout 10 "$QEMU" -machine virt -nographic -bios none -kernel "$OUT" \
	|| true
echo "== done =="
