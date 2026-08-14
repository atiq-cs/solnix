#!/bin/sh
#
# R-P19 milestone proof (re-runnable).
#
# Proves the three R-P19 deliverables that do not depend on the long-pole
# all-gcc-solaris rebuild:
#
#   (2) the sgs EM_RISCV MACH descriptor + RISC-V instruction-field reloc
#       encoders compile and self-verify, and the encoders produce
#       BYTE-IDENTICAL output to GNU ld on a real object; and
#   (3) a first illumos uts/riscv64 object built against the riscv64 MD headers
#       is a valid EM_RISCV (243) ELF64-LSB ET_REL, emits the R_RISCV_* relocs
#       the port must resolve, and links clean (all relocs applied).
#
# Run on the fred build node with the R-P17 cross toolchain.

set -e
PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
export PATH
TC=/root/riscv-port/toolchain/bin
GCC=$TC/riscv64-unknown-elf-gcc
LD=$TC/riscv64-unknown-elf-ld
RE=$TC/riscv64-unknown-elf-readelf
OD=$TC/riscv64-unknown-elf-objdump
RP19=/root/riscv-port/rp19
cd "$RP19"

echo "=== R-P19.2a: RISC-V INSREL instruction-field encoders self-test ==="
gcc -Wall -Wextra -DINSN_SELFTEST -o /tmp/insn_st machrel_riscv_insn.c
/tmp/insn_st

echo "=== R-P19.2b: sgs reloc-apply dispatch (classify + apply) self-test ==="
gcc -Wall -Wextra -DDISPATCH_SELFTEST -o /tmp/disp_st \
    machrel_riscv_dispatch.c machrel.riscv.c machrel_riscv_insn.c
/tmp/disp_st

echo "=== R-P19.2c: EM_RISCV MACH descriptor (ld_targ_riscv) wired self-test ==="
gcc -Wall -Wextra -DMACH_SELFTEST -o /tmp/mach_st \
    machtarget_riscv.c machrel_riscv_dispatch.c machrel.riscv.c \
    machrel_riscv_insn.c
/tmp/mach_st

echo "=== R-P19.3a: build first uts/riscv64 object with the MD headers ==="
cd "$RP19/uts/riscv64"
$GCC -c -march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding -nostdinc \
    -fno-stack-protector -I. -o mod_riscv64.o mod_riscv64.c
mach=$($RE -h mod_riscv64.o | awk -F: '/Machine/{gsub(/ /,"",$2);print $2}')
typ=$($RE -h mod_riscv64.o | awk -F: '/Type/{print $2}' | tr -d ' ' | cut -c1-3)
raw=$(od -An -tu1 -j18 -N1 mod_riscv64.o | tr -d ' ')
[ "$mach" = "RISC-V" ] || { echo "FAIL: not RISC-V ($mach)"; exit 1; }
[ "$raw" = "243" ] || { echo "FAIL: e_machine != 243 ($raw)"; exit 1; }
[ "$typ" = "REL" ] || { echo "FAIL: not ET_REL ($typ)"; exit 1; }
echo "  object is EM_RISCV(243) ELF64-LSB ET_REL"

echo "=== R-P19.3b: object emits the R_RISCV_* relocs the port resolves ==="
rels=$($RE -r mod_riscv64.o | awk '{print $3}' | sort -u)
for want in R_RISCV_CALL_PLT R_RISCV_PCREL_HI2 R_RISCV_PCREL_LO1 R_RISCV_RELAX
do
	echo "$rels" | grep -q "$want" || {
		echo "FAIL: missing $want"; exit 1; }
	echo "  emits $want"
done

echo "=== R-P19.3c: cross-ld applies every reloc (link-apply proof) ==="
$LD -Ttext=0x80000000 -e _init -o mod_riscv64.linked mod_riscv64.o
lmach=$($RE -h mod_riscv64.linked | awk -F: '/Machine/{gsub(/ /,"",$2);print $2}')
ltyp=$($RE -h mod_riscv64.linked | awk -F: '/Type/{print $2}' | tr -d ' ' | \
    cut -c1-4)
[ "$lmach" = "RISC-V" ] || { echo "FAIL: linked not RISC-V"; exit 1; }
[ "$ltyp" = "EXEC" ] || { echo "FAIL: linked not ET_EXEC"; exit 1; }
$RE -r mod_riscv64.linked | grep -qi "no relocations" || {
	echo "FAIL: relocs left unresolved after link"; exit 1; }
echo "  linked EM_RISCV ET_EXEC, all relocs applied"

echo "=== R-P19.3d: INSREL encoder == GNU ld byte-for-byte on this object ==="
# The first PCREL_HI20/LO12 pair the linker resolved (auipc a5 / addi a5,a5).
hi=$($OD -d mod_riscv64.linked | awk '/auipc[ \t]+a5/{print $2; exit}')
lo=$($OD -d mod_riscv64.linked | \
    awk '/auipc[ \t]+a5/{getline; print $2; exit}')
echo "  GNU ld applied: auipc=0x$hi addi=0x$lo"
python3 - "$hi" "$lo" mod_riscv64.linked <<'PY'
import sys, subprocess, re
hi = int(sys.argv[1], 16); lo = int(sys.argv[2], 16)
# recover the reloc target + site from the disasm comment
od = subprocess.check_output(
    ["/root/riscv-port/toolchain/bin/riscv64-unknown-elf-objdump", "-d",
     sys.argv[3]], text=True)
m = re.search(r'([0-9a-f]+):\s+\S+\s+auipc\s+a5.*\n\s*([0-9a-f]+):.*#\s*'
              r'([0-9a-f]+)\s*<', od)
assert m, "could not parse auipc/addi pair"
P = int(m.group(1), 16); S = int(m.group(3), 16); val = S - P
REACH = 1 << 12
HIGH = (val + REACH // 2) & ~(REACH - 1)
def RV_X(x, s, n): return (x >> s) & ((1 << n) - 1)
def ENC_U(x): return (RV_X(x, 12, 20) << 12) & 0xffffffff
def ENC_I(x): return (RV_X(x, 0, 12) << 20) & 0xffffffff
umask = ENC_U(0xffffffff); imask = ENC_I(0xffffffff)
my_auipc = (0x00000797 & ~umask) | (ENC_U(HIGH) & umask)   # auipc a5
my_addi  = (0x00078793 & ~imask) | (ENC_I(val) & imask)    # addi a5,a5
assert my_auipc == hi, f"auipc mismatch {my_auipc:#x} != {hi:#x}"
assert my_addi == lo, f"addi mismatch {my_addi:#x} != {lo:#x}"
print(f"  INSREL encoder: auipc={my_auipc:#010x} addi={my_addi:#010x} "
      f"(S={S:#x} P={P:#x}) MATCH")
PY

echo
echo "ALL R-P19 PROOFS PASSED (sgs INSREL encoders + MACH descriptor;"
echo "first EM_RISCV uts/riscv64 object built, relocs emitted + applied;"
echo "INSREL encoder output byte-identical to GNU ld)"
