# modules/config/system-path.nix — the declarative userland profile. Declares
# environment.systemPackages and composes them (via pkgs.buildEnv) into
# system.path, the /run/current-system/sw symlink farm every user's PATH picks
# up (design \u00a7B). The solnix analog of NixOS's config/system-path.nix.
#
# sw is SEPARATE from pkgs.solnix.systemPath (the kernel/libc base): a broken
# systemPackages set can't drop the kernel. The activation module links
# system.path at $out/sw; shell-environment.nix puts sw/bin first on PATH.

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption types;

  # extraOutputPaths: systemPackages plus each requested extra output that a
  # package actually HAS. lib/build-env.nix only merges the paths it is handed
  # (its own extraOutputsToInstall is a no-op on single-output slices), so to
  # deliver a package's `debug`/`man`/`dev` output into the profile the way NixOS
  # does (environment.extraOutputsToInstall), the extra outputs must be added to
  # `paths` here. `pkg ? <output>` guards packages that lack a given output (a
  # single-output slice has no `.debug`), so it is safe across the mixed set
  # (mk-userland-pkg packages carry a `debug` output; mk-src-pkg ones do not).
  extraOutputPaths =
    config.environment.systemPackages
    ++ lib.concatMap
      (pkg: lib.concatMap
        # isDerivation: an attr named like an output can be something else (cargoPkg's `man` install hook is a string)
        (o: lib.optional (pkg ? ${o} && lib.isDerivation pkg.${o}) pkg.${o})
        config.environment.extraOutputsToInstall)
      config.environment.systemPackages;
in
{
  options.environment = {
    systemPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = ''
        Packages merged into the system profile (/run/current-system/sw) and put
        in every user's PATH. The solnix analog of NixOS's
        environment.systemPackages.
      '';
    };

    pathsToLink = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Subtrees of each package linked into the system profile. Prefixes match
        the leading path component(s) of a package's files (e.g. "/bin" links
        bin/*). Defaults cover binaries, libraries (both ABIs), and man/info.
      '';
    };

    extraOutputsToInstall = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "man" "dev" ];
      description = ''
        Extra package outputs to install into the system profile (NixOS's
        environment.extraOutputsToInstall). For each systemPackage that HAS the
        named output (e.g. a mk-userland-pkg package's `debug` output), that
        output is added to the composed profile (see extraOutputPaths above).
        Packages lacking the output are skipped. `debug` is set by
        modules/config/debug-info.nix when environment.enableDebugInfo is on.
      '';
    };
  };

  # internal: the composed system profile derivation the activation module links
  # at $out/sw (-> /run/current-system/sw). NixOS's `system.path`.
  options.system.path = mkOption {
    type = types.package;
    internal = true;
    description = "The composed system profile (buildEnv over environment.systemPackages).";
  };

  config = {
    system.path = pkgs.buildEnv {
      name = "solnix-system-path";
      paths = extraOutputPaths;
      inherit (config.environment) pathsToLink extraOutputsToInstall;
      ignoreCollisions = true;
    };

    # The base subtrees, as a definition rather than the option default, so a
    # config's own `environment.pathsToLink = [ ... ]` ADDS to them (list options
    # merge definitions; a default is replaced). NixOS does the same in
    # nixos/modules/config/system-path.nix. Measured: setting the option in
    # configurations/installer.nix replaced the default and dropped /bin, so the
    # toplevel failed with "no nix on the system PATH".
    environment.pathsToLink = [ "/bin" "/sbin" "/share/man" "/share/info" ];

    # Seed the gate's whole userland first, so a config's own systemPackages
    # (later in the list) win on a name clash. /usr/bin links to sw/bin.
    environment.systemPackages = lib.mkBefore [ pkgs.solnix.world ];
  };
}
