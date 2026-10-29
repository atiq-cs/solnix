# desktop-cosmic-config.nix: the config half of services.desktopManager.cosmic (desktop-cosmic.nix).
{ config, lib, pkgs, cfg, s, mesa, greeterUid }:
let
  inherit (lib) mkIf concatMapStringsSep;
  greeter = s.cosmic-greeter;
  # greetd.toml (NixOS services.greetd.settings): cosmic-greeter-start as the cosmic-greeter user.
  # PATH explicitly: a greetd session gets only the PAM environment (measured: no PATH).
  greetdToml = ''
    [terminal]
    vt = ${toString cfg.vt}
    [general]
    service = "greetd"
    [default_session]
    user = "cosmic-greeter"
    command = "/usr/bin/env PATH=/run/current-system/sw/bin:/usr/bin:/usr/sbin XCURSOR_THEME=Pop COSMIC_COMP=${s.cosmic-comp}/bin/cosmic-comp ${greeter}/bin/cosmic-greeter-start"
  '';
  # fontconfig: fontdb (cosmic-text) reads /etc/fonts/fonts.conf itself (no libfontconfig).
  fontsConf = ''
    <?xml version="1.0"?>
    <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
    <fontconfig>
    ${concatMapStringsSep "\n" (f: "  <dir>${f}/share/fonts</dir>") cfg.fonts}
    </fontconfig>
  '';
  start = cmd: "/usr/bin/bash -c ${lib.escapeShellArg cmd}";
in
{
  assertions = [{
    assertion = config.hardware.graphics.i915.attachAtBoot;
    message = ''
      services.desktopManager.cosmic opens the i915 DRM node, which runs the first
      inteldrm modeset. src/drm-port/i915/STAGED-ATTACH-PLAN.md allows that only
      after stage 1 passed; set hardware.graphics.i915.attachAtBoot first.
    '';
  }];

  solnix.roles = [ "cosmic-desktop" ];
  environment.systemPackages = [ s.wayland s.libdrm mesa s.greetd ] ++ cfg.packages ++ cfg.fonts;

  # libEGL/libgbm find iris/GBM in Mesa's own prefix (its compiled-in paths), so no
  # /run/opengl-driver indirection. The ICD file is for whichever Vulkan loader an app ships.
  environment.variables = {
    VK_DRIVER_FILES = "${mesa}/share/vulkan/icd.d/intel_icd.x86_64.json";
    XDG_SESSION_TYPE = "wayland";
    XDG_CURRENT_DESKTOP = "COSMIC";
    XDG_DATA_DIRS = lib.concatMapStringsSep ":" (p: "${p}/share") cfg.packages;
    X11_BASE_RULES_XML = "${s.xkeyboard-config}/share/X11/xkb/rules/base.xml";
    X11_EXTRA_RULES_XML = "${s.xkeyboard-config}/share/X11/xkb/rules/base.extras.xml";
    COSMIC_RENDER_DEVICE = cfg.drmDevice;
  };
  environment.generatedEtc = {
    "fonts/fonts.conf" = fontsConf;
    "greetd/config.toml" = greetdToml;
  };
  # PAM: greetd and cosmic-greeter have no pam.conf(5) lines of their own, so illumos libpam
  # uses the stock "other" stack (pam_authtok_get, pam_unix_auth, ...; /etc/pam.conf), the
  # analog of NixOS's default security.pam.services entry.

  # NixOS (services.seatd): a `seat` group may open the seat. The greeter is in it; desktop
  # users join it with extraGroups = [ "seat" ] (lixi: gburd), as on NixOS.
  users.groups.seat = { gid = greeterUid + 2; members = [ "cosmic-greeter" ]; };
  users.groups.cosmic-greeter.gid = greeterUid;
  users.users.cosmic-greeter = {
    uid = greeterUid; group = "cosmic-greeter"; description = "COSMIC login greeter user";
    home = "/var/lib/cosmic-greeter"; shell = "/usr/bin/false"; hashedPassword = null;
  };

  # The system bus (NixOS has it always on): cosmic-greeter-daemon and cosmic-comp use it.
  services.dbus = { enable = true; packages = [ greeter ]; };

  smf.services = mkIf cfg.greeter {
    # NixOS services.seatd (no logind): cosmic-comp's libseat talks to it over /var/run/seatd.sock.
    seatd = {
      category = "system"; description = "seatd seat management daemon (libseat)";
      start.exec = start "${s.seatd}/bin/seatd -g seat &";
      requires = [ "svc:/system/filesystem/local:default" ];
    };
    cosmic-greeter-daemon = {
      category = "application"; description = "COSMIC greeter D-Bus daemon (com.system76.CosmicGreeter)";
      start.exec = start "${greeter}/bin/cosmic-greeter-daemon &";
      requires = [ "svc:/system/dbus:default" ];
    };
    greetd = {
      category = "application"; description = "greetd login manager running cosmic-greeter";
      start.exec = start "mkdir -p -m 0755 /run/cosmic-greeter /var/lib/cosmic-greeter && chown cosmic-greeter /run/cosmic-greeter /var/lib/cosmic-greeter && ${s.greetd}/bin/greetd --config /etc/greetd/config.toml &";
      requires = [ "svc:/milestone/multi-user:default" "svc:/application/seatd:default" "svc:/application/cosmic-greeter-daemon:default" ];
    };
  };
}
