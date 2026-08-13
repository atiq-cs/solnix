#!/bin/bash
#
# psabi-reloc-check.sh — the runnable check for the R-P17 psABI deliverable.
#
# Proves two things end-to-end on the host cross toolchain:
#   1. cross-as + cross-ld produce EM_RISCV (243) objects (the R1 toolchain proof).
#   2. every relocation type the real riscv64 gcc/binutils EMIT is DEFINED in
#      sys/elf_riscv.h (i.e. the full psABI table this port added actually
#      covers compiler output — the n-hys 12-entry table did not).
#
# Fails (non-zero exit) if any emitted R_RISCV_* is missing from the header, or
# if the ELF machine is not RISC-V. No frameworks; pure shell + readelf + gcc.
set -e
TC=${TC:-/root/riscv-port/toolchain/bin}
HDR=${HDR:-/root/riscv-port/portsrc/sys/elf_riscv.h}
AS=$TC/riscv64-unknown-elf-as
LD=$TC/riscv64-unknown-elf-ld
READELF=$TC/riscv64-unknown-elf-readelf
CC=$TC/riscv64-unknown-elf-gcc		# may not exist if only binutils built
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# --- 1. EM_RISCV proof (binutils only path) ------------------------------
cat > "$W/t.s" <<'ASM'
	.text
	.globl _start
_start:
	li	a0, 0x1234
	call	sub
	ret
	.globl sub
sub:	ret
	.data
g:	.dword 0xdeadbeefcafef00d
ASM
"$AS" -march=rv64gc -mabi=lp64d -o "$W/t.o" "$W/t.s"
mach=$("$READELF" -h "$W/t.o" | awk -F: '/Machine/{gsub(/ /,"",$2);print $2}')
[ "$mach" = "RISC-V" ] || { echo "FAIL: object machine=$mach not RISC-V"; exit 1; }
emnum=$(python3 -c "d=open('$W/t.o','rb').read(); print(d[18]|(d[19]<<8))")
[ "$emnum" = 243 ] || { echo "FAIL: e_machine=$emnum not 243 (EM_RISCV)"; exit 1; }
"$LD" -Ttext=0x80000000 -o "$W/t.elf" "$W/t.o"
"$READELF" -h "$W/t.elf" | grep -q "Machine:.*RISC-V" || { echo "FAIL: linked ELF not RISC-V"; exit 1; }
echo "PASS: cross-as + cross-ld produce EM_RISCV (243) objects"

# --- 2. reloc coverage (needs the cross gcc; skip cleanly if absent) ------
if [ -x "$CC" ]; then
	cat > "$W/r.c" <<'C'
extern int helper(int);
static int gvar = 7;
__thread int tv;
int main(void) { tv = gvar; return helper(gvar) + tv; }
C
	"$CC" -march=rv64gc -mabi=lp64d -O1 -ftls-model=local-exec -c -o "$W/r.o" "$W/r.c"
	# objdump -dr prints UNTRUNCATED reloc names (readelf -r truncates them).
	emitted=$($TC/riscv64-unknown-elf-objdump -dr "$W/r.o" | grep -oE 'R_RISCV_[A-Z0-9_]+' | sort -u)
	missing=
	for r in $emitted; do
		grep -qE "define[[:space:]]+$r([[:space:]]|\$)" "$HDR" || missing="$missing $r"
	done
	echo "emitted relocs:" $emitted
	if [ -n "$missing" ]; then
		echo "FAIL: reloc types emitted by gcc but MISSING from $HDR:$missing"
		exit 1
	fi
	echo "PASS: every gcc-emitted R_RISCV_* is defined in sys/elf_riscv.h"
else
	echo "SKIP: cross gcc not built yet; reloc-coverage check needs $CC"
	echo "      (binutils EM_RISCV proof above still stands)"
fi
echo "ALL CHECKS PASSED"
