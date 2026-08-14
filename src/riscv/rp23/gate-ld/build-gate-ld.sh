#!/usr/bin/env bash
#
# build-gate-ld.sh -- R-P23 sub-task 3: build a MINIMAL native illumos `ld`
# driver (ldmin) that links a REAL EM_RISCV object through the sgs backend
# (ld_config_target(EM_RISCV) selection + machrel.riscv.c reloc engine), and
# prove it against GNU ld: same object, same link address, byte-identical
# relocated .text.  The illumos backend -- not GNU ld -- performs the link.
#
# The full gate `ld` (usr/src/cmd/sgs/ld + libld) is NOT on this host; this is
# the buildable step toward it, using the host's native libelf/gelf as libld's
# ELF access layer.
set -e
export PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
G=/root/riscv-port/rp23/gate-ld
SGS=/root/riscv-port/rp22/sgs
GCC=/root/riscv-port/build/gcc-sol-cfg3/gcc
XGCC="$GCC/xgcc -B$GCC"
TB=/root/riscv-port/toolchain/bin
AS=$TB/riscv64-unknown-elf-as
GNULD=$TB/riscv64-unknown-elf-ld
OBJCOPY=$TB/riscv64-unknown-elf-objcopy
OBJDUMP=$TB/riscv64-unknown-elf-objdump
LINKADDR=80200000
cd $G

echo "=== assembling the real EM_RISCV test object (riscv64-solaris toolchain) ==="
$XGCC -march=rv64gc -mabi=lp64d -c t_pcrel.s -o t_pcrel.o
[ "$($TB/riscv64-unknown-elf-readelf -h t_pcrel.o | awk -F: '/Machine/{print $2}' | tr -d ' ')" = "RISC-V" ] \
	|| { echo "FAIL: test object not EM_RISCV"; exit 1; }
echo "  relocs in the object:"; $TB/riscv64-unknown-elf-readelf -rW t_pcrel.o | grep R_RISCV | sed 's/^/    /'

echo "=== building ldmin (native, links against the sgs backend) ==="
# machrel.riscv.c + insn compiled WITHOUT -DMACHREL_SELFTEST (exports entry pts)
gcc -I$SGS -Wall -Wno-unused -Wno-comment -c $SGS/machrel.riscv.c -o machrel.riscv.o
gcc -I$SGS -Wall -Wno-unused -Wno-comment -c $SGS/machrel_riscv_insn.c -o machrel_riscv_insn.o
gcc -I$SGS -Wall -Wno-unused -Wno-comment -c $SGS/target.c -o target.o
gcc -I$SGS -Wall -Wno-unused -Wno-comment -c ldmin.c -o ldmin.o
gcc ldmin.o target.o machrel.riscv.o machrel_riscv_insn.o -lelf -o ldmin
echo "  built ldmin"

echo "=== linking through the illumos backend (ldmin) ==="
./ldmin t_pcrel.o $LINKADDR ldmin.text.bin

echo "=== linking the same object with GNU ld at the same address ==="
$GNULD -Ttext=0x$LINKADDR -e load_addr t_pcrel.o -o gnu.elf 2>/dev/null
$OBJCOPY -O binary --only-section=.text gnu.elf gnu.text.bin

echo "=== diffing the relocated .text images ==="
# ldmin writes only the .text section image (same span objcopy extracts).
if cmp -s ldmin.text.bin gnu.text.bin; then
	echo "  BYTE-IDENTICAL to GNU ld:"
	echo "    illumos backend: $(od -An -tx4 ldmin.text.bin | tr -s ' ')"
	echo "    GNU ld         : $(od -An -tx4 gnu.text.bin | tr -s ' ')"
	echo "R-P23.3 PASS: illumos sgs backend natively linked a real EM_RISCV"
	echo "             object; relocated .text == GNU ld (no GNU ld in the path)"
else
	echo "  MISMATCH:"
	echo "    ldmin: $(od -An -tx4 ldmin.text.bin)"
	echo "    gnuld: $(od -An -tx4 gnu.text.bin)"
	echo "R-P23.3 FAIL"
	exit 1
fi
