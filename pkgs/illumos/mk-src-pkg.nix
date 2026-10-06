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
#   - libs: -L the gate proto's lib dirs + each dep's lib dirs. 64-bit objects are
#     compiled by the from-source gcc (gcc-src.nix) and link its libstdc++/libgcc_s
#     (RUNPATH -> gcc.lib). 32-bit objects come from the IPS seed with
#     -static-libgcc (the from-source gcc has no multilib yet).
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
, gcc ? "/usr/gcc/14"        # 64-bit compiler: the from-source gcc derivation (gcc-src.nix),
                             # or a host path (then it is a build tool only, as stage0 below)
, stage0 ? "/usr/gcc/14"     # IPS seed: used only when gcc is a host path (and for its
                             # freestanding include dir in that mode). Nothing of it ships.
}:

{ pname, version, src, build
, abis ? [ "64" ]
, deps ? [ ]                 # other mk-src-pkg outputs (or slices) this links
, selfRunpath ? true         # put this package's own lib dirs first in RUNPATH (false for a
                             # lib that NEEDs no sibling, so it can be copied out without
                             # carrying a reference back to this output)
, linkDeps ? [ ]             # build-time only (headers, link-time libs): NOT put in RUNPATH,
                             # so they stay out of the runtime closure (boost headers, json)
, system ? "x86_64-solaris"
}:

derivation {
  name = "${pname}-${version}";
  inherit system gate gcc stage0 build pname;
  # the from-source gcc's runtime dir (lib = 32-bit, lib/amd64 = 64-bit); empty for a host compiler.
  gccLib = if builtins.isAttrs gcc then "${gcc.lib}/lib" else "";
  builder = "/usr/bin/bash";
  PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";
  # The source is a fixed-output store path (NixOS: fetchurl), fetched once by Nix
  # and verified against the pinned sha256, not downloaded by the builder. A
  # builder-side curl was invisible to Nix: no retry, no cache, no substitution,
  # and one flaky mirror (ftp.gnu.org timed out after 81 s, measured) failed the
  # build. The hash check below stays as a second, independent verification.
  srcTar = builtins.fetchurl { inherit (src) url sha256; };
  srcSha256 = src.sha256;
  abisArg = builtins.concatStringsSep " " abis;
  depsArg = builtins.concatStringsSep " " deps;
  linkDepsArg = builtins.concatStringsSep " " linkDeps;
  selfRp = if selfRunpath then "1" else "";
  rtDirs = builtins.concatStringsSep " " runtimeLibDirs;
  args = [ "-c" ''
    set -eu
    export PATH=/usr/gnu/bin:/usr/bin:/usr/sbin
    W=$(mktemp -d /var/tmp/srcpkg.XXXXXX)
    cp "$srcTar" "$W/src.tar"
    got=$(sha256sum "$W/src.tar" | awk '{print $1}')
    [ "$got" = "$srcSha256" ] || { echo "FATAL: sha256 want $srcSha256 got $got" >&2; exit 1; }
    # RUNPATH: store dirs only, per ELF class.
    rp_for() {
      sub=lib; [ "$1" = 64 ] && sub=lib/amd64
      r=""; [ -n "$selfRp" ] && { r="$out/$sub"; [ "$1" = 64 ] && r="$r:$out/lib"; }
      for d in $depsArg; do
        for s in $sub lib-$1; do [ -d "$d/$s" ] && r="$r:$d/$s"; done
      done
      for d in $rtDirs; do
        case "$d" in */amd64|*/lib-64) [ "$1" = 64 ] && r="$r:$d";; *) [ "$1" = 32 ] && r="$r:$d";; esac
      done
      if [ -n "$gccLib" ]; then [ "$1" = 64 ] && r="$r:$gccLib/amd64" || r="$r:$gccLib"; fi
      echo "''${r#:}"
    }
    GI=$(ls -d "$stage0"/lib/gcc/*/[0-9]*.*/include | head -1)
    for ABI in $abisArg; do
      if [ "$ABI" = 64 ]; then LIBSUB=lib/amd64; GL="$gate/lib/amd64 $gate/usr/lib/amd64"
      else LIBSUB=lib; GL="$gate/lib $gate/usr/lib"; fi
      DL=""; DI=""
      for d in $depsArg $linkDepsArg; do
        [ -d "$d/$LIBSUB" ] && DL="$DL -L$d/$LIBSUB"
        [ -d "$d/include" ] && DI="$DI -I$d/include"
      done
      for g in $GL; do DL="$DL -L$g"; done
      PCD=""; CPP_=""
      for d in $depsArg $linkDepsArg; do
        for s in "$LIBSUB/pkgconfig" lib/pkgconfig share/pkgconfig; do [ -d "$d/$s" ] && PCD="$PCD:$d/$s"; done
        CPP_="$CPP_;$d"
      done
      # deps only: no host .pc file or cmake package can be picked up.
      export PKG_CONFIG_LIBDIR="''${PCD#:}" PKG_CONFIG_PATH="" CMAKE_PREFIX_PATH="''${CPP_#;}"
      if [ -n "$gccLib" ]; then
        # The from-source gcc: its sysroot is the gate proto, so its default headers,
        # crt objects and libs are the gate's. The final RUNPATH is baked at link
        # time (-R): post-link editing is capped by .dynstr padding (~512 B), and
        # the nix closure's RUNPATH is longer than that.
        RP=$(rp_for $ABI)
        for t in gcc:cc g++:c++; do
          cat > "$W/''${t#*:}$ABI" <<EOF
    #!/usr/bin/bash
    exec $gcc/bin/''${t%%:*} -m$ABI $DI $DL -Wl,-R,$RP "\$@"
    EOF
          chmod +x "$W/''${t#*:}$ABI"
        done
        export CXX="$W/c++$ABI"
      else
        cat > "$W/cc$ABI" <<EOF
    #!/usr/bin/bash
    exec $stage0/bin/gcc -m$ABI -nostdinc $DI -isystem $GI -isystem $gate/usr/include -B$(echo $GL | awk '{print $2}')/ $DL -static-libgcc "\$@"
    EOF
        chmod +x "$W/cc$ABI"
      fi
      export CC="$W/cc$ABI" ABI LIBSUB
      SRC="$W/s$ABI"; mkdir -p "$SRC"; cd "$SRC"
      tar xf "$W/src.tar"; cd "$(ls -d */ | head -1)"; SRC=$(pwd)
      echo "=== build $pname ABI=$ABI ===" >&2
      eval "$build"
      cd "$W"
    done

    # strip debug info (stdenv's strip phase): DWARF records the compiler's and
    # the sysroot's store paths, which Nix's reference scan turns into runtime
    # dependencies on the whole compiler and gate proto. libtool .la files name
    # build-time paths too and nothing at run time reads them.
    find "$out" -name '*.la' -type f -delete
    find "$out" -type f | while read -r f; do
      [ "$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')" = 7f454c46 ] || continue
      chmod u+w "$f"; /usr/bin/gstrip --strip-debug "$f" 2>/dev/null || true
    done
    : > "$W/fail"
    # the two big build-time-only paths (gate proto, compiler) must not appear in
    # any shipped ELF, or the runtime closure silently grows by ~400 MB.
    for x in "$gate" $([ -n "$gccLib" ] && echo "$gcc"); do
      grep -rl --binary-files=binary "$x" "$out" 2>/dev/null | while read -r f; do
        [ "$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')" = 7f454c46 ] && echo "$f: names build-time path $x" >> "$W/fail"
        true
      done
    done
    find "$out" -type f | while read -r f; do
      /usr/bin/elfdump -d "$f" 2>/dev/null | grep -Eq 'NEEDED|SONAME' || continue
      c=$(od -An -tu1 -j4 -N1 "$f" | tr -d ' '); cl=32; [ "$c" -eq 2 ] && cl=64
      # already store-only (baked at link time)? leave it; else rewrite.
      cur=$(/usr/bin/elfdump -d "$f" | awk '$2=="RUNPATH"{print $4}')
      if [ -n "$cur" ] && [ -z "$(echo "$cur" | tr ':' '\n' | grep -v '^/nix/store/')" ]; then continue; fi
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
