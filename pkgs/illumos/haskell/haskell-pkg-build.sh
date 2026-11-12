#!/usr/bin/bash
# haskell-pkg-build.sh -- builder for haskell-pkg.nix (nixpkgs generic-builder.nix's phases, reduced): unpack, Setup configure
# against ghc's global db + the hsDeps' dbs, build, copy, register into $out's package.conf.d, closure gate, then $check.
set -eu
export PATH="${toolPath:+$toolPath:}$tools/bin:$ghc/bin:$gccWrapper/bin:$binutils/bin:$world/usr/bin:$world/usr/sbin:$world/bin:$world/sbin"
/usr/bin/bash "$pathGate"; . "$illumosBin"
# FIXED build dir: .hi files and Paths_* modules record it (as ghc-build.sh); drv-keyed, so the same on every host
W=/var/tmp/ghc-$buildKey; rm -rf "$W"; mkdir -m 700 "$W"; trap 'cd /; rm -rf "$W"' EXIT; cd "$W"
export HOME=$W/home LANG=C.UTF-8 LC_ALL=C.UTF-8 SOURCE_DATE_EPOCH=315532800; mkdir home
J=${NIX_BUILD_CORES:-16}; [ "$J" -gt 0 ] || J=16
GV=$(ghc --numeric-version); LIBDIR=$out/lib/ghc-$GV/lib; DB=$LIBDIR/package.conf.d
# the build db: every hsDep's conf files, transitively (each out lists its own in nix-support/hs-deps, as nixpkgs propagates)
mkdir db; all=""
for d in $hsDeps; do all="$all $d $(cat "$d/nix-support/hs-deps" 2>/dev/null || :)"; done
all=$(echo $all | tr ' ' '\n' | sort -u | tr '\n' ' ')
for d in $all; do cp "$d"/lib/ghc-$GV/lib/package.conf.d/*.conf db/; done
ghc-pkg --package-db="$W/db" recache
tar xzf "$src"; cd "$pname-$version"
[ -z "$cabalRev" ] || cp "$cabalRev" "$pname.cabal"
[ -f Setup.hs ] || [ -f Setup.lhs ] || printf 'import Distribution.Simple\nmain :: IO ()\nmain = defaultMain\n' > Setup.hs
ghc -package-env=- --make -threaded -O0 -o Setup Setup.*hs > "$W/setup.log" 2>&1 || { cat "$W/setup.log" >&2; exit 1; }
# shortcut: stripping off (Cabal runs bare `strip`; illumos strip is SVR4 and GNU strip on illumos ELF is untested here), upgrade
# by mapping it to split-debug-od.sh as the other builders do.
./Setup configure --verbose --prefix="$out" --libdir="$LIBDIR" --libsubdir='$abi/$libname' --datadir="$out/share" \
  --package-db="$W/db" --with-gcc="$gccWrapper/bin/gcc" --with-ld="$(gcc -print-prog-name=ld)" \
  --enable-shared --enable-library-vanilla --disable-library-profiling --disable-profiling --enable-split-sections \
  --disable-library-stripping --disable-executable-stripping --disable-tests --disable-benchmarks \
  --ghc-option=-j$J $configureFlags > "$W/conf.log" 2>&1 || { tail -40 "$W/conf.log" >&2; exit 1; }
./Setup build -j$J > "$W/build.log" 2>&1 || { tail -60 "$W/build.log" >&2; exit 1; }
./Setup copy > "$W/copy.log" 2>&1 || { tail -20 "$W/copy.log" >&2; exit 1; }
mkdir -p "$DB" "$out/nix-support"; echo "$all" > "$out/nix-support/hs-deps"
./Setup register --gen-pkg-config="$W/pkg.conf" > "$W/reg.log" 2>&1 || { tail -20 "$W/reg.log" >&2; exit 1; }
if [ -d "$W/pkg.conf" ]; then cp "$W"/pkg.conf/* "$DB/"; elif [ -f "$W/pkg.conf" ]; then
  id=$(sed -n 's/^id: *//p' "$W/pkg.conf"); cp "$W/pkg.conf" "$DB/$id.conf"; fi
[ -z "$(ls "$DB")" ] || ghc-pkg --package-db="$DB" recache
rmdir "$DB" 2>/dev/null || :   # an executable-only package registers nothing
# gates: DT_CHECKSUM, host refs, then the closure gate (store-only RUNPATH, ldd in the store, no global errno; the ghc
# build dir and the build-time db may not leak)
: > "$W/zc"; /usr/bin/bash "$zeroChecksum" "$out" "$W/zc"; [ ! -s "$W/zc" ] || { cat "$W/zc" >&2; exit 1; }
/usr/bin/bash "$outHostRefs" "$out"
! grep -rqF "$W/db" "$out" || { echo "FATAL: $out names the build db" >&2; exit 1; }
if find "$out" -type f | while read -r f; do [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] && elfdump -d "$f" 2>/dev/null | grep -q NEEDED && echo y; done | grep -q y; then
  /usr/bin/bash "$storeGate" "$out" "$tsErrnoGate"; fi
cd "$W"; eval "$check"
echo "=== $name: check passed ===" >&2
