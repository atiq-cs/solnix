# gcc15-src.nix -- GCC 15.3.0 FROM SOURCE with the illumos patch series, as a SECOND compiler (pkgs.solnix.gcc15).
# The stdenv compiler is still ./gcc-src.nix (14.3.0); nothing else builds with this one yet (gcc1, 2026-11-02).
#
# Same recipe as ./gcc-src.nix (stage0 compiles cc1/cc1plus, the new xgcc builds libgcc/libstdc++,
# --with-sysroot=<gate proto>, the out/lib split, the RUNPATH and errno gates, the wave5 reproducibility fixes),
# with four differences:
#  * store tools only (infra's dixi trial, 2026-11-02): stage0 is the solnix gcc 14 wrapper, not the host's IPS gcc-14,
#    and PATH is store tools + /usr/bin. No /usr/gnu, no /usr/gcc, no host perl or gas, so a solnix host can build it.
#  * the source is 15.3.0, which is NixOS 26.05's default gcc (default-gcc-version = 15).
#  * ALL 39 illumos patches (./patches/gcc-15/: OpenIndiana oi-userland components/developer/gcc-15 0001-0039 at
#    d759189, the same series as omniosorg/gcc il-15_2_0). gcc-src.nix applies only one of them (TS errno).
#    Plus OmniOS's two later fixes (omnios-build build/gcc15/patches 0040, 0041; OI does not have them yet):
#    0040 is GCC PR 126399. In GCC 15 __gthread_trigger left the hidden-visibility region, so the program's exported copy
#    sets ITS flag and not the library's. std::call_once in a .so then throws system_error "Unknown error", and
#    std::mutex locks there become no-ops. Measured: the from-source nix built with this gcc died "error: Unknown error"
#    in preloadNSS's call_once (gcc1, gdb watchpoint). 0041 makes ctype<char>::ctype() set its locale pointer
#    (the dragonfly clocale).
#    The series adds __illumos__, libc SSP (0030), -lsocket/-lnsl (0002: illumos libc has no socket()), the
#    .eh_frame_hdr unwinder (0003), frame pointers always (0012), -msave-args, and -fstrict-calling-conventions.
#    Not taken: OI 0040 / OmniOS 0042 (OmniOS /usr/gcc/N in -Y P; a store gcc has none) and OI 1000 (gccgo only).
#  * --enable-clocale=dragonfly, as OI and OmniOS configure it. Patches 0037-0039 make upstream configure accept it.
#    gcc-src.nix uses the generic model because plain upstream rejects the option.
# Why 15 and not 16.2, and the GCC 16 port plan: docs/gcc15.md. GCC 16's sol2.h drops the -Y P sysroot link path, and
# illumos ld has no -z sysroot.
{ gate                    # gate proto store path (the sysroot)
, ld                      # the store link-editor slice (default.nix ld): collect2 runs $ld/usr/bin/ld
, libcSlice               # pkgs.solnix.libc: RUNPATH target for libc/libm at run time
, libcExtra               # base-src's illumos-libc-extra: libkstat.so.1, which the drivers NEED
, stage0                  # BUILD-TIME compiler: srcPkgs.gccWrapper (gcc 14 + gas), the NixOS stage chain (infra's dixi trial fix 1)
, binutils                # store gas: --with-as, so the installed gcc needs no host /usr/bin/gas
, tools                   # store bin dirs, the whole PATH before /usr/bin (no /usr/gnu): seed make/tar/xz/grep/sed/binutils,
                          # coreutils (cp -P), findutils, gnupatch, perl (make_sunver.pl). Infra's dixi trial fixes 3 and 4.
, bash                    # store bash: CONFIG_SHELL (gate2 A1-tool: /usr/bin/bash is the OI host's); the seed instance's bash
, world                   # the gate userland as a store path: the illumos tools (elfedit elfdump ldd nm od awk digest), as the store
                          # copy of the gate binaries /usr/bin holds, so PATH has no host dir at all (wave6, rows1's finding)
, system ? "x86_64-solaris"
}:

let
  version = "15.3.0";
  fetch = url: sha256: import <nix/fetchurl.nix> { inherit url sha256; };
  gccSrc = fetch "https://mirrors.kernel.org/gnu/gcc/gcc-${version}/gcc-${version}.tar.xz"
    "fa59c1beef8995f27c4d71c1df227587189315d3e6faff1bb4306e61b0c530eb";
  gmpSrc = fetch "https://mirrors.kernel.org/gnu/gmp/gmp-6.3.0.tar.xz"
    "a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898";
  mpfrSrc = fetch "https://mirrors.kernel.org/gnu/mpfr/mpfr-4.2.1.tar.xz"
    "277807353a6726978996945af13e52829e3abd7a9a5b7fb2793894e18f1fcbb2";
  mpcSrc = fetch "https://mirrors.kernel.org/gnu/mpc/mpc-1.3.1.tar.gz"
    "ab642492f5cf882b74aa0cb730cd410a81edcdbec895183ce930e706c1c759b8";
  drvAttrs = {
  name = "gcc-${version}";
  inherit system gate stage0 gccSrc gmpSrc mpfrSrc mpcSrc version;
  # the illumos series (0001-0039) + OmniOS 0040-0041, applied in order (0033 is gcc-src.nix's TS-errno patch).
  patches = ./patches/gcc-15;
  libcDir = "${libcSlice}/lib/amd64";
  libcDir32 = "${libcSlice}/lib";
  libcExtraDir = "${libcExtra}/lib/amd64";
  # The link-editor is a store path (NixOS: the linker is part of stdenv), not the host /usr/bin/ld: gcc passes
  # -Qy, so every ELF records the ld version, which differed between OI (1793) and a solnix host (1791). repro2.
  ldBin = "${ld}/usr/bin/ld";
  SOURCE_DATE_EPOCH = "315532800";  # as NixOS stdenv: __DATE__/__TIME__ are the epoch, not the build day
  outputs = [ "out" "lib" ];
  builder = "/usr/bin/bash";
  inherit binutils tools world bash;
  # the world's bin dirs end PATH: the illumos base tools, from the store (no /usr/bin, /usr/sbin, /usr/gnu; ./path-gate.sh)
  worldPath = "${world}/usr/bin:${world}/usr/sbin:${world}/bin:${world}/sbin";
  PATH = "${tools}";
  args = [ "-c" ''
    set -eu
    # store tools, then the illumos base from the world store path (elfedit elfdump ldd nm od dd awk digest: the gate's binaries).
    # No /usr/bin, /usr/sbin or /usr/gnu: on an OI host they are OpenIndiana's, and configure found /usr/bin/nm and gmsgfmt there.
    export PATH="$tools:$worldPath"
    /usr/bin/bash ${./path-gate.sh}
    . ${./illumos-bin.sh}   # ILLUMOS_BIN for zero-checksum.sh (the world's elfedit, not a GNU elfedit)
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
    exec gar "''${a[@]}"
    EOS
    printf '#!/usr/bin/bash\nexec granlib -D "$@"\n' > "$W/detbin/ranlib"
    chmod +x "$W/detbin/ar" "$W/detbin/ranlib"
    # the unprefixed GNU names configure looked up in OI's /usr/gnu/bin (objdump readelf nm strip), from the store binutils
    for t in objdump readelf nm strip; do ln -s "$(command -v g$t)" "$W/detbin/$t"; done
    export PATH="$W/detbin:$PATH"
    PATH_GATE_ALLOW="$W" /usr/bin/bash ${./path-gate.sh}
    tar xf "$gccSrc"
    cd "gcc-$version"
    n=0; for p in "$patches"/0*.patch; do patch -p1 --no-backup-if-mismatch -s < "$p" >&2; n=$((n + 1)); done
    [ "$n" = 41 ] || { echo "FATAL: $n illumos patches applied, want 41" >&2; exit 1; }
    ! find . -name '*.rej' | grep -q . || { echo "FATAL: patch rejects" >&2; exit 1; }
    # make_sunver.pl (libgcc/libssp/libatomic version scripts) runs a fixed elfdump (OI patch 0028): the world's
    sed -i "s|^my \$elfdump = \"/usr/bin/elfdump\";|my \$elfdump = \"$world/usr/bin/elfdump\";|" contrib/make_sunver.pl
    grep -qF "my \$elfdump = \"$world/usr/bin/elfdump\";" contrib/make_sunver.pl || { echo "FATAL: make_sunver.pl elfdump not pinned" >&2; exit 1; }
    # GMP/MPFR/MPC in-tree: linked statically into cc1, so the compiler carries
    # no host math libs either.
    tar xf "$gmpSrc"; mv gmp-6.3.0 gmp
    tar xf "$mpfrSrc"; mv mpfr-4.2.1 mpfr
    tar xf "$mpcSrc"; mv mpc-1.3.1 mpc
    mkdir ../b; cd ../b
    # MAKEINFO=true: chef2 has /usr/bin/makeinfo, a solnix host none; the release tarball's prebuilt .info files are installed either way.
    export CC="$stage0/bin/gcc" CXX="$stage0/bin/g++" CONFIG_SHELL="$bash/bin/bash" MAKEINFO=true
    # the host-state configure answers pinned, as every store-only mk-src-pkg build (./config.site): libstdc++'s "checking for working
    # iconv" RUNS a conversion through the BUILD HOST's /usr/lib/iconv modules, so chef said yes and dixi (201 modules) no, and
    # libstdc++.so's std::format locale path differed (wave6t step41: dixi --check DIFFERS on gcc-15.3.0-lib). Pinned to yes: the
    # iconv functions are the store libc's, the same on every host.
    export CONFIG_SITE=${./config.site}
    # NM: binutils' gnm (configure took OI's /usr/bin/nm -p before). gettext tools: none (--disable-nls; configure still looked).
    export NM="$binutils/bin/gnm" NM_FOR_TARGET="$binutils/bin/gnm" MSGFMT=: GMSGFMT=: XGETTEXT=: MSGMERGE=:
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
      --with-gnu-as --with-as="$binutils/bin/as" --without-gnu-ld --with-ld="$ldBin" \
      --enable-shared --enable-__cxa_atexit --enable-initfini-array --enable-clocale=dragonfly \
      --without-zstd --disable-nls \
      --disable-libsanitizer --disable-libgomp --disable-libitm --disable-libvtv \
      --with-pkgversion="solnix ${version}" >&2
    # The target-library configure scripts (libstdc++) RUN test programs linked
    # by the new xgcc, which NEED the just-built libgcc_s.so.1. The build host has
    # no libgcc_s on its default path, so without this the probe dies in ld.so.1
    # ("libgcc_s.so.1: open failed") and configure reports "cannot run C compiled
    # programs" (measured). Build-time only; unset before the closure gate.
    export LD_LIBRARY_PATH_64="$W/b/gcc" LD_LIBRARY_PATH_32="$W/b/gcc/32"
    # -j from nix's --cores (NIX_BUILD_CORES), not psrinfo: build hosts are shared (chef2: 48 CPUs, three agents).
    gmake -j"''${NIX_BUILD_CORES:-8}" >&2 || gmake -j2 >&2
    gmake install >&2
    # install-tools (fixincl + mkheaders, re-run only by hand after a sysroot header change) bakes configure's sed: the seed
    # sed, which put seedBuildTools and its world (~300 MB) into gcc's closure (measured, v3b). nixpkgs deletes it for the same
    # reason ("a retained dependency on the previous gcc"; gcc/common/builder.nix).
    for d in "$out"/libexec/gcc/*/*/install-tools "$out"/lib/gcc/*/*/install-tools; do [ ! -e "$d" ] || find "$d" -depth -delete; done
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
        gstrip --strip-debug "$f"
        elfedit -e "dyn:runpath $dst:$lc" "$f"
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
        elfdump -d "$f" 2>/dev/null | grep -q NEEDED || continue
        chmod u+w "$f"
        elfedit -e "dyn:runpath $d:$lc" "$f"
      done
    done
    # The compiler binaries (bin/, libexec/gcc/) and the cc1 plugins (lib/gcc/*/plugin) link stage0's C++ runtime
    # statically and NEED only libc/libm/libsocket/libnsl(/libkstat), but they keep stage0's RUNPATH: the gcc 14 wrapper's
    # gcc-14.3.0-lib (or none at all, which reads the HOST /lib/64). Every dynamic ELF in $out whose RUNPATH is not
    # already this gcc's own (the lib loops above set those) gets the store one. Infra's dixi trial fix 5. Without it
    # bin/gcc kept a gcc-14.3.0-lib reference (infra measured that).
    # + libc-extra: the drivers NEED libkstat.so.1, which the libc slice lacks; + gcc.lib: the cc1
    # plugins NEED libstdc++/libgcc_s. With the libc slice alone ldd took the HOST /lib/64 libkstat
    # and found no libstdc++ (publish gate, 2026-10-29).
    find "$out" -type f | while read -r f; do
      [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] || continue
      elfdump -d "$f" 2>/dev/null | grep -q NEEDED || continue
      cur=$(elfdump -d "$f" 2>/dev/null | awk '$2=="RUNPATH"{print $4}')
      case "$cur" in "$out"/*|"$lib"/*) continue;; esac
      chmod u+w "$f"; elfedit -e "dyn:runpath $libcDir:$libcExtraDir:$lib/lib/amd64" "$f"
    done
    # gate: no RUNPATH in $out names the build host or another compiler's runtime (stage0's gcc.lib)
    s0lib=$(sed -n 's|.*-Wl,-R,\([^:]*\)/lib/amd64:.*|\1|p' "$stage0/bin/gcc")
    [ -n "$s0lib" ] || { echo "FATAL: no gcc.lib in $stage0/bin/gcc" >&2; exit 1; }
    if find "$out" -type f | while read -r f; do
         [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] || continue
         elfdump -d "$f" 2>/dev/null | awk '$2=="RUNPATH"{print $4}'
       done | grep -qE "/usr/gcc|$s0lib"; then
      echo "FATAL: an ELF in $out still has a /usr/gcc or stage0 ($s0lib) RUNPATH" >&2; exit 1
    fi
    # elfedit leaves the OLD RUNPATH string in .dynstr as dead bytes, and libtool's .la files name stage0's lib dir. With the
    # IPS seed that text was /usr/gcc/14 (not a store path); with the store stage0 it made the out reference gcc-14.3.0 and
    # gcc-14.3.0-lib, 1.2 GB of build-time closure (measured, v3). Overwrite those hashes in place, same length:
    # nixpkgs' remove-references-to. Nothing live points at them (the RUNPATH gate above passed).
    s0gcc=$(sed -n 's|^exec \([^ ]*\)/bin/gcc .*|\1|p' "$stage0/bin/gcc")
    [ -n "$s0gcc" ] || { echo "FATAL: no gcc in $stage0/bin/gcc" >&2; exit 1; }
    for h in "$(basename "$s0gcc" | cut -c1-32)" "$(basename "$s0lib" | cut -c1-32)"; do
      grep -rlaF "$h" "$out" "$lib" 2>/dev/null | while read -r f; do chmod u+w "$f"; LC_ALL=C sed -i "s/$h/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee/g" "$f"; done
      ! grep -rlaF "$h" "$out" "$lib" >/dev/null 2>&1 || { echo "FATAL: $out/$lib still names stage0 ($h)" >&2; exit 1; }
    done
    # every shipped archive's armap without a date, whatever wrote it (strip -D would strip the symbols too)
    find "$out" "$lib" -name '*.a' -type f | while read -r f; do chmod u+w "$f"; granlib -D "$f"; done
    # cc1/cc1plus executable_checksum (gcc's PCH validity stamp) is genchecksum's md5 over objects that embed $out. An
    # unsandboxed `nix-store --check` builds at a scratch out and rewrites only the hash string, never this md5 (wave3:
    # 7 objects equal after mapping scratch->real hash; only the two *-checksum.o differ). Set it to md5(name-buildKey):
    # still unique per compiler drv (what PCH needs), the same on every host and under --check.
    for f in "$out"/libexec/gcc/*/*/cc1 "$out"/libexec/gcc/*/*/cc1plus; do
      [ -f "$f" ] || continue
      sym=$("$world/usr/bin/nm" -x "$f" | awk -F'|' '{gsub(/ /, "", $NF)} $NF == "executable_checksum" {print $2, $3, $7}')
      set -- $sym; [ "$(($2))" = 16 ] || { echo "FATAL: $f executable_checksum: [$sym]" >&2; exit 1; }
      read -r sn sa so < <(elfdump -c "$f" | awk -v i="$(($3))" '$1 == "Section" {x = ($2 == "Header[" i "]:"); n = $4} x && /sh_addr:/ {a = $2} x && /sh_offset:/ {print n, a, $2; exit}')
      [ "$sn" = .rodata ] || { echo "FATAL: $f executable_checksum in [$sn], expected .rodata" >&2; exit 1; }
      h=$(printf '%s' "gcc-$version-$buildKey" | digest -a md5)
      # the 16 bytes as printf octal escapes, built with awk's %c 92 (a backslash written in this Nix string reached sed as plain x)
      e=""; i=0; while [ $i -lt 32 ]; do e="$e$(printf '%d' "0x''${h:$i:2}" | awk '{printf "%c%03o", 92, $1}')"; i=$((i + 2)); done
      chmod u+w "$f"; printf "$e" | dd of="$f" bs=1 seek=$(($1 - sa + so)) conv=notrunc 2>/dev/null
      [ "$(dd if="$f" bs=1 skip=$(($1 - sa + so)) count=16 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "$h" ] || { echo "FATAL: $f checksum write" >&2; exit 1; }
    done
    # DT_CHECKSUM -> 0 in both outputs (./zero-checksum.sh says why; gcc.lib names $lib in its RUNPATH).
    : > "$W/zc"; /usr/bin/bash ${./zero-checksum.sh} "$out" "$W/zc"; /usr/bin/bash ${./zero-checksum.sh} "$lib" "$W/zc"
    [ ! -s "$W/zc" ] || { cat "$W/zc" >&2; exit 1; }
    unset LD_LIBRARY_PATH LD_LIBRARY_PATH_64 LD_LIBRARY_PATH_32 || true
    # Every dynamic ELF in $out, not only lib/*.so*: the publish gate checks all of them, and this
    # gate let bin/gcc's host libkstat through.
    bad=$(find "$out" -type f | while read -r f; do
      [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] || continue
      elfdump -d "$f" 2>/dev/null | grep -q NEEDED || continue
      ldd "$f" 2>&1 | awk -v f="$f" '/not found/ || (/=>/ && $NF !~ /^\/nix\/store\//) {print f": "$0}'
    done)
    [ -z "$bad" ] || { echo "FATAL: $out shared libs leave the store:" >&2; echo "$bad" >&2; exit 1; }
    # Gate: the runtime libs resolve inside /nix/store with no LD_LIBRARY_PATH.
    unset LD_LIBRARY_PATH LD_LIBRARY_PATH_64 LD_LIBRARY_PATH_32 || true
    bad=$(for f in "$lib"/lib/libstdc++.so.6 "$lib"/lib/libgcc_s.so.1 "$lib"/lib/amd64/libstdc++.so.6 "$lib"/lib/amd64/libgcc_s.so.1; do
      ldd "$f" 2>&1 | awk -v f="$f" '/not found/ || (/=>/ && $NF !~ /^\/nix\/store\//) {print f": "$0}'
    done)
    [ -z "$bad" ] || { echo "FATAL: runtime libs leave the store:" >&2; echo "$bad" >&2; exit 1; }
    # Gate: libstdc++ must read the per-thread errno (___errno), never the global
    # errno symbol. Without the 0032 patch the 64-bit lib had 86 references to
    # errno@SUNW_0.7 and std::filesystem threw "Error 0" from worker threads; OI's
    # patched libstdc++ has 1 (measured). Allow a handful for code that takes
    # errno's ADDRESS legitimately, fail on anything near the unpatched count.
    nglob=$(gobjdump -d --no-show-raw-insn "$lib/lib/amd64/libstdc++.so.6" | grep -c 'errno@SUNW' || true)
    echo "=== libstdc++ global-errno references: $nglob ===" >&2
    [ "$nglob" -le 4 ] || { echo "FATAL: libstdc++ uses the GLOBAL errno ($nglob refs); -D_TS_ERRNO missing" >&2; exit 1; }
    echo "=== gcc-$version: lib output resolves inside /nix/store ===" >&2
  '' ];
};
# buildKey: 1:1 with the drv, the same on every host and under --check (mk-src-pkg.nix explains why).
in derivation (drvAttrs // { buildKey = builtins.substring 0 16 (builtins.hashString "sha256" (builtins.toJSON drvAttrs)); })
