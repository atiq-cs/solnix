#!/usr/bin/bash
# ghc-build.sh -- builder for ghc-9.10.3.nix (read that file for the why). Store-only PATH, fixed drv-keyed build dir.
set -eu
export PATH="$tools/bin:$gccWrapper/bin:$binutils/bin:$python3/bin:$autotools:$world/usr/bin:$world/usr/sbin:$world/bin:$world/sbin"
/usr/bin/bash "$pathGate"; . "$illumosBin"
# FIXED build dir: GHC's .hi files and debug RTS archives record the source dir (measured on the by-hand build: 273 files name it),
# so it must be the same on every host and run (gate-checks.py B8 DRV_KEYED). $buildKey: see mk-src-pkg.nix.
W=/var/tmp/ghc-$buildKey; rm -rf "$W"; mkdir -m 700 "$W"; trap 'cd /; rm -rf "$W"' EXIT; cd "$W"
BASH=$(command -v bash); export HOME=$W/home CONFIG_SHELL=$BASH SHELL=$BASH LANG=C.UTF-8 LC_ALL=C.UTF-8 SOURCE_DATE_EPOCH=315532800
mkdir -p home
LDP=$(gcc -print-prog-name=ld)   # the gcc's illumos ld (a store path)
L="$libffi/lib/amd64 $gmp/lib/amd64 $libiconv/lib/amd64 $ncurses/lib/amd64"
R=$(echo $L | tr ' ' ':')
J=${NIX_BUILD_CORES:-16}; [ "$J" -gt 0 ] || J=16

# 1. the seed: its own bindist configure, into $W/boot; package db from pkgsrc's /opt/local to the store libs, plus -liconv on base
#    (its iconv.o calls GNU libiconv_open/locale_charset; pkgsrc's wrappers added -liconv). Links get the store RUNPATH.
mkdir seed; xz -dc "$seed" | tar xf - -C seed
cd seed/ghc-9.8.2-boot-x86_64-unknown-solaris2
sed -i '/^GhcRTSWays/d' config.mk.in   # pkgsrc bootstrap.mk: the bindist's RTS ways line is bogus (vanilla-only kit)
CC=gcc CXX=g++ LD=$LDP "$BASH" ./configure --prefix="$W/boot" > "$W/seed.log" 2>&1 || { tail -30 "$W/seed.log" >&2; exit 1; }
gmake install >> "$W/seed.log" 2>&1 || { tail -30 "$W/seed.log" >&2; exit 1; }
cd "$W"; D=$W/boot/lib/ghc-9.8.2/lib/package.conf.d; S=$W/boot/lib/ghc-9.8.2/lib/settings
for c in "$D"/*.conf; do
  sed -i -e "s|/opt/local/lib|$L|g" -e "s|/opt/local/include|$libffi/include $gmp/include $libiconv/include $ncurses/include|g" "$c"
done
sed -i 's/^\(library-dirs:\)/extra-libraries: iconv\n\1/' "$D"/base-*.conf
sed -i "s|(\"C compiler link flags\", \"-m64\")|(\"C compiler link flags\", \"-m64 -Wl,-R,$R\")|" "$S"
! grep -rqF /opt/local "$D"/*.conf || { echo "FATAL: seed package db still names /opt/local" >&2; exit 1; }
grep -qF -- "-Wl,-R,$libffi" "$S" || { echo "FATAL: seed settings edit did not apply" >&2; exit 1; }
"$W/boot/bin/ghc-pkg" recache
"$W/boot/bin/ghc" --version >&2

# 2. source + pkgsrc's patches (each file says why)
tar xf "$src"; cd ghc-9.10.3
for p in "$patches"/ghc-9.10.3-*.patch; do patch -p0 -s < "$p"; done

# 3. hadrian, bootstrapped offline: the plan's hackage sources (FODs) laid out as bootstrap.py's -s tarball expects;
#    FILESDIR: pkgsrc's per-package patches (hadrian-shake: no -threaded exe; hadrian-clock: capi clock_gettime)
mkdir "$W/hs"; cp hadrian/bootstrap/plan-bootstrap-9_8_2.json "$W/hs/plan-bootstrap.json"
echo "$hackage" | while read -r pv t c; do cp "$t" "$W/hs/$pv.tar.gz"; cp "$c" "$W/hs/${pv%-*}.cabal"; done
(cd "$W/hs" && tar czf "$W/hsrc.tar.gz" .)
(cd hadrian/bootstrap && FILESDIR=$patches python3 bootstrap.py -w "$W/boot/bin/ghc" -s "$W/hsrc.tar.gz" -j "$J" > "$W/hadrian.log" 2>&1) \
  || { tail -40 "$W/hadrian.log" >&2; exit 1; }

# 4. configure (nixpkgs' flags; pkgsrc: no @file for ar, ALEX/HAPPY/HSCOLOUR unset so a stray one on PATH is not used;
#    dtrace off: the build host's dtrace is not a store tool; -D_TS_ERRNO: per-thread errno in every C object, as mk-src-pkg's
#    wrappers (ts-errno-gate.sh says why): without it process's cbits referenced the global errno (measured, r1). The installed
#    settings keep it, so user cbits get it too.)
conf() {
  fp_cv_prog_ar_supports_atfile=no ac_cv_path_ALEX= ac_cv_path_HAPPY= ac_cv_path_HSCOLOUR= \
  CONF_GCC_LINKER_OPTS_STAGE1="-Wl,-R,$R" CONF_GCC_LINKER_OPTS_STAGE2="-Wl,-R,$R" \
  CONF_CC_OPTS_STAGE1=-D_TS_ERRNO CONF_CC_OPTS_STAGE2=-D_TS_ERRNO \
  "$BASH" ./configure "$@" CC=gcc CXX=g++ LD=$LDP AR=$binutils/bin/gar RANLIB=$binutils/bin/granlib MergeObjsCmd=$LDP \
    --with-system-libffi --with-ffi-includes=$libffi/include --with-ffi-libraries=$libffi/lib/amd64 \
    --with-gmp-includes=$gmp/include --with-gmp-libraries=$gmp/lib/amd64 \
    --with-iconv-includes=$libiconv/include --with-iconv-libraries=$libiconv/lib/amd64 \
    --with-curses-includes=$ncurses/include --with-curses-libraries=$ncurses/lib/amd64
}
conf --prefix="$out" --disable-dtrace GHC="$W/boot/bin/ghc" > "$W/conf.log" 2>&1 || { tail -40 "$W/conf.log" >&2; exit 1; }

# 5. build: nixpkgs' hadrianFlags for 9.10. TAR_OPTIONS: hadrian makes share/doc/.../libraries.html.tar.xz with `tar -c` of a
#    directory, so in readdir order (on ZFS different in every fresh build dir), with build mtimes and the build user (measured,
#    ghc1 --check: same members, different order and owner). Name order and fixed metadata make it reproducible.
TAR_OPTIONS="--sort=name --mtime=@$SOURCE_DATE_EPOCH --owner=0 --group=0 --numeric-owner" \
hadrian/bootstrap/_build/bin/hadrian -j"$J" --flavour=release+split_sections --bignum=gmp --docs=no-sphinx --hash-unit-ids \
  binary-dist-dir > "$W/build.log" 2>&1 || { grep -v '^| Run' "$W/build.log" | tail -60 >&2; exit 1; }

# 6. install through the bindist (nixpkgs: "We need to configure the bindist *again* before installing")
cd _build/bindist/ghc-9.10.3-x86_64-unknown-solaris2
conf --prefix="$out" > "$W/inst.log" 2>&1 || { tail -40 "$W/inst.log" >&2; exit 1; }
gmake install >> "$W/inst.log" 2>&1 || { tail -40 "$W/inst.log" >&2; exit 1; }
cd "$W"
# the settings name the compiler by bare name (gcc/g++); NixOS bakes the store cc (ghc-settings-edit), so ghc works without a
# compiler on PATH. Same here.
ST=$out/lib/ghc-9.10.3/lib/settings
sed -i -e "s|(\"C compiler command\", \"gcc\")|(\"C compiler command\", \"$gccWrapper/bin/gcc\")|" \
       -e "s|(\"C++ compiler command\", \"g++\")|(\"C++ compiler command\", \"$gccWrapper/bin/g++\")|" \
       -e "s|(\"CPP command\", \"gcc\")|(\"CPP command\", \"$gccWrapper/bin/gcc\")|" \
       -e "s|(\"Haskell CPP command\", \"gcc\")|(\"Haskell CPP command\", \"$gccWrapper/bin/gcc\")|" \
       -e "s|(\"C-- CPP command\", \"gcc\")|(\"C-- CPP command\", \"$gccWrapper/bin/gcc\")|" "$ST"
grep -qF "\"C compiler command\", \"$gccWrapper/bin/gcc\"" "$ST" || { echo "FATAL: settings edit did not apply" >&2; exit 1; }
grep -q '"C compiler flags", "[^"]*-D_TS_ERRNO' "$ST" || { echo "FATAL: settings lack -D_TS_ERRNO" >&2; exit 1; }
# package.cache is a binary db regenerated from the .conf files; keep it (ghc reads it), but drop the lock (pkgsrc does too)
rm -f "$out/lib/ghc-9.10.3/lib/package.conf.d/package.cache.lock"

# the debug-way RTS (libHSrts*_debug*, built -g) keeps DWARF naming the unwrapped gcc and the gate proto (its sysroot), which
# made both RUNTIME references (measured: 6-9 files of r2's out). strip --strip-debug those files (mk-src-pkg's strip phase;
# -D: deterministic ar headers), then fail if anything still names them.
GCCU=$(sed -n 's|^exec \(/nix/store/[^ /]*\)/bin/gcc .*|\1|p' "$gccWrapper/bin/gcc"); SYSR=$(gcc -print-sysroot)
case "$GCCU:$SYSR" in /nix/store/*:/nix/store/*) ;; *) echo "FATAL: gcc '$GCCU' or sysroot '$SYSR' not found" >&2; exit 1;; esac
grep -rlF -e "$GCCU" -e "$SYSR" "$out" | while read -r f; do
  case "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" in 7f454c46|213c6172) chmod u+w "$f"; gstrip --strip-debug -D "$f";; esac
done
# ELF/ar files only: package.conf.d/system-cxx-std-lib-1.0.conf (and package.cache) name the gcc's libstdc++ dirs on purpose
grep -rlF -e "$GCCU" -e "$SYSR" "$out" | while read -r f; do
  case "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" in 7f454c46|213c6172) echo "$f";; esac
done > "$W/gccref"
[ ! -s "$W/gccref" ] || { echo "FATAL: $out still names the gcc or the gate proto:" >&2; head -5 "$W/gccref" >&2; exit 1; }
# 7. checks: DT_CHECKSUM, then the gates (no global errno, every RUNPATH in the store or $ORIGIN, ldd resolves in the store,
#    no #! or symlink to the host), then compile + run (hello, C FFI + threaded RTS, a dynamic link)
: > "$W/zc"; /usr/bin/bash "$zeroChecksum" "$out" "$W/zc"; [ ! -s "$W/zc" ] || { cat "$W/zc" >&2; exit 1; }
/usr/bin/bash "$outHostRefs" "$out"
: > "$W/fail"
/usr/bin/bash "$tsErrnoGate" "$out" 2>> "$W/fail" || echo "ts-errno gate failed" >> "$W/fail"
find "$out" -type f | while read -r f; do
  [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] || continue
  for x in "$W/boot" /opt/local; do grep -qF "$x" "$f" && echo "$f names $x" >> "$W/fail"; done
  elfdump -d "$f" 2>/dev/null | grep -q NEEDED || continue
  for e in $(elfdump -d "$f" | awk '$2=="RUNPATH"||$2=="RPATH"{print $4}' | tr ':' ' '); do
    case "$e" in /nix/store/*|'$ORIGIN'*) ;; *) echo "$f RUNPATH $e" >> "$W/fail";; esac
  done
  (unset LD_LIBRARY_PATH LD_LIBRARY_PATH_64; ldd "$f") 2>&1 | awk -v f="$f" '/not found/ || (/=>/ && $NF !~ /^\/nix\/store\//) {print f": "$0}' >> "$W/fail"
done
if [ -s "$W/fail" ]; then echo "FATAL: closure gate failed:" >&2; head -40 "$W/fail" >&2; exit 1; fi
mkdir "$W/t"; cd "$W/t"
G="env -i PATH=$world/usr/bin HOME=$W/t $out/bin/ghc"   # no compiler on PATH: the settings must name it
"$out/bin/ghc" --version | grep -q 'version 9.10.3$' || { echo "FATAL: ghc --version" >&2; exit 1; }
printf 'main :: IO ()\nmain = putStrLn "hello-ghc"\n' > hello.hs
$G -O -o hello hello.hs > /dev/null; [ "$(./hello)" = hello-ghc ] || { echo "FATAL: hello" >&2; exit 1; }
printf '#include <math.h>\ndouble cube_plus(double x, double y) { return x*x*x + cbrt(y); }\n' > cbits.c
cat > ffi.hs <<'H'
import Foreign.C.Types
import Control.Concurrent
foreign import ccall "cube_plus" c_cube_plus :: CDouble -> CDouble -> CDouble
main :: IO ()
main = do
  mv <- newEmptyMVar
  mapM_ (\i -> forkIO (putMVar mv (sum [1..i*1000 :: Integer]))) [1..8]
  rs <- mapM (const (takeMVar mv)) [1..8 :: Int]
  print (c_cube_plus 3 27, sum rs)
H
$G -O -threaded -o ffi ffi.hs cbits.c > /dev/null; [ "$(./ffi +RTS -N4)" = "(30.0,102018000)" ] || { echo "FATAL: ffi" >&2; exit 1; }
printf 'main :: IO ()\nmain = print (2 ^ (100 :: Int) :: Integer)\n' > dyn.hs
$G -dynamic -o dyn dyn.hs > /dev/null; [ "$(./dyn)" = 1267650600228229401496703205376 ] || { echo "FATAL: dynamic" >&2; exit 1; }
[ "$($G -e '1 + 2 * 3')" = 7 ] || { echo "FATAL: ghc -e (the interpreter)" >&2; exit 1; }
/usr/bin/bash "$storeGate" "$W/t" "$tsErrnoGate"
echo "=== ghc-9.10.3: check passed ===" >&2
