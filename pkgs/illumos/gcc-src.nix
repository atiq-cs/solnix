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
, ld                      # the store link-editor slice (default.nix ld): collect2 runs $ld/usr/bin/ld
, libcSlice               # pkgs.solnix.libc: RUNPATH target for libc/libm at run time
, libcExtra               # base-src's illumos-libc-extra: libkstat.so.1, which the drivers NEED
, stage0 ? "/usr/gcc/14"  # BUILD-TIME seed compiler (IPS developer/gcc-14)
, system ? "x86_64-solaris"
}:

let
  version = "14.3.0";
  fetch = url: sha256: import <nix/fetchurl.nix> { inherit url sha256; };
  gccSrc = fetch "https://mirrors.kernel.org/gnu/gcc/gcc-${version}/gcc-${version}.tar.xz"
    "e0dc77297625631ac8e50fa92fffefe899a4eb702592da5c32ef04e2293aca3a";
  gmpSrc = fetch "https://mirrors.kernel.org/gnu/gmp/gmp-6.3.0.tar.xz"
    "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898";
  mpfrSrc = fetch "https://mirrors.kernel.org/gnu/mpfr/mpfr-4.2.1.tar.xz"
    "277807353a6726978996945af13e52829e3abd7a9a5b7fb2793894e18f1fcbb2";
  mpcSrc = fetch "https://mirrors.kernel.org/gnu/mpc/mpc-1.3.1.tar.gz"
    "ab642492f5cf882b74aa0cb730cd410a81edcdbec895183ce930e706c1c759b8";
  drvAttrs = {
  name = "gcc-${version}";
  inherit system gate stage0 gccSrc gmpSrc mpfrSrc mpcSrc version;
  # OpenIndiana/OmniOS gcc patch 0032: libstdc++ built with -D_TS_ERRNO so it
  # reads the per-thread errno. See the patch header for the measurement.
  tsErrnoPatch = ./patches/gcc-14/0032-libstdc-must-use-thread-local-errno.patch;
  libcDir = "${libcSlice}/lib/amd64";
  libcDir32 = "${libcSlice}/lib";
  libcExtraDir = "${libcExtra}/lib/amd64";
  # The link-editor is a store path (NixOS: the linker is part of stdenv), not the host /usr/bin/ld: gcc passes
  # -Qy, so every ELF records the ld version, which differed between OI (1793) and a solnix host (1791). repro2.
  ldBin = "${ld}/usr/bin/ld";
  SOURCE_DATE_EPOCH = "315532800";  # as NixOS stdenv: __DATE__/__TIME__ are the epoch, not the build day
  outputs = [ "out" "lib" ];
  builder = "/usr/bin/bash";
  PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";
  args = [ "-c" ''
    set -eu
    export PATH=/usr/gnu/bin:/usr/bin:/usr/sbin
    # Fixed build dir (as mk-src-pkg.nix): the compiler named the random mktemp dir 5741 times.
    # Keyed on $buildKey (eval-time digest of this drv's attrs), not $out: `nix build --check` builds into a scratch out.
    W=/var/tmp/gccsrc-$buildKey
    rm -rf "$W"; mkdir -m 700 "$W"; trap 'cd /; rm -rf "$W"' EXIT; cd "$W"
    # Deterministic archives (NixOS: binutils --enable-deterministic-archives). OI's GNU ar/ranlib stamp the
    # armap with the build time: 22 shipped .a differed under --check, and so did cc1/cc1plus, whose
    # executable_checksum is an md5 over libbackend.a & co. Every ar/ranlib on PATH gets D / -D (wave3).
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
    exec /usr/gnu/bin/ar "''${a[@]}"
    EOS
    printf '#!/usr/bin/bash\nexec /usr/gnu/bin/ranlib -D "$@"\n' > "$W/detbin/ranlib"
    chmod +x "$W/detbin/ar" "$W/detbin/ranlib"; export PATH="$W/detbin:$PATH"
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
      --with-gnu-as --with-as=/usr/bin/gas --without-gnu-ld --with-ld="$ldBin" \
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
    # The main output keeps its own copies of the runtime libs under $out/lib
    # (gcc's install layout; nothing links them, the wrapper uses $lib) and the
    # plugin libs libcc1*/libcp1plugin. Give every shared object in $out a store
    # RUNPATH as well: without it libatomic's NEEDED libgcc_s does not resolve and
    # libcc1* name the bootstrap compiler's /usr/gcc/14 (measured by the publish gate).
    for pair in "$out/lib/amd64:$libcDir" "$out/lib:$libcDir32"; do
      d=''${pair%%:*}; lc=''${pair#*:}
      for f in "$d"/*.so*; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        case "$f" in *.py) continue;; esac
        /usr/bin/elfdump -d "$f" 2>/dev/null | grep -q NEEDED || continue
        chmod u+w "$f"
        /usr/bin/elfedit -e "dyn:runpath $d:$lc" "$f"
      done
    done
    # The compiler binaries (bin/, libexec/gcc/) and the cc1 plugins
    # (lib/gcc/*/plugin) link the seed's C++ runtime statically and NEED only
    # libc/libm/libsocket/libnsl, but the bootstrap compiler left RUNPATH
    # /usr/gcc/14/lib/amd64 on every one. Point it at the store libc instead, so
    # nothing in $out names the build host.
    find "$out" -type f | while read -r f; do
      [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] || continue
      cur=$(/usr/bin/elfdump -d "$f" 2>/dev/null | awk '$2=="RUNPATH"{print $4}')
      # + libc-extra: the drivers NEED libkstat.so.1, which the libc slice lacks; + gcc.lib: the cc1
      # plugins NEED libstdc++/libgcc_s. With the libc slice alone ldd took the HOST /lib/64 libkstat
      # and found no libstdc++ (publish gate, 2026-10-29).
      case "$cur" in /usr/gcc/*) chmod u+w "$f"; /usr/bin/elfedit -e "dyn:runpath $libcDir:$libcExtraDir:$lib/lib/amd64" "$f";; esac
    done
    if find "$out" -type f | while read -r f; do
         [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] || continue
         /usr/bin/elfdump -d "$f" 2>/dev/null | awk '$2=="RUNPATH"{print $4}'
       done | grep -q '/usr/gcc'; then
      echo "FATAL: an ELF in $out still has a /usr/gcc RUNPATH" >&2; exit 1
    fi
    # every shipped archive's armap without a date, whatever wrote it (strip -D would strip the symbols too)
    find "$out" "$lib" -name '*.a' -type f | while read -r f; do chmod u+w "$f"; /usr/gnu/bin/ranlib -D "$f"; done
    # cc1/cc1plus executable_checksum (gcc's PCH validity stamp) is genchecksum's md5 over objects that embed $out. An
    # unsandboxed `nix-store --check` builds at a scratch out and rewrites only the hash string, never this md5 (wave3:
    # 7 objects equal after mapping scratch->real hash; only the two *-checksum.o differ). Set it to md5(name-buildKey):
    # still unique per compiler drv (what PCH needs), the same on every host and under --check.
    for f in "$out"/libexec/gcc/*/*/cc1 "$out"/libexec/gcc/*/*/cc1plus; do
      [ -f "$f" ] || continue
      sym=$(/usr/bin/nm -x "$f" | awk -F'|' '{gsub(/ /, "", $NF)} $NF == "executable_checksum" {print $2, $3, $7}')
      set -- $sym; [ "$(($2))" = 16 ] || { echo "FATAL: $f executable_checksum: [$sym]" >&2; exit 1; }
      read -r sn sa so < <(/usr/bin/elfdump -c "$f" | awk -v i="$(($3))" '$1 == "Section" {x = ($2 == "Header[" i "]:"); n = $4} x && /sh_addr:/ {a = $2} x && /sh_offset:/ {print n, a, $2; exit}')
      [ "$sn" = .rodata ] || { echo "FATAL: $f executable_checksum in [$sn], expected .rodata" >&2; exit 1; }
      h=$(printf '%s' "gcc-$version-$buildKey" | digest -a md5)
      # the 16 bytes as printf octal escapes, built with awk's %c 92 (a backslash written in this Nix string reached sed as plain x)
      e=""; i=0; while [ $i -lt 32 ]; do e="$e$(printf '%d' "0x''${h:$i:2}" | awk '{printf "%c%03o", 92, $1}')"; i=$((i + 2)); done
      chmod u+w "$f"; printf "$e" | dd of="$f" bs=1 seek=$(($1 - sa + so)) conv=notrunc 2>/dev/null
      [ "$(dd if="$f" bs=1 skip=$(($1 - sa + so)) count=16 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "$h" ] || { echo "FATAL: $f checksum write" >&2; exit 1; }
    done
    # DT_CHECKSUM -> 0 in both outputs (./zero-checksum.sh says why; gcc.lib names $lib in its RUNPATH).
    : > "$W/zc"; /usr/bin/bash ${./exempt/zero-checksum.sh} "$out" "$W/zc"; /usr/bin/bash ${./exempt/zero-checksum.sh} "$lib" "$W/zc"
    [ ! -s "$W/zc" ] || { cat "$W/zc" >&2; exit 1; }
    unset LD_LIBRARY_PATH LD_LIBRARY_PATH_64 LD_LIBRARY_PATH_32 || true
    # Every dynamic ELF in $out, not only lib/*.so*: the publish gate checks all of them, and this
    # gate let bin/gcc's host libkstat through.
    bad=$(find "$out" -type f | while read -r f; do
      [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] || continue
      /usr/bin/elfdump -d "$f" 2>/dev/null | grep -q NEEDED || continue
      /usr/bin/ldd "$f" 2>&1 | awk -v f="$f" '/not found/ || (/=>/ && $NF !~ /^\/nix\/store\//) {print f": "$0}'
    done)
    [ -z "$bad" ] || { echo "FATAL: $out shared libs leave the store:" >&2; echo "$bad" >&2; exit 1; }
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
};
# buildKey: 1:1 with the drv, the same on every host and under --check (mk-src-pkg.nix explains why).
in derivation (drvAttrs // { buildKey = builtins.substring 0 16 (builtins.hashString "sha256" (builtins.toJSON drvAttrs)); })
