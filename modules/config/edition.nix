{ config, lib, ... }:
# modules/config/edition.nix — the solnix edition marker (release channel).
#
# Mirrors NixOS's stable/unstable model (see docs/design-editions.md). Two
# editions: rolling "unstable" (what we build now) and frozen dated stables
# ("26.11", ...). The edition is set here + recorded in /etc/solnix-release so
# a running system is self-describing and a future dated freeze is a pin+tag,
# not a retrofit.
{
  options.solnix.edition = lib.mkOption {
    type = lib.types.str;
    default = "unstable";
    example = "26.11";
    description = ''
      solnix release edition. "unstable" = rolling (moving nixpkgs pin +
      solnix-pkgs at HEAD). A dated value like "26.11" = a frozen release
      (nixpkgs release-26.11 pin + solnix-pkgs tag v26.11, namespaced cache).
    '';
  };

  config.environment.generatedEtc."solnix-release" = ''
    NAME=solnix
    ID=solnix
    EDITION=${config.solnix.edition}
    VERSION_ID=${config.solnix.edition}
  '';
}
