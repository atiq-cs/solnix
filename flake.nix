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
        overlays = [ solnix-pkgs.overlays.default worldOverlay ];
      };

      # worldOverlay — layer THIS REPO's pkgs/illumos onto pkgs.solnix.
      #
      # WARNING: WITHOUT THIS NO TOPLEVEL CAN EVALUATE, and that was the state of
      # the repo. modules/system/activation/default.nix:428 reads
      # pkgs.solnix.systemPath, but solnix-pkgs' overlay supplies only the
      # BOOTSTRAP half of pkgs.solnix (seed, cc, bintools, libc, libcFromSource,
      # aarch64Cross). systemPath, gate, base-tools, starter and the six proto
      # slices are defined HERE, in pkgs/illumos/default.nix, and were never wired
      # into the overlay at all -- so
      #   nix eval .#solnixConfigurations.<any>.config.system.build.toplevel.drvPath
      # failed with `attribute 'systemPath' missing` for base, pgfarm AND dixi
      # alike. That is why the slices could build standalone while a toplevel
      # referencing them could not, and why no toplevel here has ever been built.
      #
      # WARNING: THE GATE IS A HOST ARTIFACT, which is why it is an argument.
      # pkgs/illumos/gate.nix asserts srcDir or srcHash (an unpinned network fetch
      # is not reproducible), and the real proto is a 491 MB tree that exists only
      # on an illumos build host. So:
      #   * SOLNIX_GATE_PROTO=/var/tmp/proto-unpack/<hash>-illumos-gate-proto
      #     points at an already-built proto (what the illumos host does);
      #   * unset, gate stays null and gate.nix's own assertion throws WHEN FORCED,
      #     rather than yielding a silently empty world.
      # Forcing the toplevel's drvPath therefore needs the env var; reading cheap
      # attrs (hostName, roles) does not, because Nix is lazy -- which is exactly
      # how this bug hid. `builtins.attrNames` on the world lists all 21 attrs
      # without forcing one of them.
      #
      # This makes the flake/host EVAL-SPLIT explicit instead of implicit: the host
      # path (lib/eval-host.nix -> lib/host-pkgs.nix) already did precisely this via
      # `import solnixDir`, which is why toplevels evaluated there and only there.
      worldOverlay = _final: prev: {
        solnix = prev.solnix // (import ./pkgs/illumos (
          let p = builtins.getEnv "SOLNIX_GATE_PROTO";
          in if p == "" then { } else { gate = builtins.storePath p; }
        ));
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

        # The PostgreSQL build-farm animal + dev host role (base + pgfarm).
        # This is what an installer selects for that machine.
        pgfarm = solnixSystem {
          system = "x86_64-solaris";
          pkgs = pkgsFor "x86_64-solaris";
          modules = [ ./configurations/pgfarm.nix ];
        };

        # The maintainer's x86_64 workstation -- the target of
        # `solnix-install --flake .#dixi`. See configurations/dixi.nix.
        #
        # ⚠️ configurations/dixi.nix deliberately sets NO system.stateVersion and NO
        # solnix.home.style: neither option exists in this module set, and setting an
        # undefined option is an eval error. Do not add them here either without first
        # declaring the option in modules/config/.
        dixi = solnixSystem {
          system = "x86_64-solaris";
          pkgs = pkgsFor "x86_64-solaris";
          modules = [ ./configurations/dixi.nix ];
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
        pgfarmToplevel = self.solnixConfigurations.pgfarm.config.system.build.toplevel;
        # dixi: the maintainer's workstation. Same eval-split caveat as the others --
        # this EVALUATES here and only BUILDS on the illumos host, because the gate
        # proto and the slices carved from it are x86_64-solaris derivations.
        dixiToplevel = self.solnixConfigurations.dixi.config.system.build.toplevel;

        # The pgfarm role's generated artifacts ALONE (build-farm.conf, the
        # run_build.pl driver, the setup oneshot). These are plain text/script
        # derivations with no dependency on the illumos gate proto, so they
        # realise on any host — which is what makes the animal's acceptance test
        # (a real run_build.pl run) runnable without first building a whole
        # bootable world.
        pgfarmConf = self.solnixConfigurations.pgfarm.config.solnix.pgfarm.buildFarmConf;
        pgfarmRun = self.solnixConfigurations.pgfarm.config.solnix.pgfarm.runBuild;
        pgfarmSetup = self.solnixConfigurations.pgfarm.config.solnix.pgfarm.setup;
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
