set -eu
# builder for aarch64/gcc-src.nix (see its header). LP64 only: everything lives in lib/.
export PATH=/usr/gnu/bin:/usr/bin:/usr/sbin
W=$(mktemp -d /var/tmp/gccsrc.XXXXXX); cd "$W"
tar xf "$gccSrc"; cd "gcc-$rev"
tar xf "$gmpSrc"; mv gmp-6.3.0 gmp
tar xf "$mpfrSrc"; mv mpfr-4.2.1 mpfr
tar xf "$mpcSrc"; mv mpc-1.3.1 mpc
mkdir ../b; cd ../b
export CC="$stage0/bin/gcc" CXX="$stage0/bin/g++" CONFIG_SHELL=/usr/bin/bash M4=/usr/bin/gm4
export LDFLAGS="-static-libstdc++ -static-libgcc" CFLAGS="-O2" CXXFLAGS="-O2"
export CFLAGS_FOR_TARGET="$tflags" CXXFLAGS_FOR_TARGET="$tflags"
T=aarch64-unknown-solaris2.11
../gcc-$rev/configure --build=$T --host=$T --target=$T --prefix="$out" \
  --with-sysroot="$gate" --with-native-system-header-dir=/usr/include \
  --enable-languages=c,c++ --disable-bootstrap --disable-multilib --with-abi=lp64 \
  --with-gnu-as --with-as=/usr/bin/gas --without-gnu-ld --with-ld="$ldBin" \
  --enable-shared --enable-__cxa_atexit --enable-initfini-array --enable-c99 \
  --without-zstd --disable-nls --disable-decimal-float --disable-libquadmath \
  --disable-libsanitizer --disable-libgomp --disable-libitm --disable-libvtv \
  --with-pkgversion="solnix $version" >&2
# target-lib configure probes run xgcc-linked programs that NEED the new libgcc_s.
export LD_LIBRARY_PATH="$W/b/gcc" LD_LIBRARY_PATH_64="$W/b/gcc"
gmake -j"$(psrinfo | wc -l)" >&2
gmake install >&2
unset LD_LIBRARY_PATH LD_LIBRARY_PATH_64
# lib output: the runtime libraries only, RUNPATH = itself + store libc, debug stripped
# (DWARF names the sysroot = the whole gate proto, as measured on x86).
mkdir -p "$lib/lib"
for f in "$out"/lib/libstdc++.so* "$out"/lib/libgcc_s.so* "$out"/lib/libatomic.so*; do
  case "$f" in *.py) continue;; esac; cp -P "$f" "$lib/lib/"
done
for f in "$lib"/lib/*; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  # elfedit BEFORE gstrip: GNU strip 2.43.1 zeroes .SUNW_ldynsym sh_link on aarch64 and illumos
  # elfedit then segfaults (measured on libstdc++.so.6.0.33).
  chmod u+w "$f"; /usr/bin/elfedit -e "dyn:runpath $lib/lib:$libcDir" "$f"; gstrip --strip-debug "$f"
  if grep -q "$gate" "$f"; then echo "FATAL: $f still names the gate proto" >&2; exit 1; fi
done
[ -e "$lib/lib/libstdc++.so.6" ] && [ -e "$lib/lib/libgcc_s.so.1" ] || { echo "FATAL: runtime libs missing" >&2; exit 1; }
# every other ELF in $out: a store RUNPATH, never the stage0 compiler's /opt/gcc-14.
find "$out" -type f | while read -r f; do
  [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] || continue
  /usr/bin/elfdump -d "$f" 2>/dev/null | grep -q NEEDED || continue
  chmod u+w "$f"; /usr/bin/elfedit -e "dyn:runpath $out/lib:$libcDir" "$f"
done
bad=$(for f in "$lib"/lib/libstdc++.so.6 "$lib"/lib/libgcc_s.so.1; do
  /usr/bin/ldd "$f" 2>&1 | awk -v f="$f" '/not found/ || (/=>/ && $NF !~ /^\/nix\/store\//) {print f": "$0}'
done)
[ -z "$bad" ] || { echo "FATAL: runtime libs leave the store:" >&2; echo "$bad" >&2; exit 1; }
nglob=$(objdump -d --no-show-raw-insn "$lib/lib/libstdc++.so.6" | grep -c 'errno@SUNW' || true)
echo "=== libstdc++ global-errno references: $nglob ===" >&2
[ "$nglob" -le 4 ] || { echo "FATAL: libstdc++ uses the GLOBAL errno ($nglob refs)" >&2; exit 1; }
echo "=== gcc-$version (aarch64): lib output resolves inside /nix/store ===" >&2
