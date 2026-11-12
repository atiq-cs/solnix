# services.desktopManager.cosmic -- the COSMIC desktop on illumos, NixOS's
# option name (nixos/modules/services/desktop-managers/cosmic.nix). DEFAULT OFF.
#
# Like NixOS: the COSMIC packages go in the system closure (environment.systemPackages),
# with the fonts COSMIC defaults to (Fira, Noto, Open Sans) and its icon themes, and the
# greeter is cosmic-greeter under greetd (services.displayManager.cosmic-greeter). How
# this departs from NixOS, and why (illumos has no systemd or logind):
#   * SMF services instead of systemd units: greetd, cosmic-greeter-daemon, the
#     system bus is illumos's own dbus service, and a seatd daemon (NixOS without logind).
#   * PAM is illumos libpam: both services fall to the stock pam.conf "other" stack.
#   * /dev/dri as NixOS: renderD* 0666 for everyone (minor_perm, modules/config/wireless-iwx.nix drmPerms);
#     card* 0600 root, opened for the compositor by seatd (root) through libseat, as logind does on NixOS.
#   * no xdg-desktop-portal-cosmic (PipeWire + GStreamer). cosmic-settings-daemon is in, with its PipeWire
#     audio backend gated off (no audio devices), as NixOS lists it in corePkgs.
#   * the session does not start the cosmic-greeter screen locker (no logind Lock signal; cosmic-apps-src-fixup.py).
#   * cosmic-store only if flatpak were available (as NixOS); it is not, so it is off.
#
# It REFUSES to enable unless hardware.graphics.i915.attachAtBoot: a card0 opener
# before i915 stage B passes is what src/drm-port/i915/STAGED-ATTACH-PLAN.md forbids.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.desktopManager.cosmic;
  inherit (lib) mkOption mkEnableOption types mkIf;
  s = pkgs.solnix;
  mesa = s.mesa;
  greeterUid = 30080;   # NixOS: isSystemUser (dynamic); here a fixed system uid
in
{
  options.services.desktopManager.cosmic = {
    enable = mkEnableOption "the COSMIC desktop environment (needs i915 attached at boot)";
    packages = mkOption {
      type = types.listOf types.package;
      default = with s; [
        cosmic-comp cosmic-session cosmic-panel cosmic-applets cosmic-launcher cosmic-app-library
        cosmic-notifications cosmic-osd cosmic-settings-daemon cosmic-bg cosmic-workspaces cosmic-idle cosmic-randr
        cosmic-settings cosmic-files cosmic-edit cosmic-term cosmic-screenshot cosmic-greeter
        dbus cosmic-icons pop-icon-theme hicolor-icon-theme
      ];
      description = "The COSMIC packages installed (NixOS: the core list plus the optional apps).";
    };
    fonts = mkOption {
      type = types.listOf types.package;
      default = with s; [ fira-mono noto-sans noto-sans-mono open-sans dejavu-fonts liberation-fonts noto-fonts-color-emoji ];
      description = "Fonts on the fontconfig path (NixOS: fonts.packages = [ fira noto-fonts open-sans ] + fonts.enableDefaultPackages).";
    };
    greeter = mkOption {
      type = types.bool;
      default = true;
      description = "Start cosmic-greeter under greetd at boot (NixOS: services.displayManager.cosmic-greeter).";
    };
    vt = mkOption {
      type = types.int;
      default = 7;
      description = "Virtual console greetd runs on (/dev/vt/N; vt(4I) keeps VT 1 for the system console).";
    };
    drmDevice = mkOption {
      type = types.str;
      default = "/dev/dri/card0";
      description = "DRM node the compositor drives (COSMIC_RENDER_DEVICE / smithay's DRM backend).";
    };
  };

  config = mkIf cfg.enable (import ./desktop-cosmic-config.nix { inherit config lib pkgs cfg s mesa greeterUid; });
}
