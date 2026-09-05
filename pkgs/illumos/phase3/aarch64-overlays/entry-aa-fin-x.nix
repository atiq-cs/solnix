# aarch64 CROSS entry, 2.24 — reuses the WORKING native x86_64-solaris overlay
# stack from tranche-224.nix (imported verbatim) applied as regular `overlays`
# (so the native buildPackages that cross build-tools need is exactly the proven
# tranche-224 stdenv), then adds ONE crossOverlay: swap the cross target stdenv's
# cc for the seed aarch64 cross cc-wrapper. No structuredAttrs adapter (2.24
# native). buildPackages = native x86_64-solaris (proven), target = aarch64.
{ nixpkgs ? /nix/store/qmvlnvf0kk1zkfjpjpxwimg5ym8sfwnk-nixpkgs-patched-1785781297346528064
, illumos ? /root/solnix-pkgs/pkgs/os-specific/illumos
, fetchurlShim ? /root/fetchurl-shim.nix
, solarisOverlay ? /root/solaris-overlay.nix
, extraCrossOverlays ? [ ]
, extraNativeOverlays ? [ ]
}:
let
  lib = (import nixpkgs { system = "x86_64-solaris"; config = { allowUnsupportedSystem = true; }; }).lib;

  # the tranche-224 native overlay stack (the parts foundational libs need).
  baseOverlays = [
    # The illumos native stdenv's genericStdenv call omits `extraNativeBuildInputs`,
    # so it is absent from the stdenv's override arg set. The cross framework does
    # `buildPackages.stdenv.override (old: rec { extraNativeBuildInputs =
    # old.extraNativeBuildInputs ++ ...})` and throws "attribute
    # 'extraNativeBuildInputs' missing". Seed it (default []) so the arg set
    # carries it and the cross construction composes.
    (final: prev: {
      stdenv = prev.stdenv.override (old: { extraNativeBuildInputs = old.extraNativeBuildInputs or [ ]; });
    })
    (final: prev: { solnix = final.callPackage illumos { }; illumos = final.solnix; })
    (import fetchurlShim)
    (final: prev: {
      stdenv = prev.stdenv // { fetchurlBoot = final.solnixShimFetch; };
      stdenvNoCC = prev.stdenvNoCC // { fetchurlBoot = final.solnixShimFetch; };
    })
    # perl wrap (drop Linux ld-shared.patch, add split-libc link libs)
    (final: prev:
      let
        fixPerlAttrs = a:
          if (a.pname or "") == "perl"
          then a // {
            patches = builtins.filter (p: baseNameOf (toString p) != "ld-shared.patch") (a.patches or []);
            NIX_LDFLAGS = (if a ? NIX_LDFLAGS then a.NIX_LDFLAGS + " " else "") + "-lm -lnsl -lsocket -L/nix/store/ylyfkm6xwp60gg8yqcpj4g481l1fm1qq-illumos-extra-syslibs/lib/amd64 -lmd -lmp";
          } else a;
        patchPerl = stdenv: stdenv // {
          mkDerivation = args:
            if builtins.isFunction args
            then stdenv.mkDerivation (finalAttrs: fixPerlAttrs (args finalAttrs))
            else stdenv.mkDerivation (fixPerlAttrs args);
        };
      in { stdenv = patchPerl prev.stdenv; })
    (final: prev: {
      bashNonInteractive = prev.bashNonInteractive // { shellPath = "/bin/bash"; };
      runtimeShellPackage = prev.bash;
      runtimeShell = "${prev.bash}/bin/bash";
    })
    (final: prev: {
      illumosGnm = final.runCommand "illumos-gnm" { } ''
        mkdir -p $out/bin
        ln -s ${final.stdenv.cc.bintools.bintools}/bin/nm $out/bin/gnm
      '';
      gmpCOnly = (final.gmp.override { cxx = false; }).overrideAttrs (_: { doCheck = false; });
      libffiNoCheck = final.libffi.overrideAttrs (_: { doCheck = false; });
      mpfrCOnly = (final.mpfr.override { gmp = final.gmpCOnly; }).overrideAttrs (_: { doCheck = false; });
    })
    # cross-set pre-fix: solaris-overlay does `(old.postPatch or "") + gnulibFix`,
    # but gnugrep/gnused/... have postPatch = null (present, not absent) in the
    # cross set -> `or ""` yields null -> null + str throws. Pre-set to "" so
    # solaris-overlay's append sees a string. Runs BEFORE solaris-overlay.
    (final: prev:
      let fix = name: { ${name} = prev.${name}.overrideAttrs (old:
            { postPatch = if (old.postPatch or null) == null then "" else old.postPatch; }); };
      in fix "gnugrep" // fix "gnused" // fix "gawk" // fix "diffutils" // fix "coreutils")
    (import solarisOverlay)
  ];

  # crossOverlay: swap the cross target stdenv cc for the seed aarch64 cross cc.
  # extraNativeBuildInputs = [] mirrors the gate hello entry (config.sub already
  # knows aarch64-unknown-solaris2.11, so no gnu-config refresh needed).
  #
  # cxxNomapCc (docs/aarch64-cxx-wall-fix.md): the seed cross gcc's built-in
  # *link: spec emits `-M %slibgcc-unwind.map` (Solaris link-editor mapfile) for
  # every SHARED / shared-libgcc / C++ link, but collect2 execs the GNU ld (the
  # only aarch64-capable linker), which reads the Solaris mapfile as a GNU
  # linker script and dies "file format not recognized / syntax error". Bake a
  # -specs= file onto the cross cc-wrapper cc-cflags that overrides *link: with
  # the same spec minus the two -M %s..map clauses (the mapfiles only restrict
  # libgcc-unwinder symbol visibility; dropping them is harmless). Every cross
  # shared/C++ link then links; C-only static links are byte-identical.
  cxxNomapCc = cc: cc.override (_: {
    extraBuildCommands = (cc.extraBuildCommands or "") + ''
      cat > $out/nix-support/nomap.specs <<'SPECS'
      *link:
      %{h*} %{v:-V}    %{!shared:%{!static:%{!G:%{rdynamic: }}}}    %{static:-dn -Bstatic}    %{shared|G:-G -dy %{!mimpure-text:-z text}}    %{symbolic:-Bsymbolic -G -dy -z text}    %(link_arch)    %{Qy:} %{!Qn:-Qy}

      SPECS
      echo "-specs=$out/nix-support/nomap.specs" >> $out/nix-support/cc-cflags
    '';
  });

  aarch64CcSwap = _final: prev: {
    stdenv = prev.stdenv.override (_old: {
      cc = cxxNomapCc prev.solnix.aarch64Cross.cc;
      extraNativeBuildInputs = [ ];
    });
  };
in import nixpkgs {
  localSystem = "x86_64-solaris";
  crossSystem = (import "${nixpkgs}/lib/systems/examples.nix" { inherit lib; }).aarch64-illumos;
  overlays = baseOverlays ++ extraNativeOverlays;
  crossOverlays = [ aarch64CcSwap ] ++ extraCrossOverlays;
  config = { allowUnsupportedSystem = true; };
}
