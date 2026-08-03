# tranche-entry.nix — the Phase-3 "build real hermetic derivations against the
# pure x86_64-solaris stdenv" entry point.
#
# This is the working composition proven in the first tranche (zlib, bzip2, xz,
# file, gnugrep, gnused, coreutils, pcre2 — all built as real .drv-backed,
# deriver-resolving, /nix/store-only-closure derivations and published to
# cache.solnix.io). See ./README.md for the blocker families and the per-fix
# rationale.
#
# On the OI build host this lives at /root/tranche2.nix with these path
# substitutions (the host has no repo checkout, only the rsynced fork):
#   PATCHED   = /nix/store/p3lfwcvh0vz6xc8wc1yhj2f8rg1flnb9-nixpkgs-patched
#   ILLUMOS   = /root/solnix-pkgs/pkgs/os-specific/illumos
#   SHIM      = ./fetchurl-shim.nix   (rsynced to /root/fetchurl-shim.nix)
#   OVERLAY   = ../solaris-overlay.nix (rsynced to /root/solaris-overlay.nix)
#
# Usage on host:
#   nix-build /root/tranche2.nix -A <nixpkgs-attr>   # e.g. -A zlib
{ system ? "x86_64-solaris"
, nixpkgs ? /nix/store/p3lfwcvh0vz6xc8wc1yhj2f8rg1flnb9-nixpkgs-patched
, illumos ? /root/solnix-pkgs/pkgs/os-specific/illumos
, fetchurlShim ? ./fetchurl-shim.nix
, solarisOverlay ? ../solaris-overlay.nix
}:
import nixpkgs {
  inherit system;
  overlays = [
    (final: prev: { solnix = final.callPackage illumos { }; illumos = final.solnix; })
    (import fetchurlShim)
    # Nix 2.3.16 has NO __structuredAttrs support: it never writes the .attrs.sh
    # file, so NIX_ATTRS_SH_FILE is empty at build time, $stdenv is never set,
    # and source-stdenv.sh's `source $stdenv/setup` fails with `/setup: No such
    # file`. The stdenv-illumos was baked with structuredAttrs-by-default ON, so
    # config.structuredAttrsByDefault in THIS import can't turn it off. Wrap the
    # stdenv with an adapter that forces __structuredAttrs = false on every
    # derivation, reverting to the classic env-var builder the old daemon
    # handles. This is the single fix that unblocks all by-name packages.
    (final: prev: {
      stdenv = prev.stdenvAdapters.addAttrsToDerivation { __structuredAttrs = false; } prev.stdenv;
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
    (import solarisOverlay)
  ];
  config = { allowUnsupportedSystem = true; structuredAttrsByDefault = false; };
}
