# services.solnix-nm -- the org.freedesktop.NetworkManager D-Bus interface COSMIC's network applet and Settings page call
# (through the nmrs crate), served over illumos dladm/ipadm and solnix-netd: src/solnix-nm, docs/solnix-nm.md.
# NixOS runs NetworkManager itself (networking.networkmanager); it is GPL and Linux-netlink bound, so solnix ships this
# bridge instead, with the same bus name, the same policy shape (root owns the name, anyone may call it, changes need
# root or the networkmanager group, NixOS's gid 57) and the same file rule for secrets (root 0600, outside the store).
#   - networks joined from COSMIC are saved as /etc/wifi/<ssid>.psk (the shape hardware.wirelessIwx.networks.<ssid>.pskFile
#     uses) and listed in /var/lib/solnix-nm/networks; solnix-netd rejoins them like the declared ones;
#   - declared networks (hardware.wirelessIwx/Iwm.networks) show as read-only profiles;
#   - a disconnect or the radio switch writes /var/run/solnix-nm/<link>.down, and solnix-netd leaves that link alone.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.solnix-nm;
  nm = pkgs.solnix.solnix-nm;
  # an SSID as hex (solnix-nm's SOLNIX_NM_DECLARED): printable ASCII only, as an SSID in a Nix attr name is; others throw
  ascii = lib.listToAttrs (lib.imap0 (i: c: lib.nameValuePair c (i + 32)) (lib.stringToCharacters
    " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"));
  hex = s: lib.concatMapStrings (c: lib.toLower (lib.fixedWidthString 2 "0" (lib.toHexString (ascii.${c} or (throw
    "services.solnix-nm: SSID ${lib.strings.escapeNixString s} has a non-ASCII character"))))) (lib.stringToCharacters s);
  nets = config.hardware.wirelessIwx.networks // config.hardware.wirelessIwm.networks;
in
{
  options.services.solnix-nm = {
    enable = lib.mkEnableOption "solnix-nm, the NetworkManager D-Bus interface for COSMIC's network applet and Settings (over dladm/ipadm and solnix-netd)";
  };

  config = lib.mkIf cfg.enable {
    assertions = [{ assertion = config.services.dbus.enable; message = "services.solnix-nm needs services.dbus.enable (the system bus)"; }];
    services.dbus.packages = [ nm ];
    # NixOS: users in the networkmanager group may change connections (networking.networkmanager; ids.nix gid 57)
    users.groups.networkmanager.gid = lib.mkDefault 57;
    networking.solnix-netd.holdDir = "/var/run/solnix-nm";
    smf.services.solnix-nm = {
      enable = true;
      category = "site";
      description = "solnix-nm: the NetworkManager D-Bus interface (COSMIC's network applet) over dladm/ipadm";
      model = "contract";
      requires = [ "svc:/system/dbus:default" "svc:/network/physical:default" ];
      environment = {
        SOLNIX_NM_DECLARED = lib.concatStringsSep " " (lib.mapAttrsToList (ssid: n: "${hex ssid}=${n.pskFile}") nets);
        PATH = "/usr/lib/inet:/usr/sbin:/usr/bin:/sbin:/bin";
      };
      start.exec = "/usr/bin/bash -c ${lib.escapeShellArg "mkdir -p -m 0700 /var/lib/solnix-nm /etc/wifi && mkdir -p -m 0755 /var/run/solnix-nm && exec ${nm}/bin/solnix-nm"} &";
      stop.exec = ":kill";
    };
  };
}
