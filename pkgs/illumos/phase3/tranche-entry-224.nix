# tranche-entry-224.nix — the Phase-3 "build real hermetic x86_64-solaris
# derivations against the pure stdenv" entry point, on Nix 2.24+.
#
# This is the 2.24 successor to tranche-entry.nix. The single substantive change
# is the DELETION of the `__structuredAttrs = false` stdenv adapter (and the
# config.structuredAttrsByDefault = false knob): Nix 2.24 writes .attrs.sh and
# exports NIX_ATTRS_SH_FILE natively, so the classic-env-var workaround the
# 2.3.16 daemon required is gone. The by-name package universe builds directly on
# structuredAttrs, which is the nixpkgs default — no adapter, simpler overlay.
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
    # bashNonInteractive lost its shellPath passthru (lowPrio + spliced pkgset),
    # so runtimeShell = bash + bash.shellPath throws. Restore shellPath and pin
    # runtimeShell/runtimeShellPackage to plain bash so packages that read
    # runtimeShell in configureFlags evaluate.
    (final: prev: {
      bashNonInteractive = prev.bashNonInteractive // { shellPath = "/bin/bash"; };
      runtimeShellPackage = prev.bash;
      runtimeShell = "${prev.bash}/bin/bash";
    })
    (import solarisOverlay)
  ];
  # No structuredAttrsByDefault override: 2.24 supports structuredAttrs natively,
  # so the nixpkgs default (structured) is correct and requires no adapter.
  config = { allowUnsupportedSystem = true; };
}
