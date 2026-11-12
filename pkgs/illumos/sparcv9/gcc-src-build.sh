set -eu
# builder for sparcv9/gcc-src.nix (see its header). LP64 only: the runtime lives in lib/sparcv9 (MULTILIB_OSDIRNAMES . sparcv9).
# What differs from ../gcc-src.nix (x86), each measured in zone lixu (sv9gcc, floki /scratch/solnix/sv9gcc/progress.txt):
#  - GNU ar 2.46.1 bus-errors once ~17 input files are open at once (its link copy-relocates libc's __iob past its own .bss);
#    with `ulimit -n 64` bfd keeps <= 8 open and the same archives come out right and deterministic, so the det-ar wrapper sets it.
#    illumos ar has no D modifier (members keep their mtime/uid), so it can't be the wrapper's ar.
#  - the stage0 links get -YP,<gate lib dirs>: OI gcc-13's link_arch64 spec adds -R /usr/gcc/13/lib/sparcv9 unless -YP is given.
#  - gcc/ and libgcc agree on the Solaris CRTs only when pinned (see the export before configure).
#  - no patch(1) in the zone: 0032 goes in with git apply (outside a repo it is patch -p1 with no fuzz).
#  - the global-errno gate counts libstdc++.a members (x86 greps objdump's x86 syntax over the .so).
export PATH=/usr/gnu/bin:/usr/bin:/usr/sbin
ts() { echo "=== sv9gcc $1 $(date -u +%FT%TZ)" >&2; }
ts start
# Fixed build dir keyed on $buildKey (repro2 fix 3, as ../gcc-src.nix). Kept when the build fails (a rerun starts clean), since a
# run here takes hours.
W=/var/tmp/gccsrc-$buildKey
rm -rf "$W"; mkdir -m 700 "$W"; trap 'rc=$?; cd /; [ $rc != 0 ] || rm -rf "$W"' EXIT; cd "$W"
mkdir "$W/detbin"
cat > "$W/detbin/ar" <<'EOS'
#!/usr/bin/bash
ulimit -n 64
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
printf '#!/usr/bin/bash\nulimit -n 64\nexec /usr/gnu/bin/ranlib -D "$@"\n' > "$W/detbin/ranlib"
chmod +x "$W/detbin/ar" "$W/detbin/ranlib"; export PATH="$W/detbin:$PATH"
tar xf "$gccSrc"; cd "gcc-$version"
/usr/bin/git apply -v "$tsErrnoPatch" >&2
tar xf "$gmpSrc"; mv gmp-6.3.0 gmp
tar xf "$mpfrSrc"; mv mpfr-4.2.1 mpfr
tar xf "$mpcSrc"; mv mpc-1.3.1 mpc
mkdir ../b; cd ../b
# -m64: install.texi (sparcv9-*-solaris2*) requires a build compiler that emits 64-bit code
export CC="$stage0/bin/gcc -m64" CXX="$stage0/bin/g++ -m64" CONFIG_SHELL=/usr/bin/bash
export LDFLAGS="-static-libstdc++ -static-libgcc -YP,$gate/lib/sparcv9:$gate/usr/lib/sparcv9" CFLAGS="-O2" CXXFLAGS="-O2"
T=sparcv9-sun-solaris2.11
# "system-provided CRTs" pinned to yes for gcc/ and libgcc alike. In a native build gcc/configure tests the BUILD HOST's
# /usr/lib/crt1.o (it uses the sysroot only when host != target), and libgcc tests $sysroot/usr/lib/crt1.o. The LP64-only proto has
# crt1.o only in usr/lib/sparcv9, so on an OI host they disagreed (gcc yes, libgcc no), and every target link wanted a crtp.o that
# libgcc never built (b1 rzc309hp: libstdc++ configure "Link tests are not allowed after GCC_NO_EXECUTABLES"). illumos ships
# crt1.o (the proto has it), and OI's gcc-13 links crtp.o the same way.
export gcc_cv_solaris_crts=yes libgcc_cv_solaris_crts=yes
ts configure
../gcc-$version/configure --build=$T --host=$T --target=$T --prefix="$out" \
  --with-sysroot="$gate" --with-native-system-header-dir=/usr/include \
  --enable-languages=c,c++ --disable-bootstrap --disable-multilib --with-cpu=ultrasparc \
  --with-gnu-as --with-as=/usr/bin/gas --without-gnu-ld --with-ld="$ldBin" \
  --enable-shared --enable-__cxa_atexit --enable-initfini-array \
  --without-zstd --disable-nls \
  --disable-libsanitizer --disable-libgomp --disable-libitm --disable-libvtv \
  --with-pkgversion="solnix $version" >&2
# target-lib configure probes run xgcc-linked programs that NEED the new libgcc_s (build-time only)
export LD_LIBRARY_PATH_64="$W/b/gcc"
ts make
gmake -j2 >&2
ts install
gmake install >&2
unset LD_LIBRARY_PATH_64
ts post
# the runtime's dir as the new driver names it (lib/sparcv9 expected: t-sol2 MULTILIB_OSDIRNAMES . sparcv9, default -m64)
L=lib/$("$out/bin/gcc" -print-multi-os-directory); L=${L%/.}; echo "=== runtime dir $L ===" >&2
[ -e "$out/$L/libstdc++.so.6" ] && [ -e "$out/$L/libgcc_s.so.1" ] || { echo "FATAL: no runtime in $out/$L:" >&2; ls "$out/lib" >&2; exit 1; }
# lib output: the runtime libraries only, RUNPATH = itself + store libc, debug stripped (the DWARF names the sysroot, which
# Nix's reference scan reads as a dependency on the whole gate proto, as measured on x86)
mkdir -p "$lib/$L"
for f in "$out/$L"/libstdc++.so* "$out/$L"/libgcc_s.so* "$out/$L"/libatomic.so*; do
  case "$f" in *.py) continue;; esac; cp -RP "$f" "$lib/$L/"   # illumos cp: -P only with -R (no GNU cp in the zone)
done
for f in "$lib/$L"/*; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  chmod u+w "$f"; /usr/gnu/bin/strip --strip-debug "$f"; /usr/bin/elfedit -e "dyn:runpath $lib/$L:$libcDir" "$f"
  if grep -q "$gate" "$f"; then echo "FATAL: $f still names the gate proto" >&2; exit 1; fi
done
# the drivers NEED libkstat.so.1 (gcc's sparc -mcpu=native code), which the libc slice lacks: the gate's copy in $out/lib/sparcv9,
# already first on their RUNPATH (as aarch64; x86 uses libc-extra). It NEEDs libc only.
cp "$gate/lib/sparcv9/libkstat.so.1" "$out/$L/"; chmod u+w "$out/$L/libkstat.so.1"
# every other ELF in $out: a store RUNPATH, never the stage0 compiler's /usr/gcc/13 (elfedit adds one where the link left none)
find "$out" -type f | while read -r f; do
  [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] || continue
  /usr/bin/elfdump -d "$f" 2>/dev/null | grep -q NEEDED || continue
  chmod u+w "$f"; /usr/bin/elfedit -e "dyn:runpath $out/$L:$libcDir" "$f"
done
# every shipped archive's armap without a date; cc1/cc1plus executable_checksum = md5(name-buildKey) (../gcc-src.nix says why)
find "$out" "$lib" -name '*.a' -type f | while read -r f; do chmod u+w "$f"; "$W/detbin/ranlib" "$f"; done
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
# DT_CHECKSUM -> 0 in both outputs (repro2 fix 4)
: > "$W/zc"; /usr/bin/bash "$zeroChecksum" "$out" "$W/zc"; /usr/bin/bash "$zeroChecksum" "$lib" "$W/zc"
[ ! -s "$W/zc" ] || { cat "$W/zc" >&2; exit 1; }
unset LD_LIBRARY_PATH LD_LIBRARY_PATH_64 LD_LIBRARY_PATH_32 || true
# no /usr/gcc RUNPATH left anywhere, and every dynamic ELF in both outputs resolves inside /nix/store
bad=$(find "$out" "$lib" -type f | while read -r f; do
  [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] || continue
  /usr/bin/elfdump -d "$f" 2>/dev/null | awk -v f="$f" '($2 == "RUNPATH" || $2 == "RPATH") && $4 ~ /\/usr\/gcc/ {print f": "$2" "$4}'
  /usr/bin/elfdump -d "$f" 2>/dev/null | grep -q NEEDED || continue
  /usr/bin/ldd "$f" 2>&1 | awk -v f="$f" '/not found/ || (/=>/ && $NF !~ /^\/nix\/store\//) {print f": "$0}'
done)
[ -z "$bad" ] || { echo "FATAL: ELFs leave the store:" >&2; echo "$bad" >&2; exit 1; }
# libstdc++ must read the per-thread errno (0032's -D_TS_ERRNO). Counted per object in libstdc++.a: in the .so every errno read
# shares one GOT relocation, so a relocation count can't fail. Without -D_TS_ERRNO an object reading errno has `U errno` (measured,
# sv9gcc z6); OI's sparcv9 libstdc++.a has 0 such members and 9 with `U ___errno`. Allow a handful, as x86.
nglob=$(/usr/gnu/bin/nm -A "$out/$L/libstdc++.a" 2>/dev/null | awk '$NF == "errno" && $(NF-1) == "U"' | wc -l | tr -d ' ')
nts=$(/usr/gnu/bin/nm -A "$out/$L/libstdc++.a" 2>/dev/null | awk '$NF == "___errno" && $(NF-1) == "U"' | wc -l | tr -d ' ')
echo "=== libstdc++.a members reading the global errno: $nglob, the per-thread ___errno: $nts ===" >&2
[ "$nglob" -le 4 ] && [ "$nts" -ge 1 ] || { echo "FATAL: libstdc++ uses the GLOBAL errno ($nglob members, $nts on ___errno); -D_TS_ERRNO missing" >&2; exit 1; }
ts done
echo "=== gcc-$version (sparcv9): lib output resolves inside /nix/store ===" >&2
