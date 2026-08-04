#!/usr/bin/env bash
# aa-grow-seed-cross.sh — grow the aarch64 target-sysroot seed with the CROSS-SDK
# half (the richlowe/arm64-gate cross gcc + cross Solaris ld, both x86-host
# binaries that emit aarch64). Runs ON the x86 illumos build host, as root.
#
# INPUT:
#   - the existing aarch64 target-sysroot seed tarball (SEED_TARBALL)
#   - the built arm64-gate $CROSS prefix (CROSS, from `make setup`: sysroot ->
#     binutils-gdb -> sgs -> boot-gcc -> gcc)
#
# OUTPUT (in $OUT):
#   seed/                     grown tree (old sysroot + new usr/gcc/aarch64-14 +
#                             opt/onbld/bin/amd64/ld cross-SDK half)
#   aarch64-seed.tar.zst      re-tarred grown seed
#   aarch64-seed-manifest-cross.txt  provenance of the added CROSS slice
#   sha256 + the SRI hash for the fork FOD bump
#
# WHAT WE FOLD IN (the compiler half the seed lacked):
#   usr/gcc/aarch64-14/bin/aarch64-unknown-solaris2.11-{gcc,g++,cpp,gcc-14.3.0,
#     gcc-ar,gcc-nm,gcc-ranlib,gcov*}            (x86-host gcc driver binaries)
#   usr/gcc/aarch64-14/libexec/gcc/<triple>/14.3.0/{cc1,cc1plus,collect2,lto1,
#     lto-wrapper}                                (x86-host compiler proper)
#   usr/gcc/aarch64-14/lib/gcc/<triple>/14.3.0/{crt*.o,libgcc.a,libgcov.a,
#     include,include-fixed}                      (gcc-internal aarch64 crt+libgcc)
#   usr/gcc/aarch64-14/<triple>/{bin,lib,sys-include}  (target-side as/ld the
#     driver execs + libgcc_s/libstdc++ + gcc sys-include)
#   opt/onbld/bin/amd64/ld                        (x86-host Solaris link-editor)
#   usr/bin/aarch64-unknown-solaris2.11-{as,ld,ar,nm,...}  (cross binutils, x86)
#
# HOST-LIB NOTE (matches the x86 seed's own precedent): the x86-host compiler
# binaries NEED base illumos libs (libc/libm/libkstat from /lib/64) and the gcc
# math libs (libmpc/libmpfr/libgmp/libz/libzstd from /usr/lib/64). These are
# BUILD-TIME deps of the compiler running on the x86 illumos host — exactly as
# the x86 seed's cc1 NEEDs libzstd from the host. The OUTPUT closure (the aarch64
# binary + its runtime libc) is what must be host-free, and it is (target sysroot
# libs live in the seed). We RUNPATH-relocate the gcc driver's build-host
# /usr/gcc/14/lib/amd64 rpath so it does not hard-require that exact host path.
set -euo pipefail

CROSS="${CROSS:-/aarch64/arm64-gate/build/cross}"
SEED_TARBALL="${SEED_TARBALL:-/aarch64/aarch64-seed.tar.zst}"
OUT="${OUT:-/var/tmp/solnix-aarch64-seed-grown}"
SEED="$OUT/seed"
TRIPLE=aarch64-unknown-solaris2.11
GCCVER=14.3.0
GDIR="usr/gcc/aarch64-14"   # the grown gcc prefix root inside the seed

die()  { echo "FATAL: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ]        || die "run as root (perm/symlink preservation)"
[ -d "$CROSS" ]           || die "no CROSS prefix: $CROSS"
[ -f "$SEED_TARBALL" ]    || die "no seed tarball: $SEED_TARBALL"
[ -x "$CROSS/bin/$TRIPLE-gcc" ] || die "no cross gcc: $CROSS/bin/$TRIPLE-gcc"
[ -x "$CROSS/opt/onbld/bin/amd64/ld" ] || die "no cross Solaris ld: $CROSS/opt/onbld/bin/amd64/ld"
command -v zstd >/dev/null || die "zstd not on PATH"

echo "=== 1. unpack the existing target-sysroot seed ==="
rm -rf "$OUT"; mkdir -p "$SEED"
zstd -dc "$SEED_TARBALL" | ( cd "$OUT" && tar -xf - )
[ -f "$SEED/lib/libc.so.1" ] || die "unpacked seed has no lib/libc.so.1"
echo "  existing seed sysroot OK (lib/libc.so.1 present)"

echo "=== 2. fold in the cross gcc prefix (bin + libexec + lib/gcc + target side) ==="
mkdir -p "$SEED/$GDIR/bin" "$SEED/$GDIR/libexec" "$SEED/$GDIR/lib"

# gcc driver binaries — the ones needed to drive a C/C++ cross compile+link.
# (Drop gdb/lto-dump/objdump-heavy/run/gprof/strings/size to keep the seed lean;
#  keep as/ld/ar/nm/ranlib/objcopy/strip/readelf which the driver + wrappers use.)
DRIVER_BINS="gcc g++ cpp gcc-$GCCVER gcc-ar gcc-nm gcc-ranlib gcov gcov-dump gcov-tool
             c++ as ld ld.bfd ar nm ranlib objcopy strip readelf elfedit c++filt"
for b in $DRIVER_BINS; do
  s="$CROSS/bin/$TRIPLE-$b"
  [ -e "$s" ] && cp -p "$s" "$SEED/$GDIR/bin/$TRIPLE-$b"
done

# compiler proper (cc1/cc1plus/collect2/lto1/lto-wrapper) + gcc-internal crt/libgcc/include
cp -RP "$CROSS/libexec/gcc" "$SEED/$GDIR/libexec/gcc"
cp -RP "$CROSS/lib/gcc"     "$SEED/$GDIR/lib/gcc"

# target-side dir the driver execs (its own as/ld symlinks) + target libgcc_s/libstdc++
cp -RP "$CROSS/$TRIPLE" "$SEED/$GDIR/$TRIPLE"

# the x86-host Solaris link-editor (sgs) the gcc port links through
mkdir -p "$SEED/opt/onbld/bin/amd64"
cp -p "$CROSS/opt/onbld/bin/amd64/ld" "$SEED/opt/onbld/bin/amd64/ld"

# also expose the cross binutils (x86-host) under usr/bin with the triple prefix,
# so a wrapper (or the driver's PATH search) finds aarch64-*-as / -ld / -ar.
mkdir -p "$SEED/usr/bin"
for b in as ld ld.bfd ar nm ranlib objcopy strip readelf elfedit c++filt addr2line; do
  s="$CROSS/bin/$TRIPLE-$b"
  [ -e "$s" ] && cp -p "$s" "$SEED/usr/bin/$TRIPLE-$b"
done

echo "=== 3. strip the x86-host binaries (safe: host ELF; halves the seed) ==="
# Strip only the x86-host driver/compiler binaries and the Solaris ld. Do NOT
# touch the aarch64 target objects (crt*.o, libgcc.a, libstdc++.*): those are
# EM_AARCH64 and only the cross strip understands them; leave them intact.
for f in "$SEED/$GDIR/bin/"* "$SEED/usr/bin/$TRIPLE-"* \
         "$SEED/opt/onbld/bin/amd64/ld"; do
  [ -f "$f" ] || continue
  head -c4 "$f" 2>/dev/null | grep -q ELF || continue
  # host x86 ELF only (EM_AMD64); skip anything else
  elfdump -e "$f" 2>/dev/null | grep -q EM_AMD64 || continue
  /usr/bin/strip "$f" 2>/dev/null || true
done
for f in "$SEED/$GDIR/libexec/gcc/$TRIPLE/$GCCVER/"{cc1,cc1plus,collect2,lto1,lto-wrapper}; do
  [ -f "$f" ] || continue
  elfdump -e "$f" 2>/dev/null | grep -q EM_AMD64 && /usr/bin/strip "$f" 2>/dev/null || true
done

echo "=== 4. RUNPATH-relocate the gcc driver off the build-host /usr/gcc path ==="
# The gcc driver's RUNPATH is the build host's /usr/gcc/14/lib/amd64 (where its
# libkstat/libm come from) — those are base illumos libs also in /lib/64, so the
# default search already resolves them. Rewrite the rpath to /usr/gcc/14/lib/amd64
# is unnecessary; instead point it at the always-present /usr/lib/64:/lib/64 so
# the driver runs on any x86 illumos host regardless of gcc-14 pkg layout.
RELOC='/usr/lib/64:/lib/64'
for f in "$SEED/$GDIR/bin/$TRIPLE-gcc" "$SEED/$GDIR/bin/$TRIPLE-g++" \
         "$SEED/$GDIR/bin/$TRIPLE-gcc-$GCCVER" "$SEED/$GDIR/bin/$TRIPLE-cpp"; do
  [ -f "$f" ] || continue
  elfedit -e "dyn:runpath $RELOC" "$f" 2>/dev/null || \
    elfedit -e "dyn:value -s RUNPATH $RELOC" "$f" 2>/dev/null || \
    echo "  WARN: could not rewrite RUNPATH on $(basename "$f") (default search still resolves base libs)"
done

echo "=== 5. sanity: the grown seed's cross gcc runs + emits EM_AARCH64 ==="
SG="$SEED/$GDIR/bin/$TRIPLE-gcc"
"$SG" --version | head -1
echo 'int main(){return 0;}' | "$SG" --sysroot="$SEED" \
  -B"$SEED/$GDIR/lib/gcc/$TRIPLE/$GCCVER" \
  -x c - -o /tmp/aa-grow-check 2>&1 | head || \
  echo "  (link needs the wrapper's -B/-L; compile-only check below)"
echo 'int f(void){return 1;}' | "$SG" --sysroot="$SEED" -c -x c - -o /tmp/aa-grow-check.o
elfdump -e /tmp/aa-grow-check.o 2>/dev/null | grep -i e_machine

echo "=== 6. provenance manifest for the added CROSS slice ==="
MANI="$OUT/aarch64-seed-manifest-cross.txt"
{
  echo "# solnix aarch64 seed CROSS-SDK grow — generated $(date -u +%FT%TZ)"
  echo "# host uname: $(uname -a)"
  echo "# cross gcc: $("$SG" --version | head -1)"
  echo "# cross gcc -dumpmachine: $("$SG" -dumpmachine)"
  echo "# arm64-gate rev: $(cd /aarch64/arm64-gate/illumos-gate 2>/dev/null && git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "# added prefix root inside seed: $GDIR + opt/onbld/bin/amd64/ld + usr/bin/$TRIPLE-*"
  echo "# ---- path<TAB>sha256 ----"
  find "$SEED/$GDIR" "$SEED/opt/onbld/bin/amd64/ld" -type f 2>/dev/null | while read -r f; do
    printf '%s\t%s\n' "${f#$SEED/}" "$(digest -a sha256 "$f" 2>/dev/null || echo -)"
  done
} > "$MANI"

echo "=== 7. re-tar (zstd -19) ==="
( cd "$OUT" && tar -cf - seed | zstd -19 -T0 -o aarch64-seed.tar.zst )
SUM="$(digest -a sha256 "$OUT/aarch64-seed.tar.zst" 2>/dev/null)"
echo "aarch64-seed.tar.zst sha256: $SUM" | tee -a "$MANI"
echo "SIZE: $(ls -l "$OUT/aarch64-seed.tar.zst" | awk '{print $5}') bytes"

echo
echo "DONE."
echo "  grown seed:  $OUT/aarch64-seed.tar.zst"
echo "  sha256:      $SUM"
echo "  manifest:    $MANI"
echo "  (compute SRI: nix-hash --to-sri --type sha256 $SUM  OR  nix hash file)"
