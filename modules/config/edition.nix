{ config, lib, ... }:
# modules/config/edition.nix — the solnix edition marker (release channel).
#
# Mirrors NixOS's stable/unstable model (see docs/design-editions.md). Two
# editions: rolling "unstable" (what we build now) and frozen dated stables
# ("26.11", ...). The edition is set here + recorded in /etc/solnix-release so
# a running system is self-describing and a future dated freeze is a pin+tag,
# not a retrofit.
{
  # roles: WHAT a system is for, orthogonal to the edition (WHICH channel it
  # tracks). A role module (e.g. modules/config/pgfarm.nix) appends its own name
  # here, so a running system records both facts in /etc/solnix-release and an
  # installed animal is self-describing without inspecting its service list.
  options.solnix.roles = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "pgfarm" ];
    description = ''
      Roles this system fills, appended by the role modules themselves (not set
      by hand). Recorded in /etc/solnix-release as ROLES=.
    '';
  };

  options.solnix.edition = lib.mkOption {
    type = lib.types.str;
    default = config.solnix.release;
    defaultText = lib.literalExpression "config.solnix.release";
    example = "26.11";
    description = ''
      solnix release edition. "unstable" = rolling (moving nixpkgs pin +
      solnix-pkgs at HEAD). A dated value like "26.11" = a frozen release
      (nixpkgs release-26.11 pin + solnix-pkgs tag v26.11, namespaced cache).
    '';
  };

  # /etc/solnix-release (EDITION=, ROLES=) is written by modules/config/release.nix.
}
