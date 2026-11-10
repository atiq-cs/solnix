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
  # NixOS xdg.icons.fallbackCursorThemes (the cosmic module: [ "Cosmic" ]): the "default" theme cosmic-comp loads
  # when XCURSOR_THEME is unset; Cosmic inherits Pop, whose cursors/ it finds. Without it comp drew its built-in cursor.
  fallbackCursorTheme = pkgs.writeTextFile {
    name = "fallback-cursor-theme";
    text = "[Icon Theme]\nInherits=Cosmic\n";
    destination = "/share/icons/default/index.theme";
  };
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
  environment.systemPackages = [ s.wayland s.libdrm mesa s.greetd ] ++ cfg.packages ++ cfg.fonts ++ [ fallbackCursorTheme ]
    # NixOS's cosmic module (adwaita-icon-theme, xdg-user-dirs; xdg.sounds: sound-theme-freedesktop) and graphical-desktop
    # (xdg-utils). Not in cfg.packages, as NixOS keeps them out of its COSMIC list.
    ++ (with s; [ adwaita-icon-theme xdg-user-dirs sound-theme-freedesktop xdg-utils ])
    # Help on the desktop (COSMIC has none): the Solnix Manual entry (NixOS's nixos-help), the man: URI handler
    # (xdg-open man:ls) and the launcher's "man <word>" search (pkgs/illumos/desktop/help.nix).
    ++ lib.optional config.documentation.man.enable s.solnix-help;
  # NixOS cosmic: services.avahi (mdnsd here); the gate's perl scripts (lp, lpstat, print-service) need /usr/perl5/bin.
  solnix.defaults.mdns = lib.mkDefault true;
  solnix.perl5Mediator.enable = lib.mkDefault true;

  # What the session finds through /run/current-system/sw/share, as NixOS links it: cosmic.nix (backgrounds,
  # cosmic*), xdg.icons (icons, pixmaps), xdg.menus (applications, desktop-directories), xdg.mime, dbus.nix,
  # displayManager's wayland-sessions (the greeter's session list) and metainfo (app-library, store).
  environment.pathsToLink = [
    "/share/applications" "/share/desktop-directories" "/share/icons" "/share/pixmaps" "/share/mime"
    "/share/metainfo" "/share/wayland-sessions" "/share/dbus-1" "/share/backgrounds"
    "/share/cosmic" "/share/cosmic-layouts" "/share/cosmic-themes"
    "/share/sounds" "/etc/xdg"   # NixOS xdg.sounds; xdg.autostart + programs/environment.nix (sw/etc/xdg)
  ];
  # NixOS programs/environment.nix + xdg/icons.nix: XDG_DATA_DIRS and XCURSOR_PATH per profile (system, the
  # user's ~/.nix-profile, default), so apps installed with home-manager or nix profile show up too.
  environment.profileRelativeSessionVariables = {
    XDG_DATA_DIRS = [ "/share" ];
    XCURSOR_PATH = [ "/share/icons" "/share/pixmaps" ];
    # NixOS programs/environment.nix: cosmic-session's autostart scan ($dir/autostart) and xdg-user-dirs read these.
    XDG_CONFIG_DIRS = [ "/etc/xdg" ];
  };
  environment.sessionVariables.XDG_CONFIG_DIRS = [ "/etc/xdg" ];   # ahead of the profile ones, as NixOS

  # libEGL/libgbm find iris/GBM in Mesa's own prefix (its compiled-in paths), so no
  # /run/opengl-driver indirection. The ICD file is for whichever Vulkan loader an app ships.
  environment.variables = {
    VK_DRIVER_FILES = "${mesa}/share/vulkan/icd.d/intel_icd.x86_64.json";
    XDG_SESSION_TYPE = "wayland";
    XDG_CURRENT_DESKTOP = "COSMIC";
    XCURSOR_PATH = [ "$HOME/.icons" "$HOME/.local/share/icons" ];   # ahead of the profile ones, as NixOS
    X11_BASE_RULES_XML = "${s.xkeyboard-config}/share/X11/xkb/rules/base.xml";
    X11_EXTRA_RULES_XML = "${s.xkeyboard-config}/share/X11/xkb/rules/base.extras.xml";
    COSMIC_RENDER_DEVICE = cfg.drmDevice;
    # shortcut: Mesa allocates no render-compressed (CCS) buffers. cosmic-comp scanned out Y_TILED_GEN12_RC_CCS_CC
    # buffers and the panel flashed on every pointer-motion commit (lixi, cosmic6); drop once that is understood.
    INTEL_DEBUG = "noccs";
  };
  environment.generatedEtc = {
    # pop-launcher reads plugins from /etc/pop-launcher/plugins (its src/lib.rs SYSTEM_PLUGINS) as well as its own
    # store path, so the man plugin needs no launcher rebuild. bin is the plugin's absolute store path.
    "pop-launcher/plugins/man/plugin.ron" = lib.mkIf config.documentation.man.enable
      (builtins.replaceStrings [ "@out@" ] [ "${s.solnix-help}" ] (builtins.readFile ../../pkgs/illumos/desktop/help/plugin.ron));
    "fonts/fonts.conf" = fontsConf;
    "greetd/config.toml" = greetdToml;
  };
  # PAM: greetd and cosmic-greeter have no pam.conf(5) lines of their own, so illumos libpam
  # uses the stock "other" stack (pam_authtok_get, pam_unix_auth, ...; /etc/pam.conf), the
  # analog of NixOS's default security.pam.services entry.

  # NixOS (services.seatd): a `seat` group may open the seat. The greeter is in it; desktop
  # users join it with extraGroups = [ "seat" ] (lixi: its desktop user), as on NixOS.
  users.groups.seat = { gid = greeterUid + 2; members = [ "cosmic-greeter" ]; };
  users.groups.cosmic-greeter.gid = greeterUid;
  users.users.cosmic-greeter = {
    uid = greeterUid; group = "cosmic-greeter"; description = "COSMIC login greeter user";
    home = "/var/lib/cosmic-greeter"; shell = "/usr/bin/false"; hashedPassword = null;
  };

  # The system bus (NixOS has it always on): cosmic-greeter-daemon and cosmic-comp use it.
  services.dbus = { enable = true; packages = [ greeter ]; };
  # NixOS's cosmic module turns on services.upower (and power-profiles via system76-power) and, by default,
  # networking.networkmanager. Here their D-Bus stand-ins: the battery and power mode, and the network applet.
  services.solnix-power.enable = lib.mkDefault true;
  services.solnix-nm.enable = lib.mkDefault true;

  smf.services = mkIf cfg.greeter {
    # NixOS services.seatd (no logind): cosmic-comp's libseat talks to it over /var/run/seatd.sock.
    seatd = {
      enable = true;
      category = "system"; description = "seatd seat management daemon (libseat)";
      start.exec = start "${s.seatd}/bin/seatd -g seat &";
      requires = [ "svc:/system/filesystem/local:default" ];
    };
    cosmic-greeter-daemon = {
      enable = true;
      category = "application"; description = "COSMIC greeter D-Bus daemon (com.system76.CosmicGreeter)";
      start.exec = start "${greeter}/bin/cosmic-greeter-daemon &";
      requires = [ "svc:/system/dbus:default" ];
    };
    greetd = {
      enable = true;
      category = "application"; description = "greetd login manager running cosmic-greeter";
      start.exec = start "mkdir -p -m 0755 /run/cosmic-greeter /var/lib/cosmic-greeter && chown cosmic-greeter /run/cosmic-greeter /var/lib/cosmic-greeter && ${s.greetd}/bin/greetd --config /etc/greetd/config.toml &";
      requires = [ "svc:/milestone/multi-user:default" "svc:/system/seatd:default" "svc:/application/cosmic-greeter-daemon:default" ];
      # The user's session lives in greetd's contract: at logout cosmic-session SIGKILLs the panel and its applets
      # abort with cores (measured on lixi), which svc.startd took as greetd failing and restarted it (as ssh.xml).
      ignoreError = [ "core" "signal" ];
    };
  };
}
