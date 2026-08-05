# by-name-flake/pkgs.nix — thin adapter: import the repo's tranche-entry-224.nix
# (the single source of truth for the illumos package overlay) with the fork,
# gnu-config FODs, illumos overlay + shim/overlay files supplied as flake
# inputs. No package logic lives here; this only threads pure inputs into the
# existing tranche entry point so eval needs no --impure.
{ system ? "x86_64-solaris"
, nixpkgs
, forkPath
, illumos
, phase3        # dir holding tranche-entry-224.nix + the shim/overlay
, gnuConfigGuess
, gnuConfigSub
}:
import (phase3 + "/tranche-entry-224.nix") {
  inherit system nixpkgs forkPath illumos gnuConfigGuess gnuConfigSub;
  fetchurlShim = phase3 + "/fetchurl-shim-qmvlnvf0.nix";
  solarisOverlay = phase3 + "/solaris-overlay-qmvlnvf0.nix";
}
