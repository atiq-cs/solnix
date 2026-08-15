#!/usr/bin/env bash
#
# build-user.sh -- build the R-P26 static riscv64-solaris userland programs:
#   forker  -- the first process: forks a child, both run + print their pid,
#              the child exits, the parent waits + reaps it, then fork+exec+wait
#              a second (different) program.  Proves fork(2)/wait(2)/exec(2).
#   execee  -- the exec(2) target: a DISTINCT program image run in place of the
#              exec child, proving exec reloaded a new program.
# Each links crt1/crti/crtn (R-P20 csu) + its own inline syscall stubs (no
# libc beyond crt), statically into an EM_RISCV ET_EXEC.  The kernel embeds
# both ELFs (.incbin) and maps their PT_LOAD segments into fresh user ASes.
set -e
export PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
U=/root/riscv-port/rp29/user
GCC=/root/riscv-port/build/gcc-sol-cfg3/gcc
XGCC="$GCC/xgcc -B$GCC"
TB=/root/riscv-port/toolchain/bin
LD=$TB/riscv64-unknown-elf-ld
READELF=$TB/riscv64-unknown-elf-readelf
CSU=/root/riscv-port/rp20/csu
CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding \
	-fno-stack-protector -fno-pie -O2 -Wall -Wno-unused"
cd $U

build_one() {
	local name=$1
	$XGCC $CFLAGS -c $name.c -o $name.o
	# static, self-contained: crt front, program body, crtn tail. No libc.
	$LD -static -e _start \
		$CSU/crt1.o $CSU/crti.o $name.o $CSU/crtn.o \
		-o $name 2>/dev/null
	local mach
	mach=$($READELF -h $name | awk -F: "/Machine/{print \$2}" | tr -d " ")
	[ "$mach" = "RISC-V" ] || { echo "FAIL: $name not EM_RISCV"; exit 1; }
	$READELF -d $name 2>&1 | grep -q "no dynamic section" \
		|| { echo "FAIL: $name not static"; exit 1; }
	echo "  OK: static EM_RISCV userland $name"
	$READELF -h $name | grep "Entry point"
}

build_one forker
build_one execee
build_one preempt
build_one fsexec
build_one dynexec
build_one dynexec2
build_one fptest

# hellodyn -- the R-P28 cross-object DYNAMIC hello: links against libgcc_s.so.1
# (calls __multf3/__fixtfsi), so it is an ET_EXEC with PT_INTERP + JUMP_SLOT
# relocs against UNDEF symbols defined in libgcc_s.  Built with the shared
# linker; NOT statically resolved (no static libgcc.a on the link line) so the
# libgcc symbols stay dynamic imports that ld.so.1 must bind at runtime.
RP=/root/riscv-port
SR=$RP/sysroot-riscv-sol
LDSH=$TB/riscv64-unknown-elf-ld-shared
LIBGCCDIR=$RP/rp21/libgcc_s
$XGCC --sysroot=$SR $CFLAGS -fno-builtin -c hellodyn.c -o hellodyn.o
$LDSH -e _start --dynamic-linker /usr/lib/ld.so.1 -L$LIBGCCDIR \
	-o hellodyn.dyn $CSU/crt1.o $CSU/crti.o hellodyn.o $CSU/crtn.o -lgcc_s \
	--allow-shlib-undefined 2>/dev/null || \
$LDSH -e _start --dynamic-linker /usr/lib/ld.so.1 -L$LIBGCCDIR \
	-o hellodyn.dyn $CSU/crt1.o $CSU/crti.o hellodyn.o $CSU/crtn.o -lgcc_s \
	--allow-shlib-undefined
$READELF -h hellodyn.dyn | grep -q "RISC-V" || { echo "FAIL: hellodyn not EM_RISCV"; exit 1; }
$READELF -rW hellodyn.dyn | grep -q "R_RISCV_JUMP_SLOT" || { echo "FAIL: hellodyn has no cross-object JUMP_SLOT"; exit 1; }
$READELF -dW hellodyn.dyn | grep -q "libgcc_s.so.1" || { echo "FAIL: hellodyn no NEEDED libgcc_s"; exit 1; }
echo "  OK: DYNAMIC cross-object hellodyn (NEEDED libgcc_s.so.1, JUMP_SLOT __multf3/__fixtfsi)"
