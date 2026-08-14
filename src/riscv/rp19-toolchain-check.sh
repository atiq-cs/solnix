#!/bin/sh
#
# R-P19.1 toolchain proof (re-runnable): the riscv64-unknown-solaris2.11 cross
# compiler is built (all-gcc-solaris), a riscv64-solaris libgcc.a exists, and
# the solaris-triple gcc compiles an illumos uts object to EM_RISCV ET_REL.
set -e
PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
export PATH
B=/root/riscv-port/build/gcc-sol-cfg3
SOLGCC="$B/./gcc/xgcc -B$B/./gcc/"
RE=/root/riscv-port/toolchain/bin/riscv64-unknown-elf-readelf
AR=/root/riscv-port/toolchain/bin/riscv64-unknown-elf-ar
LIBGCC=/root/riscv-port/toolchain-sol/lib/gcc/riscv64-unknown-solaris2.11/14.3.0/libgcc.a

echo "=== R-P19.1a: cross gcc dumpmachine == riscv64-unknown-solaris2.11 ==="
dm=$($SOLGCC -dumpmachine)
[ "$dm" = "riscv64-unknown-solaris2.11" ] || { echo "FAIL: $dm"; exit 1; }
echo "  $dm (GCC $($SOLGCC -dumpversion))"

echo "=== R-P19.1b: solaris gcc compiles a uts object to EM_RISCV ET_REL ==="
cd /root/riscv-port/rp19/uts/riscv64
$SOLGCC -c -march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding -nostdinc \
    -fno-stack-protector -I. -o /tmp/sol_uts.o mod_riscv64.c
m=$($RE -h /tmp/sol_uts.o | awk -F: "/Machine/{gsub(/ /,\"\",\$2);print \$2}")
r=$(od -An -tu1 -j18 -N1 /tmp/sol_uts.o | tr -d " ")
[ "$m" = "RISC-V" ] && [ "$r" = "243" ] || { echo "FAIL: $m/$r"; exit 1; }
echo "  EM_RISCV(243) object from riscv64-unknown-solaris2.11 gcc"

echo "=== R-P19.1c: riscv64-solaris libgcc.a exists + members are EM_RISCV ==="
[ -f "$LIBGCC" ] || { echo "FAIL: no libgcc.a"; exit 1; }
n=$($AR t "$LIBGCC" | wc -l | tr -d " ")
cd /tmp; $AR x "$LIBGCC" muldi3.o
mm=$($RE -h /tmp/muldi3.o | awk -F: "/Machine/{gsub(/ /,\"\",\$2);print \$2}")
[ "$mm" = "RISC-V" ] || { echo "FAIL: libgcc member not RISC-V"; exit 1; }
echo "  libgcc.a: $n EM_RISCV members ($LIBGCC)"

echo
echo "ALL R-P19.1 TOOLCHAIN PROOFS PASSED (riscv64-unknown-solaris2.11 gcc +"
echo "riscv64-solaris libgcc.a; solaris gcc emits EM_RISCV illumos objects)"
