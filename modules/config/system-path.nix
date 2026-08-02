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
      default = [ "/bin" "/sbin" "/lib" "/lib/amd64" "/share/man" "/share/info" ];
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
        Extra package outputs to install into the system profile. No-op for the
        single-output solnix slices today (see lib/build-env.nix); kept for
        nixpkgs-compat + future multi-output packages.
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
      paths = config.environment.systemPackages;
      inherit (config.environment) pathsToLink extraOutputsToInstall;
      ignoreCollisions = true;
    };

    # Seed the minimal required set at low priority so a config's own
    # systemPackages merge on top. base-tools IS the coreutils-equiv here (ls/cp/
    # mv/cat/rm/mkdir/ln + the SMF stack + the shell), so do NOT re-list coreutils.
    environment.systemPackages = lib.mkBefore [ pkgs.solnix.base-tools ];
  };
}
