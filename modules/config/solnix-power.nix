# services.solnix-power -- org.freedesktop.UPower and org.freedesktop.UPower.PowerProfiles for COSMIC (Settings > Power,
# the battery applet, cosmic-settings-daemon, cosmic-idle), over acpi_drv's kstats and /etc/power.conf: src/solnix-power,
# docs/solnix-power.md. NixOS's cosmic module turns on upower and power-profiles-daemon; both are GPL, so solnix ships
# this instead, with the same bus names and the same policy shape (root owns the names, anyone reads; a profile change
# needs root or the seat group, the analog of power-profiles-daemon's polkit allow_active).
{ config, lib, pkgs, ... }:
let
  cfg = config.services.solnix-power;
  pw = pkgs.solnix.solnix-power;
in
{
  options.services.solnix-power = {
    enable = lib.mkEnableOption "solnix-power, the UPower and power-profiles D-Bus interfaces for COSMIC (battery and power mode, over acpi_drv and cpupm)";
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      { assertion = config.services.dbus.enable; message = "services.solnix-power needs services.dbus.enable (the system bus)"; }
      { assertion = config.solnix.powerManagement.enable; message = "services.solnix-power sets cpupm through svc:/system/power (solnix.powerManagement.enable)"; }
    ];
    services.dbus.packages = [ pw ];
    smf.services.solnix-power = {
      enable = true;
      category = "site";
      description = "solnix-power: UPower and power profiles on the system bus (acpi_drv, cpupm)";
      model = "contract";
      requires = [ "svc:/system/dbus:default" "svc:/system/power:default" ];
      environment.PATH = "/usr/sbin:/usr/bin:/sbin:/bin";
      start.exec = "${pw}/bin/solnix-power &";
      stop.exec = ":kill";
    };
  };
}
