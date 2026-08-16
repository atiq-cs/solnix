#!/usr/bin/env bash
# R-P36 restore: rebuild the R-P19/21/23/28/31 dynamic chain the kernel's
# dynamic-linking regressions need: solaris libgcc.a + a minimal sysroot, a
# shared-capable binutils ld, libgcc_s.so.1, ld.so.1, and the dynamic hellos.
set -e
export PATH=/root/riscv-port/toolchain-sol/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
R=/root/riscv-port
TC=$R/toolchain/bin
SOL=$R/toolchain-sol
B=$R/build/gcc-sol-cfg3
TRIPLE=riscv64-unknown-solaris2.11
GCC=$B/gcc
XGCC="$GCC/xgcc -B$GCC"
LD=$TC/riscv64-unknown-elf-ld
READELF=$TC/riscv64-unknown-elf-readelf
CFLAGS="-march=rv64gc -mabi=lp64d -mcmodel=medany -ffreestanding -fno-stack-protector -fno-pie -O2 -Wall -Wno-unused"

echo "=== [dyn 1] point the build-tree as/collect-ld at the elf binutils ==="
sed -i "s|^ORIGINAL_AS_FOR_TARGET=\"\"|ORIGINAL_AS_FOR_TARGET=\"$TC/riscv64-unknown-elf-as\"|" "$B/gcc/as" || true
sed -i "s|^ORIGINAL_LD_FOR_TARGET=\"\"|ORIGINAL_LD_FOR_TARGET=\"$TC/riscv64-unknown-elf-ld\"|" "$B/gcc/collect-ld" || true

echo "=== [dyn 2] triple-prefixed binutils symlinks + bootstrap headers ==="
mkdir -p "$SOL/bin" "$SOL/$TRIPLE/bin"
for t in as ld ar ranlib nm objcopy objdump strip readelf; do
  ln -sf "$TC/riscv64-unknown-elf-$t" "$SOL/bin/$TRIPLE-$t"
  ln -sf "$TC/riscv64-unknown-elf-$t" "$SOL/$TRIPLE/bin/$t"
done
INC="$SOL/$TRIPLE/include"; mkdir -p "$INC/sys"
cat > "$INC/sys/types.h" <<'EOF'
#ifndef _SYS_TYPES_BOOT_H
#define _SYS_TYPES_BOOT_H
typedef unsigned long size_t; typedef long ssize_t; typedef long off_t;
#endif
EOF
cat > "$INC/sys/mman.h" <<'EOF'
#ifndef _SYS_MMAN_BOOT_H
#define _SYS_MMAN_BOOT_H
#include <sys/types.h>
#define PROT_READ 0x1
#define PROT_WRITE 0x2
#define PROT_EXEC 0x4
extern int mprotect(void *, size_t, int);
#endif
EOF
cat > "$INC/unistd.h" <<'EOF'
#ifndef _UNISTD_BOOT_H
#define _UNISTD_BOOT_H
#include <sys/types.h>
#define _SC_PAGESIZE 11
#define _SC_STACK_PROT 515
extern long sysconf(int); extern int getpagesize(void);
#endif
EOF
cat > "$INC/stdlib.h" <<'EOF'
#ifndef _STDLIB_BOOT_H
#define _STDLIB_BOOT_H
extern void abort(void);
#endif
EOF
SYS=$R/sysroot-riscv-sol; mkdir -p "$SYS/usr/include/sys" "$SYS/usr/lib/64"
cp $R/uts/sys/isa_defs.h  "$SYS/usr/include/sys/"
cp $R/uts/sys/machtypes.h "$SYS/usr/include/sys/"
cp $R/uts/sys/elf_riscv.h "$SYS/usr/include/sys/"

echo "=== [dyn 3] install the solaris libgcc.a ==="
cd "$B/$TRIPLE/libgcc"
PATH="$SOL/bin:$PATH" gmake libgcc.a >>$R/logs/libgcc.log 2>&1 || true
DEST="$SOL/lib/gcc/$TRIPLE/14.3.0"; mkdir -p "$DEST"; cp libgcc.a "$DEST/"
echo "  libgcc.a: $($TC/riscv64-unknown-elf-ar t $DEST/libgcc.a | wc -l) members"

echo "=== [dyn 4] shared-capable binutils ld (regen elf64lriscv emulation) ==="
BUS=$R/src/binutils-2.44; BUB=$R/build/binutils
if [ ! -x "$TC/riscv64-unknown-elf-ld-shared" ]; then
  grep -q GENERATE_SHLIB_SCRIPT "$BUS/ld/emulparams/elf64lriscv.sh" || {
    echo GENERATE_SHLIB_SCRIPT=yes >> "$BUS/ld/emulparams/elf64lriscv.sh"
    echo GENERATE_PIE_SCRIPT=yes   >> "$BUS/ld/emulparams/elf64lriscv.sh"
  }
  cd "$BUB/ld"
  LIBDIR=$($TC/../lib 2>/dev/null; echo $R/toolchain/lib)
  sh "$BUS/ld/genscripts.sh" "$BUS/ld" "$R/toolchain/lib" "$R/toolchain" "$R/toolchain" \
     .deps "$R/toolchain/lib" "elf64lriscv elf32lriscv elf64briscv elf32briscv" \
     "$R/toolchain/lib" no yes elf64lriscv riscv64-unknown-elf >>$R/logs/ldshared.log 2>&1
  gmake eelf64lriscv.o ld-new >>$R/logs/ldshared.log 2>&1
  cp ld-new "$TC/riscv64-unknown-elf-ld-shared"
fi
LDSH="$TC/riscv64-unknown-elf-ld-shared"
echo "  ld-shared: $($LDSH --version | head -1)"

echo "=== [dyn 5] assemble csu crt (crt1/crti/crtn) ==="
CSU=$R/rp20/csu; mkdir -p $CSU
for f in crt1 crti crtn; do
  $XGCC --sysroot=$SYS $CFLAGS -c -o $CSU/$f.o $R/csu/$f.s
done
echo "  crt built: $(ls $CSU/*.o | wc -l)"

echo "=== [dyn 6] hand-link libgcc_s.so.1 ==="
LGS=$R/rp21/libgcc_s; mkdir -p $LGS; cd $LGS
cp $R/libgcc_s/libgcc_s.ver ./libgcc_s.ver
cp "$DEST/libgcc.a" ./libgcc.a
$LDSH -shared -soname libgcc_s.so.1 -o libgcc_s.so.1 \
  --version-script libgcc_s.ver \
  --whole-archive libgcc.a --no-whole-archive \
  --allow-shlib-undefined >>$R/logs/libgcc_s.log 2>&1
$READELF -h libgcc_s.so.1 | grep -q RISC-V && echo "  libgcc_s.so.1 OK ($($READELF -h libgcc_s.so.1 | awk -F: '/Type/{print $2}'))"

echo "=== [dyn 7] the R-P21 dynamic hello (hello.dyn) ==="
HD=$R/rp21/hello; mkdir -p $HD; cd $HD
cp $R/hello/hello.c ./hello.c
$XGCC --sysroot=$SYS $CFLAGS -fno-builtin -c hello.c -o hello.o
$LDSH -e _start --dynamic-linker /usr/lib/ld.so.1 -L$LGS \
  -o hello.dyn $CSU/crt1.o $CSU/crti.o hello.o $CSU/crtn.o -lgcc_s $LGS/libgcc.a \
  --allow-shlib-undefined >>$R/logs/hello.log 2>&1 || \
$LDSH -e _start --dynamic-linker /usr/lib/ld.so.1 -L$LGS \
  -o hello.dyn $CSU/crt1.o $CSU/crti.o hello.o $CSU/crtn.o -lgcc_s $LGS/libgcc.a \
  --allow-shlib-undefined
$READELF -h hello.dyn | grep -q RISC-V && echo "  hello.dyn OK"

echo "=== [dyn 8] ld.so.1 (rp36/ldso) ==="
L=$R/rp36/ldso; cd $L
$XGCC $CFLAGS -I$L -c rtld_start.S -o rtld_start.o
$XGCC $CFLAGS -I$L -c rtld_riscv.c -o rtld_riscv.o
$LD -T ld.so.1.lds -static -e _rtld_start rtld_start.o rtld_riscv.o -o ld.so.1 2>&1 | grep -v RWX || true
$READELF -h ld.so.1 | grep -q RISC-V && echo "  ld.so.1 OK"

echo "DYNCHAIN_DONE $(date)"
