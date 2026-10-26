# services.desktopManager.cosmic -- the COSMIC desktop on illumos, NixOS's
# option name (nixos/modules/services/desktop-managers/cosmic.nix). DEFAULT OFF.
#
# Installs pkgs.solnix.{wayland,libdrm,mesa}, points the GL/GBM/Vulkan loaders at
# Mesa, and declares an SMF service starting the compositor on the i915 DRM node
# (NixOS: greetd). How and why this departs from NixOS: docs/x1-desktop-userland.md.
#
# It REFUSES to enable unless hardware.graphics.i915.attachAtBoot: a card0 opener
# before i915 stage B passes is what src/drm-port/i915/STAGED-ATTACH-PLAN.md forbids.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.desktopManager.cosmic;
  inherit (lib) mkOption mkEnableOption types mkIf;
  mesa = pkgs.solnix.mesa;
  # NixOS: logind makes /run/user/<uid>. Here the method (run as the user) makes
  # a 0700 dir it owns; one pre-created by someone else fails the start.
  start = pkgs.writeShellScript "cosmic-session-start" ''
    d=/tmp/cosmic-runtime-${cfg.user}; mkdir -m 0700 -p "$d" && [ -O "$d" ] || exit 1
    export XDG_RUNTIME_DIR="$d"; exec ${cfg.compositor}/bin/cosmic-comp
  '';
in
{
  options.services.desktopManager.cosmic = {
    enable = mkEnableOption "the COSMIC desktop environment (needs i915 attached at boot)";
    compositor = mkOption {
      type = types.nullOr types.package;
      default = null;
      description = "bin/cosmic-comp. null (no session service) until cosmic-comp builds on illumos.";
    };
    user = mkOption {
      type = types.str;
      description = "User the session runs as (NixOS: services.displayManager.autoLogin.user).";
    };
    drmDevice = mkOption {
      type = types.str;
      default = "/dev/dri/card0";
      description = "DRM node the compositor drives (COSMIC_RENDER_DEVICE / smithay's DRM backend).";
    };
  };

  config = mkIf cfg.enable {
    assertions = [{
      assertion = config.hardware.graphics.i915.attachAtBoot;
      message = ''
        services.desktopManager.cosmic opens the i915 DRM node, which runs the first
        inteldrm modeset. src/drm-port/i915/STAGED-ATTACH-PLAN.md allows that only
        after stage 1 passed; set hardware.graphics.i915.attachAtBoot first.
      '';
    }];

    environment.systemPackages = [ pkgs.solnix.wayland pkgs.solnix.libdrm mesa ]
      ++ lib.optional (cfg.compositor != null) cfg.compositor;

    # libEGL/libgbm find iris/GBM in Mesa's own prefix (its compiled-in dri and gbm
    # paths), so no /run/opengl-driver indirection is needed. The ICD file is for
    # whichever Vulkan loader an app ships (NixOS: hardware.graphics.extraPackages).
    environment.variables = {
      VK_DRIVER_FILES = "${mesa}/share/vulkan/icd.d/intel_icd.x86_64.json";
      XDG_SESSION_TYPE = "wayland";
      XDG_CURRENT_DESKTOP = "COSMIC";
    };

    smf.services.cosmic-session = mkIf (cfg.compositor != null) {
      category = "application";
      description = "COSMIC Wayland session (cosmic-comp on the i915 DRM node)";
      inherit (cfg) user;
      environment = {
        COSMIC_RENDER_DEVICE = cfg.drmDevice;
      };
      start.exec = "/usr/bin/bash ${start}";
      requires = [ "svc:/milestone/multi-user:default" ];
    };
  };
}
