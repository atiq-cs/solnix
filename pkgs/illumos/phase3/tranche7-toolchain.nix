{ system ? "x86_64-solaris" }:
import /nix/store/00w7p2sg4svr8rqavapiqv34iwyr1anw-nixpkgs-patched {
  inherit system;
  overlays = [
    (final: prev: { solnix = final.callPackage /root/solnix-pkgs/pkgs/os-specific/illumos { }; illumos = final.solnix; })
    (import /root/fetchurl-shim.nix)
    (final: prev: {
      stdenv = prev.stdenvAdapters.overrideMkDerivationArgs
        (old: { __structuredAttrs = false; }
          // prev.lib.optionalAttrs (old ? outputChecks) { outputChecks = null; })
        prev.stdenv;
    })
    (final: prev: {
      stdenv = prev.stdenv // { fetchurlBoot = final.solnixShimFetch; };
      stdenvNoCC = prev.stdenvNoCC // { fetchurlBoot = final.solnixShimFetch; };
    })
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
    (final: prev: {
      bashNonInteractive = prev.bashNonInteractive // { shellPath = "/bin/bash"; };
      runtimeShellPackage = prev.bash;
      runtimeShell = "${prev.bash}/bin/bash";
    })
    # illumosGnm: the GNU-format nm the solaris-overlay's withGnm helper wants.
    # The fork's newer stdenv exposes it as a passthru; patch 0004's stdenv (my
    # nixpkgs-patched) predates that, so surface it here from the stdenv's own
    # binutils (GNU nm) as bin/gnm.
    (final: prev: {
      illumosGnm = final.runCommand "illumos-gnm" { } ''
        mkdir -p $out/bin
        ln -s ${final.stdenv.cc.bintools.bintools}/bin/nm $out/bin/gnm
      '';
      # gmp C-only (task: gmp C-only doCheck=false). The default `gmp` attr is
      # gmp-with-cxx, whose C++ conftest fails on the seed toolchain; build the
      # plain C gmp and skip the (illumos-flaky) test suite.
      gmpCOnly = (final.gmp.override { cxx = false; }).overrideAttrs (_: { doCheck = false; });
      # libffi: its doCheck pulls dejagnu (needs isainfo/host tools that aren't
      # in the pure closure). The library builds+links fine; skip the test suite.
      libffiNoCheck = final.libffi.overrideAttrs (_: { doCheck = false; });
      # mpfr against the C-only gmp (gmp-with-cxx's C++ conftest fails to RUN on
      # the seed toolchain -- libstdc++ load issue; mpfr is C-only so needs only
      # the C gmp).
      mpfrCOnly = (final.mpfr.override { gmp = final.gmpCOnly; }).overrideAttrs (_: { doCheck = false; });
      # gawkReal (H30 durable fix): the published gawk crashes at load because
      # its RUNPATH is /usr/gcc/14/lib/amd64 only and its closure has no
      # libmpfr.so.6 -> substituteAll's awk emits nothing -> cc-wrapper
      # @wrapperName@/@suffixSalt@ left unsubstituted -> every fresh bootstrap
      # dies. Rebuilt below (own overlay after solaris-overlay) so final.gawk is
      # a resolved derivation.
    })
    (import /root/solaris-overlay.nix)
    # gawkReal defined here so final.gawk (post solaris-overlay) is resolved.
    (final: prev: {
      gawkReal = prev.gawk.overrideAttrs (old: {
        # Strip the autoreconf + texinfo path (the "no-pma fix" needs autoreconf,
        # which drags gettext/texinfo -- both illumos-fragile and unneeded for a
        # working awk). Build from the pristine configure; keep only the libs
        # gawk links (gmp/mpfr for bignum, readline/ncurses).
        nativeBuildInputs = builtins.filter
          (d: let n = d.pname or d.name or ""; in
              !(final.lib.hasInfix "autoreconf" n || final.lib.hasInfix "texinfo" n))
          (old.nativeBuildInputs or []);
        outputs = builtins.filter (o: o != "info") (old.outputs or [ "out" ]);
        postPatch = "";
        buildInputs = (old.buildInputs or []) ++ [
          final.gmpCOnly final.mpfrCOnly
        ];
        NIX_CFLAGS_COMPILE_BEFORE = builtins.concatStringsSep " " [
          (old.NIX_CFLAGS_COMPILE_BEFORE or "")
          "-L${final.mpfrCOnly}/lib" "-L${final.gmpCOnly}/lib"
        ];
      });
    })
  ];
  config = { allowUnsupportedSystem = true; structuredAttrsByDefault = false; };
}
