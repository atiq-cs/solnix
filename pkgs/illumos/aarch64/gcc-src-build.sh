set -eu
# builder for aarch64/gcc-src.nix (see its header). LP64 only: everything lives in lib/.
export PATH=/usr/gnu/bin:/usr/bin:/usr/sbin
# Fixed build dir keyed on $buildKey (repro2 fix 3, as ../gcc-src.nix): the compiler names it, and --check builds at a scratch out.
W=/var/tmp/gccsrc-$buildKey
rm -rf "$W"; mkdir -m 700 "$W"; trap 'cd /; rm -rf "$W"' EXIT; cd "$W"
# Deterministic archives (NixOS binutils --enable-deterministic-archives; wave3 gcc-detar, as ../gcc-src.nix): GNU ar/ranlib
# stamp the armap and members with the build time, and cc1's executable_checksum is an md5 over those archives.
mkdir "$W/detbin"
cat > "$W/detbin/ar" <<'EOS'
#!/usr/bin/bash
a=(); k=0
while [ $# -gt 0 ]; do
  case "$1" in
    --plugin|--target|--output) a+=("$1" "$2"); shift 2; continue;;
    --*|-V|-h) a+=("$1");;
    *) if [ $k = 0 ]; then k=1; case "$1" in *[rqs]*) a+=("$1"D);; *) a+=("$1");; esac; else a+=("$1"); fi;;
  esac; shift
done
exec /usr/gnu/bin/ar "${a[@]}"
EOS
printf '#!/usr/bin/bash\nexec /usr/gnu/bin/ranlib -D "$@"\n' > "$W/detbin/ranlib"
chmod +x "$W/detbin/ar" "$W/detbin/ranlib"; export PATH="$W/detbin:$PATH"
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
# the drivers (bin/gcc, cpp, ...) NEED libkstat.so.1, which the libc slice lacks: a copy in $out/lib, already first on their RUNPATH
# (x86 uses libc-extra for this; without it ldd took the host /lib/libkstat, publish gate dixa4 2026-10-31). It NEEDs libc only.
cp "$gate/lib/libkstat.so.1" "$out/lib/"; chmod u+w "$out/lib/libkstat.so.1"
# every other ELF in $out: a store RUNPATH, never the stage0 compiler's /opt/gcc-14.
find "$out" -type f | while read -r f; do
  [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] || continue
  /usr/bin/elfdump -d "$f" 2>/dev/null | grep -q NEEDED || continue
  chmod u+w "$f"; /usr/bin/elfedit -e "dyn:runpath $out/lib:$libcDir" "$f"
done
# every shipped archive's armap without a date; cc1/cc1plus executable_checksum = md5(name-buildKey) (../gcc-src.nix says why)
find "$out" "$lib" -name '*.a' -type f | while read -r f; do chmod u+w "$f"; /usr/gnu/bin/ranlib -D "$f"; done
for f in "$out"/libexec/gcc/*/*/cc1 "$out"/libexec/gcc/*/*/cc1plus; do
  [ -f "$f" ] || continue
  sym=$(/usr/bin/nm -x "$f" | awk -F'|' '{gsub(/ /, "", $NF)} $NF == "executable_checksum" {print $2, $3, $7}')
  set -- $sym; [ "$(($2))" = 16 ] || { echo "FATAL: $f executable_checksum: [$sym]" >&2; exit 1; }
  read -r sn sa so < <(/usr/bin/elfdump -c "$f" | awk -v i="$(($3))" '$1 == "Section" {x = ($2 == "Header[" i "]:"); n = $4} x && /sh_addr:/ {a = $2} x && /sh_offset:/ {print n, a, $2; exit}')
  [ "$sn" = .rodata ] || { echo "FATAL: $f executable_checksum in [$sn], expected .rodata" >&2; exit 1; }
  h=$(printf '%s' "gcc-$version-$buildKey" | /usr/bin/digest -a md5)
  e=""; i=0; while [ $i -lt 32 ]; do e="$e$(printf '\\%03o' "0x${h:$i:2}")"; i=$((i + 2)); done
  chmod u+w "$f"; printf "$e" | dd of="$f" bs=1 seek=$(($1 - sa + so)) conv=notrunc 2>/dev/null
  [ "$(dd if="$f" bs=1 skip=$(($1 - sa + so)) count=16 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "$h" ] || { echo "FATAL: $f checksum write" >&2; exit 1; }
done
# DT_CHECKSUM -> 0 in both outputs (repro2 fix 4; ./zero-checksum.sh, the aarch64 dd copy)
: > "$W/zc"; /usr/bin/bash "$zeroChecksum" "$out" "$W/zc"; /usr/bin/bash "$zeroChecksum" "$lib" "$W/zc"
[ ! -s "$W/zc" ] || { cat "$W/zc" >&2; exit 1; }
bad=$(for f in "$lib"/lib/libstdc++.so.6 "$lib"/lib/libgcc_s.so.1; do
  /usr/bin/ldd "$f" 2>&1 | awk -v f="$f" '/not found/ || (/=>/ && $NF !~ /^\/nix\/store\//) {print f": "$0}'
done)
[ -z "$bad" ] || { echo "FATAL: runtime libs leave the store:" >&2; echo "$bad" >&2; exit 1; }
nglob=$(objdump -d --no-show-raw-insn "$lib/lib/libstdc++.so.6" | grep -c 'errno@SUNW' || true)
echo "=== libstdc++ global-errno references: $nglob ===" >&2
[ "$nglob" -le 4 ] || { echo "FATAL: libstdc++ uses the GLOBAL errno ($nglob refs)" >&2; exit 1; }
echo "=== gcc-$version (aarch64): lib output resolves inside /nix/store ===" >&2
