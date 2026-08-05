# by-name-flake/flake.nix — the PURE `nix profile install nixpkgs#<pkg>` entry
# point baked into solnix images.
#
# WHY THIS EXISTS. The image ships a `solnix-flake` whose `pkgs.nix` used to do
# `builtins.storePath /nix/store/<hash>-nixpkgs-patched` (plus mirrors.nix and
# the gnu-config FODs). `builtins.storePath` — and, on Nix 2.24, ANY absolute
# `/nix/store/...` path literal — is forbidden in pure evaluation, so every
# by-name install needed `--impure`. Flake INPUTS are the only pure way to name
# a store path: a `flake = false` path input is recorded in flake.lock by
# narHash and referenced through the input arg, never as a bare absolute path.
# So `nix profile install nixpkgs#hello` (no --impure) evaluates and installs.
#
# The three out-of-tree store paths the package set needs become inputs:
#   fork        — the patched nixpkgs source (x86_64-solaris stdenv + overlay)
#   configGuess — gnu-config config.guess FOD (autotools hook, savannah-404)
#   configSub   — gnu-config config.sub  FOD
# The package overlay itself is the repo's tranche-entry-224.nix (single source
# of truth for the H1-H38 illumos fixes); this flake just feeds it inputs
# instead of the absolute-path defaults the classic `nix-build` path uses.
#
# BAKING (for the AMI): oi-make-declarative-be.sh copies this dir + its
# flake.lock into the image, `nix flake archive`s the three inputs into the
# image /nix/store as GC roots, and points the flakes registry `nixpkgs` at it.
# The lock pins the fork by narHash, so the baked image evaluates offline/pure.
{
  description = "solnix by-name package set (pure: nix profile install nixpkgs#<pkg>)";

  inputs = {
    # The patched nixpkgs fork (x86_64-solaris). flake = false: consumed as a
    # source tree, not a flake. The absolute path is the store path the fork
    # currently occupies; flake.lock pins it by narHash so eval is pure.
    fork = {
      url = "path:/nix/store/qmvlnvf0kk1zkfjpjpxwimg5ym8sfwnk-nixpkgs-patched-1785781297346528064";
      flake = false;
    };
    # gnu-config FODs (content-addressed; identical hash regardless of source).
    configGuess = {
      url = "path:/nix/store/vq0j27nvpks679djbiykl8ikdyj6z5a9-config.guess-948ae97";
      flake = false;
    };
    configSub = {
      url = "path:/nix/store/1p61qjvlqmwrqab3zp5yh3z8rf3mvjmz-config.sub-948ae97";
      flake = false;
    };
    # The illumos package overlay + the tranche stack live in the solnix-pkgs
    # fork tree (same repo the fork was cut from). flake = false: imported as a
    # source path. The tranche entry point (pkgs.nix here) callPackage's the
    # illumos dir out of it.
    solnixPkgs = {
      url = "path:/root/solnix-pkgs";
      flake = false;
    };
  };

  outputs =
    { self, fork, configGuess, configSub, solnixPkgs }:
    let
      system = "x86_64-solaris";
      pkgs = import ./pkgs.nix {
        inherit system;
        nixpkgs = fork;
        forkPath = fork;
        illumos = solnixPkgs + "/pkgs/os-specific/illumos";
        phase3 = solnixPkgs + "/pkgs/os-specific/illumos/phase3";
        gnuConfigGuess = configGuess;
        gnuConfigSub = configSub;
      };
    in
    {
      # `nix profile install nixpkgs#<pkg>` resolves legacyPackages.<system>.<pkg>
      # once the flakes registry maps nixpkgs -> this flake.
      legacyPackages.${system} = pkgs;
    };
}
