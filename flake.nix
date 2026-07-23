{
  description = "solnix — a Nix distribution of illumos (illumos analog of nixbsd)";

  inputs = {
    # ponytail: for now this points at plain upstream nixpkgs so the flake parses
    # and lib.evalModules is reachable. Phase 1 (T1.1) swaps this to the solnix
    # nixpkgs fork branch that carries the x86_64-solaris pure stdenv +
    # pkgs.illumos.* world (see docs/design-nixpkgs-illumos.md §5). Repin here and
    # in .kiro/steering/nix-conventions.md when the fork branch exists.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;

      # The canonical Nix system for illumos is x86_64-solaris (GNU triple
      # x86_64-unknown-solaris2.11); "illumos" is branding at the attribute layer.
      # See docs/design-nixpkgs-illumos.md §1.
      solnixSystems = [ "x86_64-solaris" ];

      # The systems a solnix image can be *built from* (cross from Linux, T1.6).
      # Native illumos building is added once the fork's stdenv is green.
      buildSystems = [ "x86_64-linux" ];

      # solnixSystem: the nixosSystem analog. Thin wrapper over lib/eval-config.nix
      # (a fork of NixOS's nixos/lib/eval-config.nix). Kept out here so both the
      # flake and out-of-tree callers use one entrypoint.
      solnixSystem = import ./lib/eval-config.nix { inherit lib; };
    in
    {
      # lib.solnixSystem — build a solnix system from modules. Analog of
      # nixpkgs' lib.nixosSystem.
      lib = { inherit solnixSystem; };

      # solnixConfigurations.<name> — the nixosConfigurations analog. These do NOT
      # evaluate yet: they need the nixpkgs fork (pkgs.illumos.*) and the seed
      # toolchain, neither of which exists. Wired now so the shape is fixed and
      # `configurations/` has a home.
      solnixConfigurations = {
        base = solnixSystem {
          system = "x86_64-solaris";
          modules = [ ./configurations/base.nix ];
        };
      };

      # Per-build-system image packages. Stubbed: the image builders
      # (lib/make-be.nix, lib/make-disk-image.nix — roadmap P1.5) do not exist yet,
      # so we expose nothing buildable rather than fake a derivation.
      # ponytail: add real image outputs when make-be.nix lands (P1.5). Until then
      # this is intentionally empty — no speculative packages.
      packages = lib.genAttrs buildSystems (_buildSystem: {
        # TODO(P1.5): baseImage = self.solnixConfigurations.base.config.system.build.image;
      });
    };
}
