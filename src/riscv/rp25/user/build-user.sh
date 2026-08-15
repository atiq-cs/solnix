#!/usr/bin/env bash
#
# build-user.sh -- build the R-P25 static riscv64-solaris userland hello: the
# process the kernel execs.  crt1/crti/crtn (R-P20 csu) + libc_syscall.o
# (R-P22 minimal libc: write(2)/exit(2) via ecall) + hello.o, statically
# linked into an EM_RISCV ET_EXEC.  The kernel embeds this ELF (.incbin) and
# maps its PT_LOAD segments into a fresh user address space.
set -e
export PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
U=/root/riscv-port/rp25/user
GCC=/root/riscv-port/build/gcc-sol-cfg3/gcc
XGCC="$GCC/xgcc -B$GCC"
TB=/root/riscv-port/toolchain/bin
LD=$TB/riscv64-unknown-elf-ld
READELF=$TB/riscv64-unknown-elf-readelf
CSU=/root/riscv-port/rp20/csu
LIBC=/root/riscv-port/rp22/libc
CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding \
	-fno-stack-protector -fno-pie -O2 -Wall -Wno-unused"
cd $U
$XGCC $CFLAGS -c hello.c -o hello.o
# link the static userland ELF (crt front, libc syscall stubs, crtn tail)
$LD -static -e _start \
	$CSU/crt1.o $CSU/crti.o hello.o $CSU/crtn.o $LIBC/libc.a \
	-o hello_user 2>/dev/null
MACH=$($READELF -h hello_user | awk -F: "/Machine/{print \$2}" | tr -d " ")
[ "$MACH" = "RISC-V" ] || { echo "FAIL: not EM_RISCV"; exit 1; }
$READELF -d hello_user 2>&1 | grep -q "no dynamic section" \
	|| { echo "FAIL: not static"; exit 1; }
echo "  OK: static EM_RISCV userland hello (hello_user)"
$READELF -lW hello_user | grep -E "LOAD|Entry"
$READELF -h hello_user | grep "Entry point"
