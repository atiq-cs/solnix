# gcc-src.nix -- GCC built FROM SOURCE: the solnix stdenv compiler, and the
# source of every C++/unwind runtime library that ships.
#
# This follows the NixOS bootstrap. NixOS starts from bootstrap-tools, a binary
# seed whose only job is to compile gcc. Everything that ships links against the
# from-source gcc's runtime, so the seed never appears in a runtime closure. Here
# the seed (stage0) is the build host's IPS developer/gcc-14. It compiles cc1/
# cc1plus (build-time tools), and the NEW compiler (xgcc) then builds libgcc and
# libstdc++. Those target libraries are therefore built from this source tree and
# compiled by the new compiler, and they are what ships.
#
# --with-sysroot=<gate proto>: the new gcc's default headers, crt objects and
# link search path (gcc passes `-Y P,%R/lib/amd64:%R/usr/lib/amd64` to the
# illumos link-editor) all come from the gate proto, which is illumos-gate built
# from source (pkgs/illumos/gate.nix). Nothing compiled by this gcc sees the
# build host's /usr/include or /lib unless asked to.
#
# Outputs, the NixOS split:
#   out -- the compiler (driver, cc1, cc1plus, headers). Build-time only; it names
#          the host /usr/bin/ld and /usr/bin/gas, which are build tools.
#   lib -- libstdc++.so.6 + libgcc_s.so.1 (and their versioned files). This is
#          the only output a shipped binary may reference.
#
# Configure line follows OpenIndiana's gcc-14 (`/usr/gcc/14/bin/gcc -v` on the
# build host): illumos ld (not GNU ld), GNU as, __cxa_atexit, initfini-array.
# Not OI's --enable-clocale=dragonfly: that model is an OI patch, and upstream
# libstdc++ configure rejects it ("Unknown argument to enable/disable clocale",
# measured), so the upstream default (generic on solaris) is used. Languages cut to c,c++, multilib off (64-bit only),
# and the libraries nothing here needs (sanitizers, gomp, itm, vtv) are dropped to
# keep the build short.
{ gate                    # gate proto store path (the sysroot)
, libcSlice               # pkgs.solnix.libc: RUNPATH target for libc/libm at run time
, stage0 ? "/usr/gcc/14"  # BUILD-TIME seed compiler (IPS developer/gcc-14)
, system ? "x86_64-solaris"
}:

let
  version = "14.3.0";
  fetch = url: sha256: builtins.fetchurl { inherit url sha256; };
  gccSrc = fetch "https://ftp.gnu.org/gnu/gcc/gcc-${version}/gcc-${version}.tar.xz"
    "e0dc77297625631ac8e50fa92fffefe899a4eb702592da5c32ef04e2293aca3a";
  gmpSrc = fetch "https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz"
    "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898";
  mpfrSrc = fetch "https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.1.tar.xz"
    "277807353a6726978996945af13e52829e3abd7a9a5b7fb2793894e18f1fcbb2";
  mpcSrc = fetch "https://ftp.gnu.org/gnu/mpc/mpc-1.3.1.tar.gz"
    "ab642492f5cf882b74aa0cb730cd410a81edcdbec895183ce930e706c1c759b8";
in
derivation {
  name = "gcc-${version}";
  inherit system gate stage0 gccSrc gmpSrc mpfrSrc mpcSrc version;
  # OpenIndiana/OmniOS gcc patch 0032: libstdc++ built with -D_TS_ERRNO so it
  # reads the per-thread errno. See the patch header for the measurement.
  tsErrnoPatch = ./patches/gcc-14/0032-libstdc-must-use-thread-local-errno.patch;
  libcDir = "${libcSlice}/lib/amd64";
  libcDir32 = "${libcSlice}/lib";
  outputs = [ "out" "lib" ];
  builder = "/usr/bin/bash";
  PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";
  args = [ "-c" ''
    set -eu
    export PATH=/usr/gnu/bin:/usr/bin:/usr/sbin
    W=$(mktemp -d /var/tmp/gccsrc.XXXXXX); cd "$W"
    tar xf "$gccSrc"
    cd "gcc-$version"
    patch -p1 < "$tsErrnoPatch" >&2
    # GMP/MPFR/MPC in-tree: linked statically into cc1, so the compiler carries
    # no host math libs either.
    tar xf "$gmpSrc"; mv gmp-6.3.0 gmp
    tar xf "$mpfrSrc"; mv mpfr-4.2.1 mpfr
    tar xf "$mpcSrc"; mv mpc-1.3.1 mpc
    mkdir ../b; cd ../b
    export CC="$stage0/bin/gcc" CXX="$stage0/bin/g++" CONFIG_SHELL=/usr/bin/bash
    # The compiler binaries themselves link the seed's C++ runtime statically, so
    # `out` does not depend on /usr/gcc/14/lib at run time.
    export LDFLAGS="-static-libstdc++ -static-libgcc"
    # No -g for the compiler's own objects: with debug info cc1/cc1plus/lto1 are
    # ~420 MB each, and linking three in parallel on an 8 GB build guest failed
    # (measured: the -j6 link of all three died; a serial `gmake cc1` succeeded).
    export CFLAGS="-O2" CXXFLAGS="-O2"
    ../gcc-$version/configure \
      --prefix="$out" \
      --with-sysroot="$gate" --with-native-system-header-dir=/usr/include \
      --enable-languages=c,c++ --disable-bootstrap --enable-multilib \
      --with-gnu-as --with-as=/usr/bin/gas --without-gnu-ld --with-ld=/usr/bin/ld \
      --enable-shared --enable-__cxa_atexit --enable-initfini-array \
      --without-zstd --disable-nls \
      --disable-libsanitizer --disable-libgomp --disable-libitm --disable-libvtv \
      --with-pkgversion="solnix ${version}" >&2
    # The target-library configure scripts (libstdc++) RUN test programs linked
    # by the new xgcc, which NEED the just-built libgcc_s.so.1. The build host has
    # no libgcc_s on its default path, so without this the probe dies in ld.so.1
    # ("libgcc_s.so.1: open failed") and configure reports "cannot run C compiled
    # programs" (measured). Build-time only; unset before the closure gate.
    export LD_LIBRARY_PATH_64="$W/b/gcc" LD_LIBRARY_PATH_32="$W/b/gcc/32"
    gmake -j"$(psrinfo | wc -l)" >&2 || gmake -j2 >&2
    gmake install >&2
    unset LD_LIBRARY_PATH_64 LD_LIBRARY_PATH_32

    # lib output: the runtime libraries, and nothing else. lib/ = 32-bit,
    # lib/amd64 = 64-bit (the illumos layout, matching the gate's own libs).
    #
    # Debug info is stripped: the DWARF carries the sysroot include paths, which
    # Nix's reference scan reads as a dependency on the whole gate proto (219 MB),
    # so every C++ closure would drag the proto in (measured: 6 such strings in
    # libstdc++.so.6.0.33, 3 in libgcc_s.so.1). Same as stdenv's strip phase.
    for pair in "$out/lib/amd64:$lib/lib/amd64:$libcDir" "$out/lib:$lib/lib:$libcDir32"; do
      src=''${pair%%:*}; rest=''${pair#*:}; dst=''${rest%%:*}; lc=''${rest#*:}
      mkdir -p "$dst"
      # libatomic: configure scripts that probe GCC_ATOMIC_BUILTINS add -latomic.
      for f in "$src"/libstdc++.so* "$src"/libgcc_s.so* "$src"/libatomic.so*; do
        [ -e "$f" ] || continue
        case "$f" in *.py) continue;; esac
        cp -P "$f" "$dst/"
      done
      for f in "$dst"/*; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        chmod u+w "$f"
        /usr/bin/gstrip --strip-debug "$f"
        /usr/bin/elfedit -e "dyn:runpath $dst:$lc" "$f"
        if grep -q "$gate" "$f"; then echo "FATAL: $f still names the gate proto" >&2; exit 1; fi
      done
      [ -e "$dst/libstdc++.so.6" ] && [ -e "$dst/libgcc_s.so.1" ] || { echo "FATAL: runtime libs missing in $dst" >&2; exit 1; }
    done
    # Gate: the runtime libs resolve inside /nix/store with no LD_LIBRARY_PATH.
    unset LD_LIBRARY_PATH LD_LIBRARY_PATH_64 LD_LIBRARY_PATH_32 || true
    bad=$(for f in "$lib"/lib/libstdc++.so.6 "$lib"/lib/libgcc_s.so.1 "$lib"/lib/amd64/libstdc++.so.6 "$lib"/lib/amd64/libgcc_s.so.1; do
      /usr/bin/ldd "$f" 2>&1 | awk -v f="$f" '/not found/ || (/=>/ && $NF !~ /^\/nix\/store\//) {print f": "$0}'
    done)
    [ -z "$bad" ] || { echo "FATAL: runtime libs leave the store:" >&2; echo "$bad" >&2; exit 1; }
    # Gate: libstdc++ must read the per-thread errno (___errno), never the global
    # errno symbol. Without the 0032 patch the 64-bit lib had 86 references to
    # errno@SUNW_0.7 and std::filesystem threw "Error 0" from worker threads; OI's
    # patched libstdc++ has 1 (measured). Allow a handful for code that takes
    # errno's ADDRESS legitimately, fail on anything near the unpatched count.
    nglob=$(/usr/gnu/bin/objdump -d --no-show-raw-insn "$lib/lib/amd64/libstdc++.so.6" | grep -c 'errno@SUNW' || true)
    echo "=== libstdc++ global-errno references: $nglob ===" >&2
    [ "$nglob" -le 4 ] || { echo "FATAL: libstdc++ uses the GLOBAL errno ($nglob refs); -D_TS_ERRNO missing" >&2; exit 1; }
    echo "=== gcc-$version: lib output resolves inside /nix/store ===" >&2
  '' ];
}
