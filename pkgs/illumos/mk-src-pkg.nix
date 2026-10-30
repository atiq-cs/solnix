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
, buildTools ? [ ]           # store paths whose bin/ go FIRST on the builder PATH, so the
                             # build names store gmake/gnutar/gzip/xz/bzip2/gnugrep/gnused/
                             # gstrip instead of an OI host's /usr/gnu + decompressors. Each
                             # is a real Nix reference (baked into the drv), pulled into the
                             # build-time closure. Default [] => builder PATH is byte-for-byte
                             # the old /usr/gnu:/usr/bin:/usr/sbin (the OI buildhost path),
                             # so this arg changes NO hash for the bhost build. A solnix
                             # system (no /usr/gnu, no gstrip, no gzip) passes the store set.
, aarch64 ? false           # native aarch64 illumos (aa64nix): LP64 only, libs in lib/ (lib/64 -> .).
                             # false = the x86 text byte-for-byte, so no x86 drv hash moves.
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

let
  # bin/ dirs of each buildTools store path, joined with ':'. Empty list -> "",
  # and the "${btPath:+$btPath:}" guards below then collapse to the original
  # /usr/gnu/bin:/usr/bin:/usr/sbin, so a default (bhost) build is unchanged.
  btPath = builtins.concatStringsSep ":" (map (d: "${d}/bin") buildTools);
  # gstrip: binutils ships it in a buildTools entry on a solnix system; on the
  # OI host it is /usr/bin/gstrip. Pick a store gstrip if a buildTools bin/ has
  # one, else the host path. (illumos /usr/bin/strip is SVR4 strip and does not
  # take --strip-debug; using it would be a silent no-op, so never fall to it.)
  gstripCands = (map (d: "${d}/bin/gstrip") buildTools) ++ [ "/usr/bin/gstrip" ];
  # aarch64: rewrite the x86 builder text (lib/amd64 -> lib, -m$ABI -> the arm64-gate target
  # flags: illumos aarch64 ld has no TLSDESC relocs and shared links miss libgcc.a's outline
  # atomics, both measured on nix), plus the bootstrap box's autotools/config.guess quirks.
  # shortcut: aclocal dirs name the stage0 box (/opt/nixboot, /opt/ooce), as x86 names the OI
  # host's /usr/share/aclocal; upgrade when pkgconf/autoconf-archive are store build tools.
  lp64Fix = t: if !aarch64 then t else builtins.replaceStrings
    [ ''case "$d" in */amd64|*/lib-64) [ "$1" = 64 ] && r="$r:$d";; *) [ "$1" = 32 ] && r="$r:$d";; esac''
      "lib/amd64" "$gccLib/amd64" " -m$ABI " "architecture=x86 abi=sysv" "gmake -j3 "
      "ACLOCAL_PATH=/usr/share/aclocal autoreconf -fi -I /usr/share/aclocal" "./configure --prefix="
      ''export PATH="''${btPath:+$btPath:}/usr/gnu/bin:/usr/bin:/usr/sbin"''
      stripLoop rpLoop "INSTALL=ginstall" ''-Dlddlflags="-shared -m64"'' ]
    [ ''r="$r:$d"''
      "lib" "$gccLib" " -mno-outline-atomics -mtls-dialect=trad " "architecture=arm abi=aapcs" "gmake -j24 "
      "ACLOCAL_PATH=/opt/nixboot/share/aclocal:/opt/ooce/autoconf-archive/share/aclocal M4=/usr/bin/gm4 autoreconf -fi -I /opt/nixboot/share/aclocal -I /opt/ooce/autoconf-archive/share/aclocal"
      "./configure --build=aarch64-unknown-solaris2.11 --prefix="
      # cmake (/opt/ooce) + pkgconf (/opt/nixboot) of the stage0 box, as x86 uses the OI host's.
      ''export PATH="''${btPath:+$btPath:}/usr/gnu/bin:/usr/bin:/usr/sbin:/opt/ooce/bin:/opt/nixboot/bin"''
      # RUNPATH rewrite BEFORE the strip: GNU strip 2.43.1 zeroes .SUNW_ldynsym sh_link on
      # aarch64 and illumos elfedit then segfaults (measured on libstdc++.so.6.0.33);
      # elfedit-then-strip works. The build-time-path guards still run after the strip.
      (rpLoop + stripLoop) ""
      "INSTALL=/usr/gnu/bin/install"  # braich ships GNU install only as /usr/gnu/bin/install
      ''-Dlddlflags="-shared"'' ] t;    # perl (cli/c-big.nix): aarch64 gcc has no -m64
  stripLoop = ''
    find "$out" -type f | while read -r f; do
      # ELF, or an ar archive ("!<ar"): -D zeroes archive member mtimes (NixOS binutils is --enable-deterministic-archives).
      case "$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')" in 7f454c46|213c6172) ;; *) continue;; esac
      chmod u+w "$f"; "$GSTRIP" --strip-debug -D "$f" 2>/dev/null || true
    done
  '';
  rpLoop = ''
    find "$out" -type f | while read -r f; do
      /usr/bin/elfdump -d "$f" 2>/dev/null | grep -Eq 'NEEDED|SONAME' || continue
      c=$(od -An -tu1 -j4 -N1 "$f" | tr -d ' '); cl=32; [ "$c" -eq 2 ] && cl=64
      # already store-only (baked at link time)? leave it; else rewrite.
      cur=$(/usr/bin/elfdump -d "$f" | awk '$2=="RUNPATH"{print $4}')
      if [ -n "$cur" ] && [ -z "$(echo "$cur" | tr ':' '\n' | grep -v '^/nix/store/')" ]; then continue; fi
      chmod u+w "$f"
      /usr/bin/elfedit -e "dyn:runpath $(rp_for $cl)" "$f" || echo "elfedit $f" >> "$W/fail"
    done
  '';
  drvAttrs = {
  name = "${pname}-${version}";
  inherit system gate gcc stage0 pname;
  build = lp64Fix build;
  # the from-source gcc's runtime dir (lib = 32-bit, lib/amd64 = 64-bit); empty for a host compiler.
  gccLib = if builtins.isAttrs gcc then "${gcc.lib}/lib" else "";
  # buildTools' bin/ dirs on PATH (btPath) and the gstrip candidates both
  # interpolate each store path, so buildTools become real Nix references and
  # are pulled into the build-time closure.
  btPath = btPath;
  gstripCands = builtins.concatStringsSep " " gstripCands;
  builder = "/usr/bin/bash";
  PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";
  SOURCE_DATE_EPOCH = "315532800";  # as NixOS stdenv: gcc uses it for __DATE__/__TIME__ (gdbm embedded its build day)
  # The source is a fixed-output store path (NixOS: fetchurl), fetched once by Nix
  # and verified against the pinned sha256, not downloaded by the builder. A
  # builder-side curl was invisible to Nix: no retry, no cache, no substitution,
  # and one flaky mirror (ftp.gnu.org timed out after 81 s, measured) failed the
  # build. The hash check below stays as a second, independent verification.
  # <nix/fetchurl.nix>: a builtin:fetchurl FOD, so eval downloads nothing (same store path).
  srcTar = import <nix/fetchurl.nix> { inherit (src) url sha256; };
  srcSha256 = src.sha256;
  abisArg = builtins.concatStringsSep " " abis;
  depsArg = builtins.concatStringsSep " " deps;
  linkDepsArg = builtins.concatStringsSep " " linkDeps;
  selfRp = if selfRunpath then "1" else "";
  rtDirs = builtins.concatStringsSep " " runtimeLibDirs;
  args = [ "-c" (lp64Fix ''
    set -eu
    # buildTools store bin/ dirs go first (store gmake/gnutar/gzip/xz/bzip2/
    # gnugrep/gnused/gstrip on a solnix system). Empty $btPath collapses this to
    # the old /usr/gnu/bin:/usr/bin:/usr/sbin, so the bhost build is unchanged.
    export PATH="''${btPath:+$btPath:}/usr/gnu/bin:/usr/bin:/usr/sbin"
    # FIXED build dir, not mktemp: configure/libtool record it in shipped strings (jq's `CC=<W>/cc64`
    # and its .libs search path), so a random name made every build's NarHash differ (measured:
    # docs/pending/builders-need-store-tools.md, 2026-10-29). NixOS builds in the sandbox's /build;
    # illumos has no sandbox, so: one constant path per output, the same on every host (unlike
    # $NIX_BUILD_TOP, which follows the daemon's TMPDIR). Keyed by $buildKey, an eval-time digest of
    # this drv's attrs (so 1:1 with the drv), NOT $out: `nix build --check/--rebuild` builds into a
    # scratch out, and jq embeds W (measured, repro2). Nix locks the real out path for normal and
    # --check builds alike, so two builds of one drv on one host never share W at the same time.
    # mkdir without -p FAILS if a stale entry we cannot remove (another user's) is in the way.
    W=/var/tmp/srcpkg-$buildKey
    # Removed on ANY exit: a stale dir from a failed build by another nixbld uid could not be.
    rm -rf "$W"; mkdir -m 700 "$W"; trap 'cd /; rm -rf "$W"' EXIT
    cp "$srcTar" "$W/src.tar"
    # illumos has no sha256sum; /usr/bin/digest -a sha256 is always present and
    # emits lowercase hex, matching the plain-hex src.sha256 (verified on dixi).
    got=$(/usr/bin/digest -a sha256 "$W/src.tar")
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
      # -D_TS_ERRNO in both wrappers: errno is per-thread, as in illumos-gate (DTS_ERRNO).
      # Without it errno is the main thread's global and other threads clobber it (./ts-errno-gate.sh).
      if [ -n "$gccLib" ]; then
        # The from-source gcc: its sysroot is the gate proto, so its default headers,
        # crt objects and libs are the gate's. The final RUNPATH is baked at link
        # time (-R): post-link editing is capped by .dynstr padding (~512 B), and
        # the nix closure's RUNPATH is longer than that.
        RP=$(rp_for $ABI)
        for t in gcc:cc g++:c++; do
          cat > "$W/''${t#*:}$ABI" <<EOF
    #!/usr/bin/bash
    exec $gcc/bin/''${t%%:*} -m$ABI -D_TS_ERRNO $DI $DL -Wl,-R,$RP "\$@"
    EOF
          chmod +x "$W/''${t#*:}$ABI"
        done
        export CXX="$W/c++$ABI"
      else
        cat > "$W/cc$ABI" <<EOF
    #!/usr/bin/bash
    exec $stage0/bin/gcc -m$ABI -D_TS_ERRNO -nostdinc $DI -isystem $GI -isystem $gate/usr/include -B$(echo $GL | awk '{print $2}')/ $DL -static-libgcc "\$@"
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
    # GNU strip (gstrip) does --strip-debug; the OI host has /usr/bin/gstrip,
    # a solnix system gets it from a buildTools entry (binutils). illumos
    # /usr/bin/strip is SVR4 strip and silently ignores --strip-debug, so it is
    # NOT a fallback. Resolve the first candidate that exists.
    GSTRIP=""; for g in $gstripCands; do [ -x "$g" ] && { GSTRIP="$g"; break; }; done
    [ -n "$GSTRIP" ] || { echo "FATAL: no gstrip (GNU strip) on this host or in buildTools" >&2; exit 1; }
    find "$out" -type f | while read -r f; do
      # ELF, or an ar archive ("!<ar"): -D zeroes archive member mtimes (NixOS binutils is --enable-deterministic-archives).
      case "$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')" in 7f454c46|213c6172) ;; *) continue;; esac
      chmod u+w "$f"; "$GSTRIP" --strip-debug -D "$f" 2>/dev/null || true
    done
    # BUILD-TOOL PATHS BAKED INTO GENERATED SCRIPTS (the stdenv patchShebangs /
    # --replace analog). A package's own ./configure can hardcode the ABSOLUTE path
    # of a build tool it found on PATH into a generated SHELL SCRIPT: gzip's
    # configure writes GREP=<grep-on-PATH> into bin/zgrep, and on a solnix system
    # that PATH leads with the seedBuildTools farm (btPath). The result: the ~239 MB
    # SEED world (its own illumos-userland + the seed GNU tools -- a SECOND copy of
    # what the system already ships) becomes a RUNTIME reference of gzip and rides
    # into every toplevel closure. Measured on the installer-live toplevel: that
    # duplicate illumos-userland was 57% of the live-ramdisk closure and by itself
    # pushed it 207 MB over the X1 boot_archive ceiling -- caused by this one zgrep
    # line. The ELF/RUNPATH guard below never saw it (zgrep is text, not an ELF).
    #
    # Fix it the stdenv way: a generated script must resolve its tools from the
    # RUNTIME PATH, not a build-time absolute path. Strip each buildTools bin/
    # prefix from every NON-ELF file in $out, so "<store>/bin/grep" becomes "grep"
    # (the system has gnugrep on PATH as grep). ELF files are left to the RUNPATH
    # pass + ldd gate; only text scripts are touched. Empty btPath (the bhost
    # buildTools=[] build) makes this a no-op, so that path stays byte-identical.
    if [ -n "''${btPath:-}" ]; then
      _oldifs=$IFS; IFS=:
      for _btd in $btPath; do
        [ -n "$_btd" ] || continue
        find "$out" -type f | while read -r f; do
          [ "$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')" = 7f454c46 ] && continue  # skip ELF
          grep -q "$_btd/" "$f" 2>/dev/null || continue
          chmod u+w "$f"; sed "s@$_btd/@@g" "$f" > "$f.btfix" && mv "$f.btfix" "$f" \
            || { echo "FATAL: could not de-bake build-tool path $_btd in $f" >&2; exit 1; }
        done
      done
      IFS=$_oldifs
    fi
    : > "$W/fail"
    # no shipped ELF may reference the global errno (the wrappers pass -D_TS_ERRNO)
    /usr/bin/bash ${./ts-errno-gate.sh} "$out" 2>> "$W/fail" || echo "ts-errno gate failed for $out" >> "$W/fail"
    # the two big build-time-only paths (gate proto, compiler) must not appear in
    # any shipped ELF, or the runtime closure silently grows by ~400 MB.
    # grep's status is checked, not piped away: 0 = hits, 1 = none, anything else
    # (an option this grep rejects, an unreadable file) FAILS the build. Piping
    # grep into the loop with 2>/dev/null turned an error into "no hits": on a
    # system without GNU grep, --binary-files is rejected (illumos grep, measured)
    # and the guard checked nothing. -rl is POSIX-enough for both greps.
    for x in "$gate" $([ -n "$gccLib" ] && echo "$gcc"); do
      rc=0; grep -rl "$x" "$out" > "$W/hits" || rc=$?
      [ "$rc" -le 1 ] || { echo "FATAL: build-time-path guard: grep -rl exited $rc" >&2; exit 1; }
      while read -r f; do
        [ "$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')" = 7f454c46 ] && echo "$f: names build-time path $x" >> "$W/fail"
        true
      done < "$W/hits"
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
    /usr/bin/bash ${./zero-checksum.sh} "$out" "$W/fail"
    # THE GATE: ldd with no LD_LIBRARY_PATH; nothing unresolved, nothing off-store.
    unset LD_LIBRARY_PATH LD_LIBRARY_PATH_64 LD_LIBRARY_PATH_32 || true
    find "$out" -type f | while read -r f; do
      /usr/bin/elfdump -d "$f" 2>/dev/null | grep -q NEEDED || continue
      /usr/bin/ldd "$f" 2>&1 | awk -v f="$f" '/not found/ || (/=>/ && $NF !~ /^\/nix\/store\//) {print f": "$0}' >> "$W/fail"
    done
    if [ -s "$W/fail" ]; then echo "FATAL: closure gate failed:" >&2; head -40 "$W/fail" >&2; exit 1; fi
    echo "=== $pname: every ELF resolves inside /nix/store ===" >&2
  '') ];
};
in derivation (drvAttrs // { buildKey = builtins.substring 0 16 (builtins.hashString "sha256" (builtins.toJSON drvAttrs)); })
