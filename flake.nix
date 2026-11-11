{
  description = "solnix — a Nix distribution of illumos (illumos analog of nixbsd)";

  inputs = {
    # The solnix nixpkgs fork: pins nixpkgs 7f81d69 + applyPatches (x86_64-solaris
    # stdenv wiring) + overlays.default exposing pkgs.illumos.*. See
    # docs/design-nixpkgs-illumos.md §5. This is the flake-native path (dev boxes
    # with flake-capable Nix). The BUILD path (illumos host, Nix 2.3.16 classic,
    # no flakes) uses lib/eval-host.nix — see the eval-split note below.
    # shallow=0: Nix fetches flake inputs as shallow clones (git fetch --depth 1), and
    # git.solnix.io serves dumb HTTP, which cannot ("dumb http transport does not support
    # shallow capabilities"). Without it every machine whose store lacks this input
    # fails with "Cannot find Git revision ... in ref 'main'" (measured: stock Nix 2.35
    # and 2.24 into an empty store). A full clone is ~1 MB.
    solnix-pkgs.url = "git+https://git.solnix.io/solnix-pkgs.git?ref=main&shallow=0";
    # Plain UPSTREAM nixpkgs, for the host-ops devShell ONLY. The fork's patched
    # nixpkgs (solnix-pkgs.lib.nixpkgsSrc) rebuilds bison/perl/etc. from source
    # (no binary cache for the applyPatches tree), which made `cd` into the repo
    # recompile a toolchain on every cold direnv eval. Host tools (git/sops/
    # awscli2/xorriso) come from this cached upstream pin instead.
    nixpkgs-host.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, solnix-pkgs, nixpkgs-host, ... }:
    let
      # nixpkgs lib comes from the fork's patched source (carries x86_64-solaris).
      nixpkgs = solnix-pkgs.lib.nixpkgsSrc;
      # lib for EVALUATING solnix systems: the pinned nixpkgs source itself, not
      # solnix-pkgs' patched copy. That copy is an x86_64-linux applyPatches
      # derivation, so importing from it is import-from-derivation: measured on
      # illumos, `nix eval .#solnixConfigurations.<x>...drvPath` died with "a
      # 'x86_64-linux' is required to build ...-nixpkgs-solnix-patched.drv", and
      # its output is in no cache. The patches touch lib/systems (the *-solaris
      # platforms), which nothing here reads: system = "x86_64-solaris" is a
      # plain string. NixOS evaluates a system without IFD; so does this.
      lib = import "${solnix-pkgs.inputs.nixpkgs}/lib";

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
      # The revision is passed in as nixpkgs' flake sets system.nixos.revision: the
      # flake's source copy has no .git for modules/config/release.nix to read.
      solnixSystem = args: import ./lib/eval-config.nix { inherit lib; } (args // {
        modules = (args.modules or [ ]) ++ [
          { solnix.revision = lib.mkDefault (self.rev or self.dirtyRev or null); }
        ];
      });

      # pkgs for a solnix system: the pinned nixpkgs instantiated for
      # x86_64-solaris with the fork's illumos overlay (exposes pkgs.illumos.*).
      pkgsFor = system: import nixpkgs {
        inherit system;
        overlays = [ solnix-pkgs.overlays.default shellPathOverlay worldOverlay ];
      };

      # mkPkgs: the pkgs a solnix SYSTEM is evaluated with -- lib/host-pkgs.nix,
      # the same shim the illumos host's lib/eval-host.nix uses: pkgs.solnix.* from
      # this repo's pkgs/illumos plus plain-derivation writers. Not pkgsFor: the
      # nixpkgs writers there are built with nixpkgs' x86_64-solaris stdenv, so every
      # toplevel dragged ~200 bootstrap derivations (perl, bison, texinfo, bash 5.3,
      # libxml2 2.15 ...) that are in no cache and that the installer media cannot
      # build. With the shim, a flake eval and a host eval give the SAME toplevel
      # derivation, so what bhost built is what an install substitutes or reuses.
      # The gate proto comes from gate.nix's own pinned, named fetch (pure-legal).
      mkPkgs = { system ? "x86_64-solaris" }: import ./lib/host-pkgs.nix { inherit system; };

      # shellPathOverlay — restore bashNonInteractive.shellPath on x86_64-solaris.
      #
      # On the fork's pinned nixpkgs, bashNonInteractive loses its shellPath
      # passthru (lowPrio + the spliced package set), so nixpkgs'
      #   runtimeShell = "${runtimeShellPackage}${runtimeShellPackage.shellPath}"
      # throws "attribute 'shellPath' missing" the moment ANY trivial-builder
      # (runCommand/writeShellScript — used by systemPath/activation) is forced.
      # The phase3 tranche entry already carries this exact fix; the flake's
      # pkgsFor was missing it, which blocked the toplevel at eval. Restore
      # shellPath and pin runtimeShell to plain bash (matches
      # solnix-pkgs .../phase3/tranche-224-node-FIXED.nix).
      shellPathOverlay = _final: prev: {
        bashNonInteractive = prev.bashNonInteractive // { shellPath = "/bin/bash"; };
        runtimeShellPackage = prev.bash;
        runtimeShell = "${prev.bash}/bin/bash";
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
      #
      # lib.overlays — the overlays a toplevel needs, exported so an EXTERNAL
      # consumer (nix-config's mkSolnixHost) that builds its own pkgs set can
      # apply the SAME layers this flake's pkgsFor does. Without worldOverlay
      # `pkgs.solnix.systemPath` is missing (activation/default.nix:428) and the
      # toplevel throws `attribute 'systemPath' missing`; without shellPathOverlay
      # runtimeShell throws `attribute 'shellPath' missing`. A consumer applying
      # only solnix-pkgs.overlays.default (the bootstrap half) hits both — which is
      # why `solnix-install --flake .#dixi` failed against nix-config: it built
      # pkgs its own way and inherited neither. Single source of truth here.
      # mkPkgs + solnixSystem are what an external flake (nix-config's mkSolnixHost)
      # should use: solnixSystem { pkgs = solnix.lib.mkPkgs { }; modules = [...]; }.
      # The overlays stay exported for consumers that build nixpkgs packages for
      # x86_64-solaris (home-manager), which is a separate, cache-dependent path.
      # nixpkgs' lib plus solnix's own. On a solnix system the `nixpkgs` registry
      # name resolves to THIS flake (modules/config/nix-channel.nix, as NixOS points
      # it at the system's nixpkgs), so a third-party flake that leaves its nixpkgs
      # input unnamed gets this flake: it must find nixpkgs.lib.* here. No name in
      # the solnix half shadows a nixpkgs lib attribute (checked at the pinned rev).
      lib = lib // { inherit solnixSystem mkPkgs shellPathOverlay worldOverlay; };

      # legacyPackages, nixpkgs' shape: x86_64-solaris is solnix's whole package
      # set (pkgs.solnix.*, from source); every other system is plain nixpkgs at the
      # same pin, so `nixpkgs#hello` from a flake that resolved nixpkgs here still
      # works on Linux and macOS. Lazy: a Linux eval never touches the illumos set.
      # x86_64-solaris is not in nixpkgs' flakeExposed list, so it is added here.
      legacyPackages = lib.genAttrs (lib.unique (lib.systems.flakeExposed ++ solnixSystems)) (system:
        if system == "x86_64-solaris" then (mkPkgs { }).solnix
        else (import solnix-pkgs.inputs.nixpkgs { inherit system; }));

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
          pkgs = mkPkgs { };
          modules = [ ./configurations/base.nix ];
        };

        # The public-cloud (EC2 AMI) role: base + IMDS first-boot keypair fetch,
        # MTU self-raise off (reboot-loop hazard). The toplevel the public
        # x86_64 AMI is built from.
        cloud-ec2 = solnixSystem {
          system = "x86_64-solaris";
          pkgs = mkPkgs { };
          modules = [ ./configurations/cloud-ec2.nix ];
        };

        # The PostgreSQL build-farm animal + dev host role (base + pgfarm).
        # This is what an installer selects for that machine.
        pgfarm = solnixSystem {
          system = "x86_64-solaris";
          pkgs = mkPkgs { };
          modules = [ ./configurations/pgfarm.nix ];
        };

        # arnold, the maintainer's ThinkPad X1 Extreme Gen 1 -- the target of
        # `solnix-install --flake .#arnold`. See configurations/arnold.nix.
        #
        # ⚠️ configurations/arnold.nix deliberately sets NO system.stateVersion and NO
        # solnix.home.style: neither option exists in this module set, and setting an
        # undefined option is an eval error. Do not add them here either without first
        # declaring the option in modules/config/.
        # The installer media's own system: generic (no personal users, keys or
        # flake refs). scripts/make-installer-image.sh puts its closure on the media.
        installer = solnixSystem {
          system = "x86_64-solaris";
          pkgs = mkPkgs { };
          modules = [ ./configurations/installer.nix ];
        };

        # The MINIMAL live-ramdisk edition (installation-cd-minimal.nix analog):
        # installer.nix with system.buildCapable=false, so solnix-dev-full (gcc +
        # the ~1.2 GB gate-proto sysroot) is dropped from the LIVE closure and the
        # ramdisk fits under the X1's 816 MB block ceiling. dev-full + the base
        # closure ride in the read-only media store (make-iso-usb.sh
        # SOLNIX_STORE_ROOTS = installerToplevel closure); install-from-flake
        # builds the target FROM the media store, so the shipped system is still
        # fully build-capable. See docs/design-two-installer-images.md #1+#2 and
        # configurations/installer-live.nix.
        installer-live = solnixSystem {
          system = "x86_64-solaris";
          pkgs = mkPkgs { };
          modules = [ ./configurations/installer-live.nix ];
        };

        # The wired/cloud edition: installer / installer-live without the wifi
        # and GPU modules, so it builds on a solnix host (no perl or OI gcc in
        # its kernel tree). See configurations/installer-wired.nix.
        installer-wired = solnixSystem {
          system = "x86_64-solaris";
          pkgs = mkPkgs { };
          modules = [ ./configurations/installer.nix ./configurations/installer-wired.nix ];
        };
        installer-live-wired = solnixSystem {
          system = "x86_64-solaris";
          pkgs = mkPkgs { };
          modules = [ ./configurations/installer-live.nix ./configurations/installer-wired.nix ];
        };

        # installer-live + a diagnostic agent (stick log, LAN stream, halt on
        # panic) for chasing an unexplained reboot on real hardware.
        # See configurations/installer-x1ediag.nix.
        installer-x1ediag = solnixSystem {
          system = "x86_64-solaris";
          pkgs = mkPkgs { };
          modules = [ ./configurations/installer-x1ediag.nix ];
        };

        arnold = solnixSystem {
          system = "x86_64-solaris";
          pkgs = mkPkgs { };
          modules = [ ./configurations/arnold.nix ];
        };
        # dixi: the old name of arnold's config (2026-10-24 rename), kept so scripts and
        # docs that say .#dixi still evaluate the same system.
        dixi = self.solnixConfigurations.arnold;
      };

      # Per-build-system image packages. The image builder (lib/make-be.nix)
      # emits a root-run assembly SCRIPT (the privileged ZFS/loader steps can't
      # run in a Nix sandbox — see lib/make-be.nix header + design-make-be.md §7),
      # so what we expose here is that script + the toplevel it consumes. Realise
      # on the illumos host; run the script as root against a scratch disk.
      packages = {
        # The from-source userland, for nix build .#<name> / nix shell .#<name> on
        # an illumos host (NixOS: packages.<system> = the package set): every
        # derivation in pkgs.solnix, so `nix shell solnix#<name>` reaches whatever
        # the set builds. Builder functions (mkIwxKernel ...) and nested sets
        # (cached, starter, slices) stay reachable through legacyPackages, as in
        # nixpkgs. An attribute that throws at eval is left out, not fatal.
        # cached and starter are store-path imports (builtins.storePath /
        # fetchClosure), not builds, and fetchClosure needs an experimental feature
        # whose absence tryEval cannot catch, so they are named and dropped first.
        # plus the seed rung (lib/host-pkgs.nix seedPkgs: the buildTools = [ ] instance every x86 build stands on) under its served
        # row pnames (<pname>-seed, illumos-userland-seed, seed-tar-alias, solnix-seed-build-tools, gcc-wrapper-seed), so the
        # builder's drv_for (packages.<system>.<pname>) finds a seed row's derivation (wave6t: none did; the served -seed rows were
        # rowed by out only). Never over an existing name.
        x86_64-solaris = let p = mkPkgs { }; s = p.seedPkgs;
            seedRows = {
              zlib-seed = s.zlib; libxml2-seed = s.libxml2; nspr-seed = s.nspr; nss-seed = s.nss; illumos-userland-seed = s.world;
              coreutils-seed = s.coreutils; findutils-seed = s.findutils; gnused-seed = s.gnused; gnugrep-seed = s.gnugrep;
              gnutar-seed = s.gnutar; gzip-seed = s.gzip; gnumake-seed = s.gnumake; gnupatch-seed = s.gnupatch; xz-seed = s.xz;
              binutils-seed = s.binutils; perl-seed = s.perl; bash-seed = s.bash; gcc-wrapper-seed = s.gccWrapper;
              seed-tar-alias = s.seedTarAlias; solnix-seed-build-tools = s.seedBuildTools;
              # ld's build input (pkgs/illumos/libld.nix): no runtime reference reaches it, so only its own row publishes it
              libld = s.libld0011;
              # the system world's served pname is illumos-userland (the attr is `world`): drv_for looks up the pname (wave6u, piece 2)
              illumos-userland = p.solnix.world;
            };
            # served row pnames that are not top-level attrs (wave6v, W2: drv_for MISSed 28 of 172 rows), as aarch64 below:
            # the nix chain's members (never over an existing name), hostname-f, illumos-vi; and two names whose served row
            # is another drv than the attr was: nix = nixSrc 2.24.15 (the attr was the /nix-tools ingest, which does not
            # evaluate purely), meson = 1.10.2 (served row; graphics' 1.4.2 moves to meson_1_4). aarch64 has both already.
            lifted = removeAttrs p.solnix.nixChain [ "curlForNix" "nix" ];
            # illumos-early: the early-boot slice's served pname (attr early; drv_for MISSed its W3a row, wave6w)
            renamed = { hostname-f = p.solnix.hostname; illumos-vi = p.solnix.vi; nix = p.solnix.nixSrc; illumos-early = p.solnix.early;
                        meson = p.solnix.meson_1_10; meson_1_4 = p.solnix.meson; };
          in lib.filterAttrs (_: v:
          let r = builtins.tryEval (lib.isDerivation v); in r.success && r.value)
          (lifted // seedRows // removeAttrs p.solnix [ "cached" "starter" "libld0011" ] // renamed);   # libld0011: the system instance's builds nothing (libld is the seed's)
        # the native aarch64 set (pkgs/illumos/aarch64; lib/host-pkgs.nix uses the same import), for drv_for on dixa. The
        # served aarch64 rows include the nix chain and gate pieces that live only in nested sets (srcPkgs, nixChain): they
        # are lifted to the top, never over an existing name (sqlite: one 3.50.4, which nixChain links too), plus
        # the served pnames that differ from the attr (hostname-f, illumos-gate-libs(-home)). solnix-builder.sh finds an
        # attr by pname, its _ form or camelCase (gcc-wrapper -> gccWrapper).
        aarch64-solaris = let a = import ./pkgs/illumos/aarch64 { system = "aarch64-solaris"; }; in lib.filterAttrs (_: v:
          let r = builtins.tryEval (lib.isDerivation v); in r.success && r.value)
          (removeAttrs a.srcPkgs.nixChain [ "curlForNix" ] // a.srcPkgs // removeAttrs a [ "systemToplevel" ]
           // { hostname-f = a.hostname; illumos-gate-libs = a.gateLibs; illumos-gate-libs-home = a.world; });
        # the native sparcv9 set (pkgs/illumos/sparcv9: lixu, sun's zone), for drv_for on lixu: the libc slice and the seed zlib so far
        sparcv9-solaris = lib.filterAttrs (_: v: let r = builtins.tryEval (lib.isDerivation v); in r.success && r.value)
          (import ./pkgs/illumos/sparcv9 { system = "sparcv9-solaris"; });
      } // lib.genAttrs buildSystems (_buildSystem: {
        # the full system closure (T2.8); realise on the illumos host.
        baseToplevel = self.solnixConfigurations.base.config.system.build.toplevel;
        cloudEc2Toplevel = self.solnixConfigurations.cloud-ec2.config.system.build.toplevel;
        pgfarmToplevel = self.solnixConfigurations.pgfarm.config.system.build.toplevel;
        # arnold (formerly dixi): the maintainer's X1 Extreme Gen 1. Same eval-split caveat as the others --
        # this EVALUATES here and only BUILDS on the illumos host, because the gate
        # proto and the slices carved from it are x86_64-solaris derivations.
        arnoldToplevel = self.solnixConfigurations.arnold.config.system.build.toplevel;
        dixiToplevel = self.solnixConfigurations.arnold.config.system.build.toplevel;  # old name, same system
        installerToplevel = self.solnixConfigurations.installer.config.system.build.toplevel;
        installerLiveToplevel = self.solnixConfigurations.installer-live.config.system.build.toplevel;
        installerX1ediagToplevel = self.solnixConfigurations.installer-x1ediag.config.system.build.toplevel;
        installerWiredToplevel = self.solnixConfigurations.installer-wired.config.system.build.toplevel;
        installerLiveWiredToplevel = self.solnixConfigurations.installer-live-wired.config.system.build.toplevel;

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
      #
      # IMPORTANT: use PLAIN nixpkgs for the host system here, NOT `pkgsFor`.
      # `pkgsFor` applies solnix-pkgs' illumos cross-stdenv overlay, and
      # instantiating even mkShellNoCC through that overlaid stdenv forces the
      # illumos cross-GCC bootstrap to BUILD (gmp/mpfr/mpc/isl/perl/bison...),
      # which made `cd` into the repo recompile a toolchain on every cold direnv
      # eval. The ops shell needs none of that — plain nixpkgs tools only.
      devShells = lib.genAttrs buildSystems (buildSystem:
        let pkgs = nixpkgs-host.legacyPackages.${buildSystem}; in {
          default = pkgs.mkShellNoCC {
            packages = with pkgs; [ git sops age awscli2 xorriso jq curl ];
            shellHook = ''
              echo "solnix dev shell — build/ops tooling (target userland is x86_64-solaris)."
            '';
          };
        });
    };
}
