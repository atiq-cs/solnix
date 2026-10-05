# mk-src-pkg.nix -- build a package FROM SOURCE into the store, with the host
# compiler used strictly as a BUILD tool.
#
# Why this exists next to mk-userland-pkg.nix: that builder drives the gcc14/
# clang/libc/ld SLICES (pkgs/illumos/toolchains.nix), and gcc14 is itself a copy
# of the host's IPS /usr/gcc/14 with a rewritten RUNPATH, so its runtime libs
# (libstdc++/libgcc_s) are re-labelled host binaries. This builder ships nothing
# from the compiler:
#   - headers: -nostdinc, then gcc's own freestanding include dir, then the GATE
#     PROTO's usr/include (illumos-gate source, pkgs/illumos/gate.nix).
#   - libs: -L the gate proto's lib dirs + each dep's lib dirs. -static-libgcc so
#     no libgcc_s.so.1 is NEEDED (C only; C++ would need a from-source libstdc++,
#     which is exactly why nix is not built here).
#   - RUNPATH: rewritten after install to store dirs only (this package's lib dir
#     for the ABI, each dep's, then runtimeLibDirs).
#   - GATE: every dynamic ELF in $out is run through `ldd` with LD_LIBRARY_PATH
#     unset; any "not found" or any resolution outside /nix/store FAILS the build.
#     The host's /lib and /usr/lib are not on any search path the gate accepts,
#     so a host library leaking in cannot pass.
#
# Each ABI in `abis` gets a fresh unpack and one run of `build` with:
#   $ABI (32|64), $CC, $LIBSUB (lib | lib/amd64), $SRC (unpacked tree), $out.
{ gate                       # gate proto store path (headers + link-time libs)
, runtimeLibDirs             # store lib dirs for the C runtime, both ABIs
, gcc ? "/usr/gcc/14"        # BUILD-TIME compiler (IPS developer/gcc-14; nothing of it ships)
}:

{ pname, version, src, build
, abis ? [ "64" ]
, deps ? [ ]                 # other mk-src-pkg outputs (or slices) this links
, system ? "x86_64-solaris"
}:

derivation {
  name = "${pname}-${version}";
  inherit system gate gcc build pname;
  builder = "/usr/bin/bash";
  PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";
  srcUrl = src.url;
  srcSha256 = src.sha256;
  abisArg = builtins.concatStringsSep " " abis;
  depsArg = builtins.concatStringsSep " " deps;
  rtDirs = builtins.concatStringsSep " " runtimeLibDirs;
  args = [ "-c" ''
    set -eu
    export PATH=/usr/gnu/bin:/usr/bin:/usr/sbin
    W=$(mktemp -d /var/tmp/srcpkg.XXXXXX)
    /usr/bin/curl -fsSL "$srcUrl" -o "$W/src.tar"
    got=$(sha256sum "$W/src.tar" | awk '{print $1}')
    [ "$got" = "$srcSha256" ] || { echo "FATAL: sha256 want $srcSha256 got $got" >&2; exit 1; }
    GI=$(ls -d "$gcc"/lib/gcc/*/[0-9]*.*/include | head -1)
    for ABI in $abisArg; do
      if [ "$ABI" = 64 ]; then LIBSUB=lib/amd64; GL="$gate/lib/amd64 $gate/usr/lib/amd64"
      else LIBSUB=lib; GL="$gate/lib $gate/usr/lib"; fi
      DL=""; DI=""
      for d in $depsArg; do
        [ -d "$d/$LIBSUB" ] && DL="$DL -L$d/$LIBSUB"
        [ -d "$d/include" ] && DI="$DI -I$d/include"
      done
      for g in $GL; do DL="$DL -L$g"; done
      cat > "$W/cc$ABI" <<EOF
    #!/usr/bin/bash
    exec $gcc/bin/gcc -m$ABI -nostdinc $DI -isystem $GI -isystem $gate/usr/include -B$(echo $GL | awk '{print $2}')/ $DL -static-libgcc "\$@"
    EOF
      chmod +x "$W/cc$ABI"
      export CC="$W/cc$ABI" ABI LIBSUB
      SRC="$W/s$ABI"; mkdir -p "$SRC"; cd "$SRC"
      tar xf "$W/src.tar"; cd "$(ls -d */ | head -1)"; SRC=$(pwd)
      echo "=== build $pname ABI=$ABI ===" >&2
      eval "$build"
      cd "$W"
    done

    # RUNPATH: store dirs only, per ELF class.
    rp_for() {
      sub=lib; [ "$1" = 64 ] && sub=lib/amd64
      r="$out/$sub"
      for d in $depsArg; do
        for s in $sub lib-$1; do [ -d "$d/$s" ] && r="$r:$d/$s"; done
      done
      for d in $rtDirs; do
        case "$d" in */amd64|*/lib-64) [ "$1" = 64 ] && r="$r:$d";; *) [ "$1" = 32 ] && r="$r:$d";; esac
      done
      echo "$r"
    }
    : > "$W/fail"
    find "$out" -type f | while read -r f; do
      /usr/bin/elfdump -d "$f" 2>/dev/null | grep -Eq 'NEEDED|SONAME' || continue
      c=$(od -An -tu1 -j4 -N1 "$f" | tr -d ' '); cl=32; [ "$c" -eq 2 ] && cl=64
      chmod u+w "$f"
      /usr/bin/elfedit -e "dyn:runpath $(rp_for $cl)" "$f" || echo "elfedit $f" >> "$W/fail"
    done
    # THE GATE: ldd with no LD_LIBRARY_PATH; nothing unresolved, nothing off-store.
    unset LD_LIBRARY_PATH LD_LIBRARY_PATH_64 LD_LIBRARY_PATH_32 || true
    find "$out" -type f | while read -r f; do
      /usr/bin/elfdump -d "$f" 2>/dev/null | grep -q NEEDED || continue
      /usr/bin/ldd "$f" 2>&1 | awk -v f="$f" '/not found/ || (/=>/ && $NF !~ /^\/nix\/store\//) {print f": "$0}' >> "$W/fail"
    done
    if [ -s "$W/fail" ]; then echo "FATAL: closure gate failed:" >&2; head -40 "$W/fail" >&2; exit 1; fi
    echo "=== $pname: every ELF resolves inside /nix/store ===" >&2
  '' ];
}
