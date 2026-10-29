# services.dbus -- the D-Bus system bus, NixOS's option names (nixos/modules/services/system/dbus.nix).
# NixOS always runs it; here it is off unless something needs it (COSMIC turns it on).
# Like NixOS: dbus-daemon --system from the store, the messagebus user, /etc/dbus-1/system.conf
# that includes the system.d policy files of services.dbus.packages (cosmic-greeter's
# com.system76.CosmicGreeter.conf). Departures: an SMF service instead of a systemd unit, the
# socket at /var/run/dbus/system_bus_socket (zbus's and libdbus's compiled-in default), no
# activation helper (a setuid launcher; nothing here is bus-activated).
{ config, lib, pkgs, ... }:
let
  cfg = config.services.dbus;
  inherit (lib) mkOption mkEnableOption types mkIf concatMapStringsSep;
  dbus = pkgs.solnix.dbus;
  systemConf = ''
    <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
     "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
    <busconfig>
      <type>system</type>
      <user>messagebus</user>
      <fork/>
      <pidfile>/var/run/dbus/pid</pidfile>
      <syslog/>
      <auth>EXTERNAL</auth>
      <listen>unix:path=/var/run/dbus/system_bus_socket</listen>
      <!-- the default policy of the package's system.conf, which cannot be included: its
           listen and pidfile are store paths (the package's localstatedir) -->
      <policy context="default">
        <allow user="*"/>
        <deny own="*"/>
        <deny send_type="method_call"/>
        <allow send_type="signal"/>
        <allow send_requested_reply="true" send_type="method_return"/>
        <allow send_requested_reply="true" send_type="error"/>
        <allow receive_type="method_call"/>
        <allow receive_type="method_return"/>
        <allow receive_type="error"/>
        <allow receive_type="signal"/>
        <allow send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus"/>
        <allow send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus.Introspectable"/>
        <allow send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus.Properties"/>
        <deny send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus" send_member="UpdateActivationEnvironment"/>
      </policy>
    ${concatMapStringsSep "\n" (p: "  <includedir>${p}/share/dbus-1/system.d</includedir>") cfg.packages}
    </busconfig>
  '';
in
{
  options.services.dbus = {
    enable = mkEnableOption "the D-Bus system bus";
    packages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Packages whose share/dbus-1/system.d policy files the system bus loads.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ dbus ];
    environment.generatedEtc."dbus-1/system.conf" = systemConf;
    users.groups.messagebus.gid = 30081;
    users.users.messagebus = {
      uid = 30081; group = "messagebus"; description = "D-Bus system bus";
      home = "/var/run/dbus"; shell = "/usr/bin/false"; hashedPassword = null;
    };
    smf.services.dbus = {
      enable = true;
      category = "system"; description = "D-Bus system message bus";
      # --fork: the daemon returns once the socket listens, so dependents start after it.
      start.exec = "/usr/bin/bash -c ${lib.escapeShellArg "mkdir -p -m 0755 /var/run/dbus && ${dbus}/bin/dbus-uuidgen --ensure=/var/lib/dbus/machine-id && ${dbus}/bin/dbus-daemon --system --config-file=/etc/dbus-1/system.conf"}";
      requires = [ "svc:/system/filesystem/local:default" ];
    };
  };
}
