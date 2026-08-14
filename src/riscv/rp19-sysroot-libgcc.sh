#!/bin/sh
#
# R-P19.1 sysroot + libgcc bootstrap (re-runnable, idempotent).
#
# Turns the freshly-built riscv64-unknown-solaris2.11 all-gcc compiler into a
# usable cross toolchain that produces a riscv64-solaris libgcc.a, by supplying
# the minimum a bare Solaris target lacks:
#
#   1. an assembler + linker for the target: the psABI is identical to
#      riscv64-unknown-elf, so we point gcc's build-tree as/collect-ld wrappers
#      (whose ORIGINAL_*_FOR_TARGET were empty -- no in-tree binutils was built
#      for the solaris triple) at the R-P17 riscv64-unknown-elf binutils, and
#      publish triple-prefixed binutils names on PATH for libgcc's ar/ranlib.
#   2. a handful of stub headers under the target include dir so the Solaris
#      libgcc bits (enable-execute-stack-mprotect.c) that reference <sys/mman.h>
#      / <unistd.h> / <stdlib.h> compile.  These are BOOTSTRAP stubs only; the
#      real gate <usr/include> replaces them.
#   3. the minimal /usr/include sysroot skeleton carrying the R-P17 illumos
#      riscv64 MD headers (sys/isa_defs.h, sys/machtypes.h, sys/elf_riscv.h),
#      which is what real uts/riscv64 objects compile against.
#
# The core libgcc.a (the 138 compiler-runtime objects: soft integer/float,
# clz/ctz, muldi3, etc.) is built with `gmake libgcc.a`, which skips the
# Solaris gmon/profiling extra (needs full libc: fcntl/stdio) not required for
# a bootstrap runtime.

set -e
PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
export PATH

TC=/root/riscv-port/toolchain/bin			# R-P17 elf binutils/gcc
SOL=/root/riscv-port/toolchain-sol			# solaris-triple prefix
B=/root/riscv-port/build/gcc-sol-cfg3			# the all-gcc build tree
TRIPLE=riscv64-unknown-solaris2.11

# 1a. point the build-tree as/collect-ld wrappers at the elf binutils
sed -i "s|^ORIGINAL_AS_FOR_TARGET=\"\"|ORIGINAL_AS_FOR_TARGET=\"$TC/riscv64-unknown-elf-as\"|" "$B/gcc/as"
sed -i "s|^ORIGINAL_LD_FOR_TARGET=\"\"|ORIGINAL_LD_FOR_TARGET=\"$TC/riscv64-unknown-elf-ld\"|" "$B/gcc/collect-ld"

# 1b. triple-prefixed binutils on PATH (ar/ranlib/as/ld/...) for libgcc's make
mkdir -p "$SOL/bin" "$SOL/$TRIPLE/bin"
for t in as ld ar ranlib nm objcopy objdump strip readelf; do
	ln -sf "$TC/riscv64-unknown-elf-$t" "$SOL/bin/$TRIPLE-$t"
	ln -sf "$TC/riscv64-unknown-elf-$t" "$SOL/$TRIPLE/bin/$t"
done

# 2. bootstrap stub headers the Solaris libgcc bits need
INC="$SOL/$TRIPLE/include"
mkdir -p "$INC/sys"
cat > "$INC/sys/types.h" <<'EOF'
#ifndef _SYS_TYPES_BOOT_H
#define _SYS_TYPES_BOOT_H
typedef unsigned long size_t;
typedef long ssize_t;
typedef long off_t;
#endif
EOF
cat > "$INC/sys/mman.h" <<'EOF'
#ifndef _SYS_MMAN_BOOT_H
#define _SYS_MMAN_BOOT_H
#include <sys/types.h>
#define PROT_READ  0x1
#define PROT_WRITE 0x2
#define PROT_EXEC  0x4
extern int mprotect(void *, size_t, int);
#endif
EOF
cat > "$INC/unistd.h" <<'EOF'
#ifndef _UNISTD_BOOT_H
#define _UNISTD_BOOT_H
#include <sys/types.h>
#define _SC_PAGESIZE   11
#define _SC_STACK_PROT 515
extern long sysconf(int);
extern int getpagesize(void);
#endif
EOF
cat > "$INC/stdlib.h" <<'EOF'
#ifndef _STDLIB_BOOT_H
#define _STDLIB_BOOT_H
extern void abort(void);
#endif
EOF

# 3. minimal /usr/include sysroot with the illumos riscv64 MD headers
SYS=/root/riscv-port/sysroot-riscv-sol
mkdir -p "$SYS/usr/include/sys" "$SYS/usr/lib/64"
cp /root/riscv-port/portsrc/sys/isa_defs.h  "$SYS/usr/include/sys/"
cp /root/riscv-port/portsrc/sys/machtypes.h "$SYS/usr/include/sys/"
cp /root/riscv-port/portsrc/sys/elf_riscv.h "$SYS/usr/include/sys/"

# build the core libgcc.a
cd "$B/$TRIPLE/libgcc"
PATH="$SOL/bin:$PATH" gmake libgcc.a

# install it under the toolchain-sol prefix
DEST="$SOL/lib/gcc/$TRIPLE/14.3.0"
mkdir -p "$DEST"
cp libgcc.a "$DEST/"
echo "installed: $DEST/libgcc.a ($(/root/riscv-port/toolchain/bin/riscv64-unknown-elf-ar t "$DEST/libgcc.a" | wc -l | tr -d ' ') members)"
