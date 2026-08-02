{
  description = "solnix — a Nix distribution of illumos (illumos analog of nixbsd)";

  inputs = {
    # The solnix nixpkgs fork: pins nixpkgs 7f81d69 + applyPatches (x86_64-solaris
    # stdenv wiring) + overlays.default exposing pkgs.illumos.*. See
    # docs/design-nixpkgs-illumos.md §5. This is the flake-native path (dev boxes
    # with flake-capable Nix). The BUILD path (illumos host, Nix 2.3.16 classic,
    # no flakes) uses lib/eval-host.nix — see the eval-split note below.
    solnix-pkgs.url = "git+file:///home/gburd/ws/solnix-pkgs";
  };

  outputs =
    { self, solnix-pkgs, ... }:
    let
      # nixpkgs lib comes from the fork's patched source (carries x86_64-solaris).
      nixpkgs = solnix-pkgs.lib.nixpkgsSrc;
      lib = import "${nixpkgs}/lib";

      # The canonical Nix system for illumos is x86_64-solaris (GNU triple
      # x86_64-unknown-solaris2.11); "illumos" is branding at the attribute layer.
      # See docs/design-nixpkgs-illumos.md §1.
      solnixSystems = [ "x86_64-solaris" ];

      # The systems a solnix image can be *built from*. Native illumos building
      # (the only place pkgs.illumos.* realise) is the host; cross-from-Linux is
      # roadmap T1.6.
      buildSystems = [ "x86_64-linux" ];

      # solnixSystem: the nixosSystem analog. Thin wrapper over lib/eval-config.nix
      # (a fork of NixOS's nixos/lib/eval-config.nix). Kept out here so both the
      # flake and out-of-tree callers use one entrypoint.
      solnixSystem = import ./lib/eval-config.nix { inherit lib; };

      # pkgs for a solnix system: the pinned nixpkgs instantiated for
      # x86_64-solaris with the fork's illumos overlay (exposes pkgs.illumos.*).
      pkgsFor = system: import nixpkgs {
        inherit system;
        overlays = [ solnix-pkgs.overlays.default cachedOverlay ];
      };

      # cachedOverlay — layer the wave-built cache index onto pkgs.solnix so a
      # config can reference `pkgs.solnix.cached.<pname>` (store paths that
      # substitute from cache.solnix.io at realise time). Only `cached` is added
      # here: the rest of the gate-derived world (gate/libc/systemPath/...) is a
      # host-local builtins.path proto that does not exist on the build system,
      # so it stays in the host eval path (lib/eval-host.nix). cached.nix is pure
      # (reads the manifest + builtins.storePath), so it evaluates anywhere.
      cachedOverlay = _final: prev: {
        solnix = prev.solnix // {
          cached = import ./pkgs/illumos/cached.nix { system = "x86_64-solaris"; };
        };
      };
    in
    {
      # lib.solnixSystem — build a solnix system from modules. Analog of
      # nixpkgs' lib.nixosSystem.
      lib = { inherit solnixSystem; };

      # solnixConfigurations.<name> — the nixosConfigurations analog.
      #
      # EVAL-SPLIT (docs/design-make-be.md §7): this flake output EVALUATES the
      # system on a flake-capable Nix. It targets x86_64-solaris, so
      # config.system.build.* are x86_64-solaris derivations that only BUILD on
      # the illumos host. On the host (classic Nix 2.3.16, no flakes, no nixpkgs)
      # use lib/eval-host.nix instead — it imports a copied nixpkgs lib + the
      # standalone pkgs/illumos slices and produces the SAME toplevel there, where
      # it can be realised. Both entrypoints share lib/eval-config.nix + the
      # module tree; the split is only about WHERE eval vs build happen.
      solnixConfigurations = {
        base = solnixSystem {
          system = "x86_64-solaris";
          pkgs = pkgsFor "x86_64-solaris";
          modules = [ ./configurations/base.nix ];
        };
      };

      # Per-build-system image packages. The image builder (lib/make-be.nix)
      # emits a root-run assembly SCRIPT (the privileged ZFS/loader steps can't
      # run in a Nix sandbox — see lib/make-be.nix header + design-make-be.md §7),
      # so what we expose here is that script + the toplevel it consumes. Realise
      # on the illumos host; run the script as root against a scratch disk.
      packages = lib.genAttrs buildSystems (_buildSystem: {
        # the full system closure (T2.8); realise on the illumos host.
        baseToplevel = self.solnixConfigurations.base.config.system.build.toplevel;
      });

      # devShells: the build/ops toolchain used to DRIVE solnix builds from a
      # flake-capable host (this is what `.envrc`'s `use flake` loads). Not the
      # target userland (that's x86_64-solaris) — just host-side tools: nix,
      # git, plus the cache publish/verify deps (sops, awscli2) and ISO tooling.
      devShells = lib.genAttrs buildSystems (buildSystem:
        let pkgs = pkgsFor buildSystem; in {
          default = pkgs.mkShellNoCC {
            packages = with pkgs; [ git sops age awscli2 xorriso jq curl ];
            shellHook = ''
              echo "solnix dev shell — build/ops tooling (target userland is x86_64-solaris)."
            '';
          };
        });
    };
}
