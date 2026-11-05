# rust-src-build.sh -- builder for rust-src.nix (read that file for the why).
set -eu
export PATH="$tools/bin:$world/usr/bin:$world/usr/sbin:$world/bin:$world/sbin"   # store tools, then the illumos base from the world store path (no /usr/bin|sbin|gnu)
# python3 on PATH (nixpkgs rustc.nix: python3 in nativeBuildInputs): LLVM's cmake runs find_package(Python3), which otherwise falls back
# to its system prefixes: the build host's /usr/bin/python3 on OI, and on solnix (no /usr/bin/python3) "Could NOT find Python3" (dixi, wave6x).
export PATH="$python3/bin:$PATH"
/usr/bin/bash "$pathGate"; . "$illumosBin"
# FIXED build dir, not $NIX_BUILD_TOP (/tmp on OI, /var/tmp/big on dixi): ld names each link output by its
# build path (measured in rust-1.99.0, repro2). $buildKey: see mk-src-pkg.nix.
W=/var/tmp/rust-$buildKey; rm -rf "$W"; mkdir -m 700 "$W"; trap 'cd /; rm -rf "$W"' EXIT; cd "$W"
got=$(digest -a sha256 "$src")
[ "$got" = "$srcSha256" ] || { echo "FATAL: sha256 want $srcSha256 got $got" >&2; exit 1; }
# cc/c++ wrappers: the from-source gcc, the store RUNPATH baked in at link time
# (post-link elfedit is capped by .dynstr padding), -g0 so no DWARF names a path.
RP=$libc/lib/amd64:$world/lib/amd64:$gccLib/lib/amd64:$openssl/lib/amd64:$zlib/lib/amd64
mkdir -p w home
for t in gcc:cc gcc:gcc g++:c++ g++:g++; do
  printf '#!/usr/bin/bash\nexec %s/bin/%s -m64 -D_TS_ERRNO -Wl,-R,%s "$@" -g0\n' \
    "$gcc" "${t%%:*}" "$RP" > "w/${t#*:}"
  chmod +x "w/${t#*:}"
done
export PATH="$W/w:$PATH" HOME="$W/home" CARGO_HOME="$W/home/.cargo"
S0=$stage0
if [ -n "$seedStage0" ]; then
  # Seed hazard (bootstrap doc, blocker 2): drop the seed's rustc-src/src, and
  # point its /usr/gcc/14 RUNPATH at the store gcc.lib.
  S0=$W/s0; mkdir s0; cp -RP "$stage0/bin" "$stage0/lib" s0/; find s0 ! -type l -exec chmod u+w {} +
  find s0/lib/rustlib/rustc-src s0/lib/rustlib/src -depth -delete 2>/dev/null || true
  for f in s0/bin/* s0/lib/*.so*; do
    [ -L "$f" ] && continue
    [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] || continue
    elfedit -e "dyn:runpath $W/s0/lib:$gccLib/lib/amd64" "$f"
  done
fi
if [ -n "$binStage0" ]; then
  # upstream's stage0 dist tarballs (fixed-output; nixpkgs' rustc-bootstrap), unpacked into $W/s0 (build-only, never shipped). Their
  # ELFs carry only RPATH $ORIGIN/../lib and .dynstr has no room for a store path (elfedit, measured), so every system lib they NEED
  # gets a link in $W/s0/xlib to the same store lib the cc wrapper's RUNPATH resolves (libssp: gcc's), and bin/{rustc,cargo,rustdoc}
  # are wrappers that put xlib on LD_LIBRARY_PATH_64: never the build host's /lib/64.
  S0=$W/s0; mkdir -p s0/xlib t0
  for t in $stage0Tars; do tar xJf "$t" -C t0; done
  for c in t0/*/; do for comp in $(cat "$c/components"); do cp -RP "$c$comp/." s0/; done; done
  for f in s0/bin/* s0/lib/*.so*; do
    [ -L "$f" ] && continue; [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] || continue
    for n in $(elfdump -d "$f" | awk '$2=="NEEDED"{print $4}'); do
      { [ -e "s0/lib/$n" ] || [ -e "s0/xlib/$n" ]; } && continue
      p=; for d in "$libc/lib/amd64" "$world/lib/amd64" "$world/usr/lib/amd64" "$gccLib/lib/amd64" "$gcc/lib/amd64"; do [ -e "$d/$n" ] && { p=$d/$n; break; }; done
      [ -n "$p" ] || { echo "FATAL: stage0 $f NEEDs $n, in no store lib dir" >&2; exit 1; }
      ln -s "$p" "s0/xlib/$n"
    done
  done
  for b in rustc cargo rustdoc; do mv "s0/bin/$b" "s0/bin/.$b-wrapped"
    printf '#!/usr/bin/bash\nLD_LIBRARY_PATH_64=%s exec %s "$@"\n' "$W/s0/xlib" "$W/s0/bin/.$b-wrapped" > "s0/bin/$b"; chmod +x "s0/bin/$b"
  done
  # the check: every lib the stage0 compiler loads is its own s0/lib, or an s0/xlib link whose target is a store path
  LD_LIBRARY_PATH_64=$W/s0/xlib ldd s0/bin/.rustc-wrapped s0/lib/librustc_driver-*.so | awk '/not found/ {print; b=1} /=>/ {print $NF}' | sort -u |
    while read -r l; do case "$l" in */s0/bin/../lib/*|"$W"/s0/lib/*) ;; "$W"/s0/xlib/*) case "$(readlink "$l")" in /nix/store/*) ;; *) echo "$l";; esac;; /nix/store/*) ;; *) echo "$l";; esac; done > s0/bad
  [ ! -s s0/bad ] || { cat s0/bad >&2; echo "FATAL: stage0 loads a lib from outside the store" >&2; exit 1; }
fi
"$S0/bin/rustc" --version >&2
tar xf "$src"; cd "rustc-$version-src"
if [ -n "$seedStage0" ]; then
  # blocker 1: the 1.97 cargo re-resolves the locks; regenerate them offline
  # against the vendor dir so --frozen passes.
  for m in Cargo.toml library/Cargo.toml; do
    PATH="$S0/bin:$PATH" RUSTC_BOOTSTRAP=1 "$S0/bin/cargo" generate-lockfile --offline --manifest-path "$m" >&2
  done
fi
sed -e "s|@S0@|$S0|g" -e "s|@out@|$out|g" -e "s|@W@|$W|g" -e "s|@world@|$world|g" > bootstrap.toml <<'EOF'
profile = "dist"
change-id = "ignore"
[build]
build = "x86_64-unknown-illumos"
host = ["x86_64-unknown-illumos"]
target = ["x86_64-unknown-illumos"]
rustc = "@S0@/bin/rustc"
cargo = "@S0@/bin/cargo"
rustdoc = "@S0@/bin/rustdoc"
docs = false
extended = true
tools = ["cargo"]
submodules = false
verbose = 1
local-rebuild = false
[install]
prefix = "@out@"
sysconfdir = "etc"
[llvm]
download-ci-llvm = false
optimize = true
ninja = false
[rust]
channel = "stable"
download-rustc = false
codegen-units = 16
compress-debuginfo = "off"
[target.x86_64-unknown-illumos]
cc = "@W@/w/cc"
cxx = "@W@/w/c++"
linker = "@W@/w/cc"
ar = "@world@/usr/bin/ar"
EOF
export CC=$W/w/cc CXX=$W/w/c++ CC_x86_64_unknown_illumos=$W/w/cc \
  CXX_x86_64_unknown_illumos=$W/w/c++ AR_x86_64_unknown_illumos=$world/usr/bin/ar \
  OPENSSL_DIR=$openssl OPENSSL_LIB_DIR=$openssl/lib/amd64 OPENSSL_INCLUDE_DIR=$openssl/include \
  OPENSSL_NO_VENDOR=1 PKG_CONFIG_PATH= \
  PKG_CONFIG_LIBDIR=$openssl/lib/amd64/pkgconfig:$zlib/lib/amd64/pkgconfig
"$python3/bin/python3" x.py install rustc cargo std -j "${NIX_BUILD_CORES:-8}" >&2
# the installer's log names the build dir 54x, and uninstall.sh makes no sense in a store path (nixpkgs rustc.nix).
rm -f "$out/lib/rustlib/install.log" "$out/lib/rustlib/uninstall.sh"
cd "$W"
# self-check: the new rustc compiles and links a program that runs.
unset LD_LIBRARY_PATH LD_LIBRARY_PATH_64 LD_LIBRARY_PATH_32 || true
echo 'fn main(){ let v: Vec<u32> = (1..4).collect(); println!("hello {:?}", v); }' > h.rs
"$out/bin/rustc" -O h.rs -o h; [ "$(./h)" = "hello [1, 2, 3]" ]
"$out/bin/cargo" --version >&2
# THE GATE (mk-src-pkg.nix's): no global errno; no ELF names the gate proto or
# the compiler; every RUNPATH entry is a store path or $ORIGIN; ldd resolves
# every NEEDED inside /nix/store.
: > fail
/usr/bin/bash "$tsErrnoGate" "$out" 2>> fail || echo "ts-errno gate failed" >> fail
find "$out" -type f > files
# strip debug (stdenv's strip phase): DWARF from gcc's own .a files names the
# compiler's store path, which the reference scan would turn into a runtime dep.
while read -r f; do
  [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] || continue
  chmod u+w "$f"; "$tools/bin/gstrip" --strip-debug "$f"
done < files
while read -r f; do
  for x in "$gate" "$gcc/"; do grep -q "$x" "$f" && echo "$f names $x" >> fail; done
  [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] || continue
  elfdump -d "$f" 2>/dev/null | grep -q NEEDED || continue
  for e in $(elfdump -d "$f" | awk '$2=="RUNPATH"||$2=="RPATH"{print $4}' | tr ':' ' '); do
    case "$e" in /nix/store/*|'$ORIGIN'*) ;; *) echo "$f RUNPATH $e" >> fail;; esac
  done
  ldd "$f" 2>&1 | awk -v f="$f" '/not found/ || (/=>/ && $NF !~ /^\/nix\/store\//) {print f": "$0}' >> fail
done < files
/usr/bin/bash "$zeroChecksum" "$out" fail   # DT_CHECKSUM -> 0 (zero-checksum.sh says why)
if [ -s fail ]; then echo "FATAL: closure gate failed:" >&2; head -40 fail >&2; exit 1; fi
echo "=== rust-$version: every ELF resolves inside /nix/store ===" >&2
