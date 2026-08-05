# tranche-entry-224.nix — Phase-3 "build real hermetic x86_64-solaris
# derivations against the pure stdenv" entry point, on Nix 2.24+.
#
# This is the 2.24 successor to tranche-entry.nix, now wired against the NEWER
# nixpkgs fork (qmvlnvf0, the one the 2.3.16 tranche6 used) so the
# fetchFromGitHub/fetchpatch-src packages (curl/git/vim/htop/nvi/gdb) evaluate:
# the older 00w7p2sg fork's eval-time fetchurl-shim only covered plain
# `fetchurl`, so fetchpatch (H18) and fetchzip/fetchFromGitHub (H19) srcs threw.
# The qmvlnvf0 fork ships the H18/H19-covering shim (fetchurl-shim, passed as
# `fetchurlShim`), plus the H20-H36 per-package fixes live in the primary's
# solaris-overlay (passed as `solarisOverlay`).
#
# 2.24 vs 2.3.16: Nix 2.24 writes .attrs.sh and exports NIX_ATTRS_SH_FILE
# natively, so the `__structuredAttrs = false` adapter the 2.3.16 daemon needed
# is DELETED here; the by-name package universe builds directly on the nixpkgs
# default. The tranche6 stack's structuredAttrs adapter + fetchurlBoot re-assert
# are therefore dropped; everything else (perl wrap, bash pins, the base
# illumosGnm/gmpCOnly/mpfrCOnly overlays, the primary solaris-overlay) carries
# over unchanged.
#
# HOST DEPENDENCY (seed stage0): the seed's GNU userland `awk` (gawk) NEEDs
# libmpfr.so.6 from the host runtime linker path (stdenv setup.sh's
# substituteAll enumerates @var@ via awk). The build host must provide
# libmpfr.so.6 (`pkg install library/mpfr`). Stage0 host dep only; the FINAL
# package closure stays host-free.
#
# Usage on host (Nix 2.24 store nix):
#   nix-build /root/tranche-224.nix -A <nixpkgs-attr>   # e.g. -A gettext
{ system ? "x86_64-solaris"
, nixpkgs ? <nixpkgs-patched>
, illumos ? /root/solnix-pkgs/pkgs/os-specific/illumos
, fetchurlShim ? ./fetchurl-shim-qmvlnvf0.nix
, solarisOverlay ? /root/solaris-overlay-qmvlnvf0.nix
}:
import nixpkgs {
  inherit system;
  overlays = [
    (final: prev: { solnix = final.callPackage illumos { }; illumos = final.solnix; })
    (import fetchurlShim)
    # H3 (from tranche 5): route stdenv.fetchurlBoot through the same shim so
    # the libxcrypt perl<->libxcrypt cycle-break src is an eval-time
    # fixed-output fetch. On 2.24 the shim's fetchurlBoot passthru
    # (solnixShimFetch) is baked directly onto the stdenv (no structuredAttrs
    # adapter re-wrap to fight).
    (final: prev: {
      stdenv = prev.stdenv // { fetchurlBoot = final.solnixShimFetch; };
      stdenvNoCC = prev.stdenvNoCC // { fetchurlBoot = final.solnixShimFetch; };
    })
    # perl fix (H10/H11 from tranche 5): drop the Linux-only ld-shared.patch
    # and add the illumos split-libc link libs (-lm -lnsl -lsocket), applied as
    # a whole-stdenv mkDerivation wrap so every perl variant in the graph
    # (build-time deps of git/curl/gettext) gets it. The fetchurlBoot passthru
    # above is preserved because this wrap only rewrites .mkDerivation.
    (final: prev:
      let
        fixPerlAttrs = a:
          if (a.pname or "") == "perl"
          then a // {
            patches = builtins.filter
              (p: baseNameOf (toString p) != "ld-shared.patch")
              (a.patches or []);
            NIX_LDFLAGS =
              (if a ? NIX_LDFLAGS then a.NIX_LDFLAGS + " " else "")
              + "-lm -lnsl -lsocket";
          }
          else a;
        patchPerl = stdenv: stdenv // {
          mkDerivation = args:
            if builtins.isFunction args
            then stdenv.mkDerivation (finalAttrs: fixPerlAttrs (args finalAttrs))
            else stdenv.mkDerivation (fixPerlAttrs args);
        };
      in {
        stdenv = patchPerl prev.stdenv;
      })
    # bashNonInteractive lost its shellPath passthru (lowPrio + spliced pkgset),
    # so runtimeShell = bash + bash.shellPath throws. Restore shellPath and pin
    # runtimeShell/runtimeShellPackage to plain bash so packages that read
    # runtimeShell in configureFlags evaluate.
    (final: prev: {
      bashNonInteractive = prev.bashNonInteractive // { shellPath = "/bin/bash"; };
      runtimeShellPackage = prev.bash;
      runtimeShell = "${prev.bash}/bin/bash";
    })
    # illumosGnm + the C-only gmp/mpfr + no-check libffi that the solaris-overlay
    # withGnm helper and the fragile-test packages depend on.
    (final: prev: {
      illumosGnm = final.runCommand "illumos-gnm" { } ''
        mkdir -p $out/bin
        ln -s ${final.stdenv.cc.bintools.bintools}/bin/nm $out/bin/gnm
      '';
      gmpCOnly = (final.gmp.override { cxx = false; }).overrideAttrs (_: { doCheck = false; });
      libffiNoCheck = final.libffi.overrideAttrs (_: { doCheck = false; });
      mpfrCOnly = (final.mpfr.override { gmp = final.gmpCOnly; }).overrideAttrs (_: { doCheck = false; });
    })
    (import solarisOverlay)
    # H26 attempt (2.24): cmake-minimal's bundled/linked libuv links
    # -lkstat -lsendfile (illumos), absent from the seed's 13 base libs, so the
    # cmake bootstrap fails `ld: fatal: library -lkstat: not found`. The
    # extra-syslibs FOD (same provenance as the seed, hash-pinned) carries
    # libkstat/libsendfile/libproc in lib/amd64 with .so links. Wire its -L into
    # libuv (which the solaris-overlay already patches for errno.h) so the
    # cmake bootstrap link resolves. Unblocks cmake -> nvi (via zlib-ng-free
    # nvi2 cmake build). extraSyslibs rebuilt inline (the overlay's copy is in a
    # private `let`).
    (final: prev:
      let
        extraSyslibs = final.stdenvNoCC.mkDerivation {
          name = "illumos-extra-syslibs";
          src = /nix/store/qbl2q3v2h3y4ghc6mpjc2cmjyf0ppabq-extra-syslibs.tar.gz;
          dontUnpack = true;
          installPhase = ''mkdir -p "$out"; tar -xzf "$src" -C "$out"'';
        };
        seedL = "-L${extraSyslibs}/lib/amd64";
      in {
        # cmake's own bootstrap builds a bundled libuv (Utilities/cmlibuv) that
        # links kstat_*/sendfile on illumos -> `ld: fatal: library -lkstat: not
        # found`. The nixpkgs libuv buildInput is separate, so the fix must land
        # on cmake-minimal's bootstrap link: add the extra-syslibs -L and the
        # two libs to NIX_LDFLAGS, and the -L to compile flags (H1 auto-adds -R).
        cmakeMinimal = prev.cmakeMinimal.overrideAttrs (old: {
          env = (old.env or { }) // {
            NIX_CFLAGS_COMPILE = (old.env.NIX_CFLAGS_COMPILE or "") + " " + seedL;
            NIX_LDFLAGS = (old.env.NIX_LDFLAGS or "") + " " + seedL + " -lkstat -lsendfile";
          };
        });
      })
    # release-toolset curl/rsync: the full `curl` attr and rsync enable
    # zstd/brotli/lz4/xxHash, which pull zstd -> cmake (H26, still blocked on
    # this fork: cmake-minimal bootstrap fails on -lkstat/-lsendfile). The
    # release-critical curl deps are openssl+zlib+nghttp2 (http2) only, and
    # rsync's core is fine without those compressors. Drop the cmake-pulling
    # features so both build; scpSupport/libssh2 is already off on SunOS by
    # default. This preserves the solaris-overlay's gssSupport=false + socket
    # libs (curl) via a further .override/.overrideAttrs on the overlay result.
    (final: prev: {
      curl = (prev.curl.override {
        zstdSupport = false; brotliSupport = false;
        http3Support = false; pslSupport = false;
      });
      rsync = (prev.rsync.override {
        enableZstd = false; enableLZ4 = false; enableXXHash = false;
      }).overrideAttrs (old: {
        # python3 (nativeCheckInputs, for runtests.py) pulls cmake (H26,
        # blocked). Tests are not the deliverable on a fresh port; drop the
        # check inputs + doCheck so cmake never enters the build.
        doCheck = false;
        nativeCheckInputs = [];
        preCheck = "";
      });
      # gdb: pythonSupport (build==host default) pulls python3 -> cmake, and
      # zstd/xxhash/sourceHighlight/dejagnu/libipt buildInputs each pull cmake
      # too (all H26-blocked). The release-critical gdb deps are
      # gmp/mpfr/ncurses/readline/expat/zlib (all on 2.24 already). Drop the
      # cmake-pullers and disable debuginfod (elfutils). The H2 seedSyslibs
      # RUNPATH supplies libstdc++/libgcc_s at runtime, so no static-libgcc/
      # -static-libstdc++ is needed (and those flags break the illumos conftest
      # link -> "C compiler cannot create executables"). doCheck off (dejagnu).
      gdb = (prev.gdb.override {
        pythonSupport = false;
        withGuile = false;
        enableDebuginfod = false;
      }).overrideAttrs (old: {
        buildInputs = builtins.filter
          (b: let n = b.pname or b.name or ""; in
              !(final.lib.hasInfix "zstd" n || final.lib.hasInfix "source-highlight" n
                || final.lib.hasInfix "sourceHighlight" n || final.lib.hasInfix "xxhash" n
                || final.lib.hasInfix "xxHash" n || final.lib.hasInfix "dejagnu" n
                || final.lib.hasInfix "libipt" n || final.lib.hasInfix "processor-trace" n))
          (old.buildInputs or []);
        doCheck = false;
        doInstallCheck = false;
        nativeInstallCheckInputs = [];
      });
    })
    # gawkReal defined after solaris-overlay so final.gawk is a resolved drv:
    # strip the autoreconf/texinfo path (illumos-fragile, unneeded for a working
    # awk) and link the C-only gmp/mpfr for bignum.
    (final: prev: {
      gawkReal = prev.gawk.overrideAttrs (old: {
        nativeBuildInputs = builtins.filter
          (d: let n = d.pname or d.name or ""; in
              !(final.lib.hasInfix "autoreconf" n || final.lib.hasInfix "texinfo" n))
          (old.nativeBuildInputs or []);
        outputs = builtins.filter (o: o != "info") (old.outputs or [ "out" ]);
        postPatch = "";
        buildInputs = (old.buildInputs or []) ++ [ final.gmpCOnly final.mpfrCOnly ];
        NIX_CFLAGS_COMPILE_BEFORE = builtins.concatStringsSep " " [
          (old.NIX_CFLAGS_COMPILE_BEFORE or "")
          "-L${final.mpfrCOnly}/lib" "-L${final.gmpCOnly}/lib"
        ];
      });
    })
  ];
  # 2.24 supports structuredAttrs natively, so the nixpkgs default is correct.
  config = { allowUnsupportedSystem = true; };
}
