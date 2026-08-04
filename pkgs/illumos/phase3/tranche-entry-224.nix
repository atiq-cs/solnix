# tranche-entry-224.nix — the Phase-3 "build real hermetic x86_64-solaris
# derivations against the pure stdenv" entry point, on Nix 2.24+.
#
# This is the 2.24 successor to tranche-entry.nix. The single substantive change
# is the DELETION of the `__structuredAttrs = false` stdenv adapter (and the
# config.structuredAttrsByDefault = false knob): Nix 2.24 writes .attrs.sh and
# exports NIX_ATTRS_SH_FILE natively, so the classic-env-var workaround the
# 2.3.16 daemon required is gone. The by-name package universe builds directly
# on the nixpkgs default — no adapter, simpler overlay. Both structured packages
# (hello) and classic ones (cc-wrapper/bintools-wrapper) build correctly on 2.24.
#
# HOST DEPENDENCY (seed stage0): the seed's GNU userland `awk` (gawk) is NEEDED
# libmpfr.so.6, which it resolves from the host runtime linker path. stdenv
# setup.sh's substituteAll/_allFlags enumerates @var@ substitutions via
# `awk 'BEGIN { for (v in ENVIRON) ... }'`; if the seed awk cannot start (missing
# libmpfr.so.6) it emits nothing, so the cc-wrapper/bintools-wrapper/version-
# check-hook setup-hooks install with UNSUBSTITUTED @wrapperName@/@suffixSalt@/
# @envCommand@ placeholders and later `source`s die with
# `export: NIX_@wrapperName@_..._@suffixSalt@ not a valid identifier`. The build
# host must provide libmpfr.so.6 (illumos: `pkg install library/mpfr`). This is
# a stage0 seed-tool host dependency (the seed ELF runs against system libs
# during bootstrap); the FINAL package closure remains host-free.
#
# The H3 fetchurlBoot shim was only needed because the structuredAttrs adapter
# re-wrapped stdenv and dropped stdenv.fetchurlBoot; with the adapter gone,
# fetchurlBoot flows through unmodified, so the "re-assert after the adapter"
# overlay is also dropped. The fetchurl-shim itself is retained solely for the
# eval-time fixed-output fetch model (network reachability), not structuredAttrs.
#
# Usage on host (Nix 2.24 store nix):
#   nix-build /root/tranche-224.nix -A <nixpkgs-attr>   # e.g. -A hello
{ system ? "x86_64-solaris"
, nixpkgs ? <nixpkgs-patched>
, illumos ? /root/solnix-pkgs/pkgs/os-specific/illumos
, fetchurlShim ? ./fetchurl-shim.nix
, solarisOverlay ? ../solaris-overlay.nix
}:
import nixpkgs {
  inherit system;
  overlays = [
    (final: prev: { solnix = final.callPackage illumos { }; illumos = final.solnix; })
    (import fetchurlShim)
    # perl fix (from the 2.3.16 tranche7 stack): drop nixpkgs' ld-shared.patch
    # (Linux-only) and add the illumos split-libc link libs, else perl fails to
    # link its shared libperl. This is a whole-stdenv wrap so every perl in the
    # graph (build-time deps of git/curl/gettext) gets it.
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
              + "-lm -lnsl -lsocket -L/nix/store/ssszbis7hnay7yqi0gb738ly1cilg3dc-illumos-seed-unpacked/usr/gnu/lib/amd64";
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
    # withGnm helper and the fragile-test packages depend on. (Same as the
    # 2.3.16 tranche7 stack; the ONLY thing dropped for 2.24 is the
    # __structuredAttrs=false adapter, not these package fixes.)
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
    # 2.24 link fix: solaris-overlay adds -lnsl/-lsocket/-lresolv to the link for
    # the socket/resolver packages. On 2.24/this fork the bootstrapLibs libnsl.so
    # + libresolv.so themselves NEED libmp.so.2 + libmd.so.1, absent from the
    # default search path, so those links fail ("symbol referencing errors" /
    # "C compiler cannot create executables"). The seed carries both at
    # usr/gnu/lib/amd64; add that -L to exactly the packages the overlay already
    # threads socket libs into (keeps the socket-free packages' hashes intact).
    (final: prev:
      let
        seedL = " -L/nix/store/ssszbis7hnay7yqi0gb738ly1cilg3dc-illumos-seed-unpacked/usr/gnu/lib/amd64";
        addSeed = drv: drv.overrideAttrs (old: {
          env = (old.env or { }) // {
            NIX_LDFLAGS = (old.env.NIX_LDFLAGS or "") + seedL;
          };
        });
      in {
        pkg-config-unwrapped = addSeed prev.pkg-config-unwrapped;
        # openssl: seed lib path + skip the test suite (its QUIC network tests
        # hit "network BIO I/O error" in the sandbox=false no-network builder and
        # grind for many minutes; the shipped library is unaffected).
        openssl = (addSeed prev.openssl).overrideAttrs (_: { doCheck = false; });
        socat = addSeed prev.socat;
        curl = addSeed prev.curl;
        wget = addSeed prev.wget;
        openssh = addSeed prev.openssh;
        rsync = addSeed prev.rsync;
        # libxcrypt (build dep of perl -> openssl/gettext/bashInteractive) links
        # its libcrypt.so with a GNU-ld version-script (-Wl,-M,./libcrypt.map)
        # that Sun ld cannot parse ("expected a '=', ':', '|', or '@'"). The
        # nixpkgs default only --disable-symvers on Cygwin; illumos needs it too.
        libxcrypt = prev.libxcrypt.overrideAttrs (old: {
          configureFlags = (old.configureFlags or []) ++ [ "--disable-symvers" ];
          doCheck = false;
        });
      })
    # gettext + perl thread socket libs at the stdenv level (perl via the
    # patchPerl wrap above; gettext-runtime's own configure), so add the seed
    # lib path to just those two here rather than globally.
    (final: prev: {
      gettext = prev.gettext.overrideAttrs (old: {
        env = (old.env or { }) // {
          NIX_LDFLAGS = (old.env.NIX_LDFLAGS or "")
            + " -L/nix/store/ssszbis7hnay7yqi0gb738ly1cilg3dc-illumos-seed-unpacked/usr/gnu/lib/amd64"
            # gettext-runtime auto-detects the Solaris ACL/nvpair lib pile
            # (-luutil -lnvpair -lidmap -lavl -lsec) but the seed only ships them
            # as versioned .so.N. /lib/64 carries the unversioned linkable .so
            # (illumos base system libs, libc-family; runtime resolves from
            # /lib/64 like libc.so.1, so the closure stays store-only).
            + " -L/lib/64";
        };
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
  # 2.24 supports structuredAttrs natively, so the nixpkgs default is correct and
  # requires no adapter. (structuredAttrsByDefault is left unset.)
  config = { allowUnsupportedSystem = true; };
}
