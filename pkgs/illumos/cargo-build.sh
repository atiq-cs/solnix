#!/usr/bin/bash
# cargo-build.sh -- builder for cargo.nix cargoPkg: offline cargo build on rust199 + the
# from-source gcc (graphics/cosmic-build.sh, minus the COSMIC fixups), then the mk-src-pkg
# closure gate (no global errno, no gate/gcc path in an ELF, ldd resolves inside /nix/store).
set -eu
export PATH=/usr/gnu/bin:/usr/bin:/usr/sbin
W=$NIX_BUILD_TOP; cd "$W"
RP=""; PCD=""; CI=""
for d in $libDirs; do
  [ -d "$d/lib/amd64" ] && RP="$RP:$d/lib/amd64"
  [ -d "$d/include" ] && CI="$CI -I$d/include"
  for s in lib/amd64/pkgconfig share/pkgconfig; do [ -d "$d/$s" ] && PCD="$PCD:$d/$s"; done
done
RP="${RP#:}:$gccLibDir/amd64"
LD=""; for d in $(echo "$RP" | tr ':' ' '); do LD="$LD -L$d"; done
mkdir -p w home
printf '#!/usr/bin/bash\nexec %s/bin/gcc -m64 -D_TS_ERRNO %s %s -Wl,-R,%s "$@" -g0\n' "$gcc" "$CI" "$LD" "$RP" > w/cc
printf '#!/usr/bin/bash\nexec %s/bin/g++ -m64 -D_TS_ERRNO %s %s -Wl,-R,%s "$@" -g0\n' "$gcc" "$CI" "$LD" "$RP" > w/c++
chmod +x w/cc w/c++
export PATH="$W/w:$rust/bin:$PATH" HOME="$W/home" CARGO_HOME="$W/home/.cargo"
export CC=$W/w/cc CXX=$W/w/c++ CC_x86_64_unknown_illumos=$W/w/cc CXX_x86_64_unknown_illumos=$W/w/c++
export CARGO_TARGET_X86_64_UNKNOWN_ILLUMOS_LINKER=$W/w/cc
export PKG_CONFIG_PATH="${PCD#:}" PKG_CONFIG_LIBDIR="${PCD#:}"
# unpack into its own dir: $W also holds w/ and home/, so `ls -d */ | head -1` there can pick
# home/ (ripgrep/sd: "vendor FOD is for another Cargo.lock", measured).
mkdir -p "$W/src"; cd "$W/src"; tar xf "$src"; cd "$(ls -d */ | head -1)"
# into its own dir: some crates commit a vendor/ of their own (atuin: bash-preexec), and
# `cp -r $vendor vendor` would then nest the FOD inside it (measured).
V=.nix-cargo-vendor; cp -r "$vendor" $V; chmod -R u+w $V
cmp -s Cargo.lock $V/.Cargo.lock || { echo "FATAL: vendor FOD is for another Cargo.lock" >&2; exit 1; }
mkdir -p .cargo; sed 's|directory = "vendor"|directory = "'"$PWD/$V"'"|' $V/.cargo-config.toml > .cargo/config.toml
grep -q "$V" .cargo/config.toml || { echo "FATAL: cargo vendor config" >&2; exit 1; }
J=${NIX_BUILD_CORES:-0}; [ "$J" -gt 0 ] 2>/dev/null || J=16   # cores=0 (nix: all) -> cargo rejects -j 0
eval "$env"
# vfix <crate> <file> <python-literal-old> <python-literal-new>: edit a vendored crate, FAIL if the
# anchor is gone, re-stamp its .cargo-checksum.json (cosmic-comp-vendor-fixup.sh's edit()).
vfix() {
  python3 - "$V/$1/$2" "$3" "$4" <<'PY'
import sys, ast
p, o, n = sys.argv[1], ast.literal_eval(sys.argv[2]), ast.literal_eval(sys.argv[3])
s = open(p).read()
if o not in s: sys.exit("FATAL: anchor not found in %s: %r" % (p, o[:80]))
open(p, "w").write(s.replace(o, n))
PY
  new=$(sha256sum "$V/$1/$2" | cut -d' ' -f1)
  sed -i "s|\"$2\":\"[0-9a-f]\{64\}\"|\"$2\":\"$new\"|" "$V/$1/.cargo-checksum.json"
}
eval "$prep"
cargo build --release --offline --locked ${pkg:+-p "$pkg"} ${noDefault:+--no-default-features} \
  ${features:+--features "$features"} -j "$J"
mkdir -p "$out/bin"
for b in $bins; do cp "target/release/$b" "$out/bin/"; done
eval "$man"
cd "$W"
: > fail
bash "$tsErrnoGate" "$out" 2>> fail || echo "ts-errno gate failed" >> fail
find "$out" -type f > files
while read -r f; do
  [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] || continue
  chmod u+w "$f"; /usr/bin/gstrip --strip-debug "$f"
  for x in "$gate" "$gcc/"; do grep -q "$x" "$f" && echo "$f names $x" >> fail; done
  /usr/bin/elfdump -d "$f" 2>/dev/null | grep -q NEEDED || continue
  for e in $(/usr/bin/elfdump -d "$f" | awk '$2=="RUNPATH"||$2=="RPATH"{print $4}' | tr ':' ' '); do
    case "$e" in /nix/store/*|'$ORIGIN'*) ;; *) echo "$f RUNPATH $e" >> fail;; esac
  done
  (unset LD_LIBRARY_PATH; /usr/bin/ldd "$f") 2>&1 | awk -v f="$f" '/not found/ || (/=>/ && $NF !~ /^\/nix\/store\//) {print f": "$0}' >> fail
done < files
if [ -s fail ]; then echo "FATAL: closure gate failed:" >&2; head -40 fail >&2; exit 1; fi
echo "=== $name: every ELF resolves inside /nix/store ===" >&2
eval "$check"
echo "=== $name: check passed ===" >&2
