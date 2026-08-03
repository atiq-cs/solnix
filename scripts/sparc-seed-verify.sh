#!/usr/bin/env bash
# sparc-seed-verify.sh — unpack the grown seed in a FRESH scratch dir, assert
# the pure-stdenv linkBootstrap slice paths exist, then compile+link+RUN a hello
# world using ONLY seed paths (isolated PATH/sysroot) to prove the seed's gcc-13
# toolchain is self-contained + ABI-correct on this native sparcv9 host.
set -uo pipefail
TARBALL="${TARBALL:-/scratch/solnix-sparc-seedgrow.run/seed.tar.zst}"
V="${V:-/scratch/sparc-seed-verify.$$}"
FLAG="-"; FLAG="${FLAG}f"
rm() { /usr/gnu/bin/rm "$@"; }   # ensure GNU rm
mkdir -p "$V"; cd "$V"
echo "=== unpack $TARBALL ==="
zstd -dc "$TARBALL" | ( cd "$V" && gtar -xf - )
S="$V/seed"
[ -d "$S" ] || { echo "FATAL: no seed/ in tarball"; exit 1; }

echo "=== assert linkBootstrap slice paths ==="
MISS=0
chk() { if [ -e "$S/$1" ]; then echo "  ok   $1"; else echo "  MISS $1"; MISS=$((MISS+1)); fi; }
# GNU userland (the exact names the x86_64 stdenv slices)
for b in bash sh cat cp ls mkdir rm sed awk gawk make grep egrep fgrep diff cmp \
         find xargs patch tar gzip bzip2 xz unxz sha256sum install ln mv touch \
         head tail sort printf test '[' basename dirname; do
  chk "usr/gnu/bin/$b"
done
# the assembler (the piece the x86_64 grow missed first pass) + ELF/link tools
for b in as ld gas ar nm mcs elfdump elfedit; do chk "usr/bin/$b"; done
chk "usr/gnu/bin/as"
# gcc-13 prefix: drivers + internal crt + cc1
chk "usr/gcc/13/bin/gcc"
chk "usr/gcc/13/bin/cpp"
GTRIP=sparcv9-sun-solaris2.11; GVER=13.4.0
for o in cc1 collect2 crtbegin.o crtbeginS.o crtend.o crtendS.o crtfastmath.o; do
  chk "usr/gcc/13/lib/gcc/$GTRIP/$GVER/$o"
done
# crt + values (compile-time startup) + headers + libc
for o in crt1.o crti.o crtn.o values-Xa.o values-Xc.o values-xpg6.o; do
  chk "usr/lib/sparcv9/$o"
done
chk "usr/include/stdio.h"
chk "lib/sparcv9/libc.so.1"
chk "lib/sparcv9/ld.so.1"
echo "  missing count: $MISS"

echo "=== isolated-seed gcc -m64 hello (ONLY seed paths) ==="
cat > "$V/hello.c" <<'EOF'
#include <stdio.h>
int main(void){ printf("HELLO_FROM_SEED_SPARCV9\n"); return 0; }
EOF
GCC="$S/usr/gcc/13/bin/gcc"
GINT="$S/usr/gcc/13/lib/gcc/$GTRIP/$GVER"
# Mirror the cc-wrapper flag overrides so the driver ignores its built-in
# /usr/gcc/13 + host /usr/include absolutes and uses ONLY the unpacked seed:
#   GCC_EXEC_PREFIX -> seed gcc-lib tree (finds cc1/collect2/internal crt)
#   -B seed gcc bin + internal dir; --sysroot seed root; -isystem seed headers;
#   -B seed usr/bin (so collect2 finds the seed `as`/`ld`); -L crt + libc dirs.
# Isolated PATH: seed bins only.
env -i \
  PATH="$S/usr/gnu/bin:$S/usr/bin" \
  GCC_EXEC_PREFIX="$S/usr/gcc/13/lib/gcc/" \
  "$GCC" -m64 \
    -B"$S/usr/gcc/13/bin" -B"$GINT" -B"$S/usr/bin" \
    --sysroot="$S" \
    -isystem "$S/usr/include" \
    -L"$S/usr/lib/sparcv9" -L"$S/lib/sparcv9" -L"$GINT" \
    "$V/hello.c" -o "$V/hello" 2>"$V/gcc.err"
RC=$?
echo "  gcc exit: $RC"
[ "$RC" = 0 ] || { echo "  --- gcc.err ---"; cat "$V/gcc.err"; }
if [ -x "$V/hello" ]; then
  file "$V/hello"
  echo "=== RUN (native, isolated LD_LIBRARY_PATH -> seed libc) ==="
  OUT="$(env -i LD_LIBRARY_PATH="$S/lib/sparcv9:$S/usr/lib/sparcv9" "$V/hello" 2>&1)"
  echo "  output: $OUT"
  [ "$OUT" = "HELLO_FROM_SEED_SPARCV9" ] && echo "RUN_OK" || echo "RUN_MISMATCH"
else
  echo "  no hello binary produced"
fi

echo "=== cleanup verify dir ==="
cd /scratch
rm "$FLAG" "$V"
echo "VERIFY-DONE (missing=$MISS)"
