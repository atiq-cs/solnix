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
# a package with sub-libraries gets a DIRECTORY of confs named N-<id> (no .conf: recache would skip them); nixpkgs'
# generic-builder renames each to <id>.conf, as here
if [ -d "$W/pkg.conf" ]; then confs=$(ls -d "$W"/pkg.conf/*); elif [ -f "$W/pkg.conf" ]; then confs=$W/pkg.conf; else confs=; fi
for c in $confs; do
  id=$(sed -n 's/^id: *//p' "$c"); [ -n "$id" ] || { echo "FATAL: no id: in $c" >&2; exit 1; }; cp "$c" "$DB/$id.conf"
done
[ -z "$(ls "$DB")" ] || ghc-pkg --package-db="$DB" recache
rmdir "$DB" 2>/dev/null || :   # an executable-only package registers nothing
# gates: DT_CHECKSUM, host refs, then the closure gate (store-only RUNPATH, ldd in the store, no global errno; the ghc
# build dir and the build-time db may not leak)
: > "$W/zc"; /usr/bin/bash "$zeroChecksum" "$out" "$W/zc"; [ ! -s "$W/zc" ] || { cat "$W/zc" >&2; exit 1; }
/usr/bin/bash "$outHostRefs" "$out"
! grep -rqF "$W/db" "$out" || { echo "FATAL: $out names the build db" >&2; exit 1; }
# the closure gate (store-gate.sh's, but $ORIGIN allowed, as ghc-build.sh and publish-gate S1): ldd must resolve in the store
: > "$W/fail"; /usr/bin/bash "$tsErrnoGate" "$out" 2>> "$W/fail" || echo "ts-errno gate failed" >> "$W/fail"
find "$out" -type f | while read -r f; do
  [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] || continue
  elfdump -d "$f" 2>/dev/null | grep -q NEEDED || continue
  for e in $(elfdump -d "$f" | awk '$2=="RUNPATH"||$2=="RPATH"{print $4}' | tr ':' ' '); do
    case "$e" in /nix/store/*|'$ORIGIN'*) ;; *) echo "$f RUNPATH $e" >> "$W/fail";; esac
  done
  (unset LD_LIBRARY_PATH LD_LIBRARY_PATH_64; ldd "$f") 2>&1 | awk -v f="$f" '/not found/ || (/=>/ && $NF !~ /^\/nix\/store\//) {print f": "$0}' >> "$W/fail"
done
if [ -s "$W/fail" ]; then echo "FATAL: closure gate failed:" >&2; head -40 "$W/fail" >&2; exit 1; fi
cd "$W"; eval "$check"
echo "=== $name: check passed ===" >&2
