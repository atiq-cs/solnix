# modules/config/documentation.nix — man pages + the `man` command, system-wide.
#
# The solnix analog of NixOS's misc/documentation.nix + mandoc.nix. Goal: on
# every installed system and installer image, `man <tool>` works for BOTH the
# illumos base tools AND every package in the system/user Nix profile.
#
# WHAT PROVIDES WHAT (measured; see docs/man-and-debug-delivery.md):
#   * The `man`/`mandoc` viewer binaries come from pkgs.solnix.world (the gate's
#     /usr/bin/man + /usr/bin/mandoc), already on PATH via the base world. illumos
#     man(1) dispatches to mandoc(1) for formatting.
#   * Nix-profile packages ship their man pages in $out/share/man, linked into
#     the system profile at /run/current-system/sw/share/man (environment.pathsToLink
#     already carries "/share/man") and into each user's ~/.nix-profile/share/man.
#     MANPATH (modules/config/shell-environment.nix) already suffixes "/share/man"
#     onto every profile, so those resolve with no extra wiring.
#   * The illumos BASE man pages (ls(1), zfs(1M), ...) are the gap: mk-proto-world
#     EXCLUDES usr/share/man to keep the runtime closure lean, so the installed BE
#     has none. pkgs.solnix.worldMan carries them under share/man as a doc-only
#     store path; this module adds it to the system profile, so they land at
#     sw/share/man and the existing MANPATH finds them.
#
# This mirrors NixOS exactly: man pages are delivered through a PROFILE package
# into share/man, and MANPATH is profile-relative — not baked into the kernel/
# libc base. Enabling the module is the solnix analog of documentation.man.enable
# (default true, as on NixOS).

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption mkIf types concatStringsSep;
  cfg = config.documentation;

  # /etc/man.conf — the illumos man(1)/mandoc fallback config. illumos man(1)
  # honors MANPATH (set per-login in shell-environment.nix); /etc/man.conf's
  # `MANPATH <dir>` lines are the fallback when MANPATH is unset (e.g. a non-login
  # context). We list the system profile's share/man + the base-man slice so a
  # bare `man` works even without the login environment. Mirrors NixOS mandoc.nix
  # writing environment.etc."man.conf".
  manConf = concatStringsSep "\n" (map (p: "MANPATH ${p}") cfg.man.manPath) + "\n";
in
{
  options.documentation = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Master switch for installing documentation (man pages). NixOS's documentation.enable.";
    };

    man.enable = mkOption {
      type = types.bool;
      default = cfg.enable;
      description = ''
        Install man pages and make the `man` command work for base illumos tools
        and every profile package. NixOS's documentation.man.enable.
      '';
    };

    man.manPath = mkOption {
      type = types.listOf types.str;
      default = [
        "/run/current-system/sw/share/man"
        "/nix/var/nix/profiles/default/share/man"
        # the illumos base layout, for the livecd-script image path where the
        # gate's usr/share/man is staged directly (oi-make-livecd.sh) rather than
        # via the worldMan slice.
        "/usr/share/man"
      ];
      description = ''
        Absolute manpath directories written to /etc/man.conf as a fallback for
        man(1) when MANPATH is unset. The login MANPATH (shell-environment.nix)
        is the primary path; these are the belt-and-suspenders fallback.
      '';
    };
  };

  config = mkIf (cfg.enable && cfg.man.enable) {
    environment = {
      # Base illumos man pages into the system profile (-> sw/share/man). The
      # existing environment.pathsToLink carries "/share/man" and the login
      # MANPATH already suffixes it, so no MANPATH change is needed here.
      systemPackages = [ pkgs.solnix.worldMan ];

      # Ensure the man outputs of profile packages are pulled in (NixOS sets this
      # from documentation.man.enable). solnix packages keep man in $out, so this
      # is a no-op today for the base set, but it is the NixOS-faithful wiring and
      # covers any future package that splits a `man` output.
      extraOutputsToInstall = [ "man" ];

      # /etc/man.conf fallback manpath (folded into the generated /etc overlay by
      # modules/system/activation).
      generatedEtc."man.conf" = manConf;
    };
  };
}
