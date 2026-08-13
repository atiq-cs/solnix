#!/bin/bash
# R-P18 reloc-handling proof: compile C on the riscv64 cross gcc, show the
# R_RISCV_* it emits, and prove each is (1) in-bounds in the 58-entry
# krtld/sgs doreloc table, (2) named by conv_reloc_RISCV_type(), (3) classified
# by the sgs EM_RISCV machrel table. Re-runnable.
set -e
export PATH=/root/riscv-port/toolchain/bin:$PATH
RP18=/root/riscv-port/rp18
W=/tmp/rp18proof
mkdir -p "$W"; cd "$W"

cat > t.c <<'EOF'
extern int g(int);
static int s(int x){ return x+1; }
int f(int x){ return g(s(x)) + x; }
int arr[64];
int use(int i){ return arr[i&63]; }
EOF
riscv64-unknown-elf-gcc -O2 -march=rv64gc -mabi=lp64d -c t.c -o t.o
echo "== gcc-emitted R_RISCV_* =="
riscv64-unknown-elf-objdump -dr t.o | grep -oE 'R_RISCV_[A-Z0-9_]+' | sort -u

cp "$RP18/elf_riscv.h" .
grep -E '#define[[:space:]]+R_RISCV_' elf_riscv.h > nums.h
cat > defs.h <<'EOF'
#include <stdint.h>
typedef uint64_t Xword; typedef uint32_t Word; typedef uint16_t Half; typedef unsigned char uchar_t;
typedef struct { Xword re_mask; Word re_flags; uchar_t re_fsize, re_bshift, re_sigbits; } Rel_entry;
#define FLG_RE_NOTREL 0x1
#define FLG_RE_NOTSUP 0x2
#define FLG_RE_PCREL  0x4
EOF
cat > reloc.h <<'EOF'
#include <stdint.h>
typedef uint32_t Word;
#include "nums.h"
EOF
nawk '/^const Rel_entry.reloc_table/{p=1} p{print; if($0 ~ /^};/){exit}}' "$RP18/doreloc.c" > table.inc

echo; echo "== (1) doreloc 58-entry table bounds =="
gcc -I. verify.c -o verify && ./verify
echo; echo "== (2) conv_reloc_RISCV_type() naming =="
cp "$RP18/kobj_convrelstr.c" cr.c
gcc -I. verify_names.c cr.c -o verify_names && ./verify_names
echo; echo "== (3) sgs EM_RISCV machrel classification =="
gcc -I"$RP18" -I. verify_sgs.c "$RP18/machrel.riscv.c" -o verify_sgs && ./verify_sgs
echo; echo "ALL R-P18 RELOC PROOFS PASSED"
