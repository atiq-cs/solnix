# services.solnix-timedate -- org.freedesktop.timedate1 for COSMIC Settings > Time & language: src/solnix-timedate,
# docs/solnix-timedate.md. NixOS has systemd-timedated (always there with systemd); illumos has no systemd, so this is a
# small stand-in: ListTimezones from the zone files (/usr/share/lib/zoneinfo), Timezone from TZ in /etc/default/init,
# SetTimezone (root or an RBAC administrator) rewrites that TZ line. As on NixOS with time.timeZone set, the declared
# zone wins at the next switch: /etc/default/init is generated from time.timeZone (first-boot-defaults.nix).
{ config, lib, pkgs, ... }:
let
  cfg = config.services.solnix-timedate;
  td = pkgs.solnix.solnix-timedate;
in
{
  options.services.solnix-timedate = {
    enable = lib.mkEnableOption "solnix-timedate, org.freedesktop.timedate1 for COSMIC Settings > Time zone (systemd-timedated's stand-in)";
  };

  config = lib.mkIf cfg.enable {
    assertions = [{ assertion = config.services.dbus.enable; message = "services.solnix-timedate needs services.dbus.enable (the system bus)"; }];
    services.dbus.packages = [ td ];
    # root: SetTimezone rewrites /etc/default/init, as timedated runs as root to write /etc/localtime
    smf.services.solnix-timedate = {
      enable = true;
      category = "site";
      description = "solnix-timedate: org.freedesktop.timedate1 on the system bus (zones from /usr/share/lib/zoneinfo, TZ in /etc/default/init)";
      model = "contract";
      requires = [ "svc:/system/dbus:default" ];
      start.exec = "${td}/bin/solnix-timedate &";
      stop.exec = ":kill";
    };
  };
}
