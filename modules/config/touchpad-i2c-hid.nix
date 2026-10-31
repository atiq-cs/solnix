# The ThinkPad X1 Extreme Gen 5 touchpad: an ELAN HID-over-I2C device behind
# the Alder Lake-P LPSS I2C0 controller (pkgs.solnix.touchpad-driver: dwiic +
# ihid, src/ports/touchpad).
#
#   hardware.touchpad.i2cHid.enable   lay dwiic and ihid into the BE kernel
#       tree, bind dwiic to pkgs.solnix.touchpadAliases (8086:51e8), add ihid
#       (no alias) and the dacf.conf rule that links ihid under consms with
#       usbms pushed, and run solnix-touchpad at boot, which creates the i2c
#       device ihid binds to. Default off: the drivers ship unbound.
#
# Why an SMF one-shot: the illumos i2c framework creates a device node only
# from the UI2C_IOCTL_DEVICE_ADD ioctl (`i2cadm device add`); no driver can
# add one, and nothing persists it across boots. ihid then finds its ACPI node
# (TPD0) by I2cSerialBus address and reads the HID descriptor register from
# _DSM. The pointer reaches consms, so /dev/mouse (cosmic-comp via seatd) and
# the text console see the touchpad and the PS/2 TrackPoint together.
#
# The driver DB and kernel tree are rendered with the wifi and GPU drivers'
# in modules/config/wireless-iwx.nix; this file holds the option and the
# service.
{ config, lib, pkgs, ... }:
let
  cfg = config.hardware.touchpad.i2cHid;
in
{
  options.hardware.touchpad.i2cHid = {
    enable = lib.mkEnableOption "the X1E Gen 5 HID-over-I2C touchpad (dwiic + ihid, linked under consms)";
    address = lib.mkOption {
      type = lib.types.strMatching "0x[0-9a-fA-F]{1,2}";
      default = "0x15";
      description = ''
        The touchpad's 7-bit I2C address on dwiic0/0: 0x15 for the ELAN0686 part
        (lixi), 0x2c for the Synaptics SYNA801D variant the same DSDT describes.
        ihid refuses an address with no ACPI node.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    smf.services.solnix-touchpad = {
      enable = true;
      category = "system";
      description = "add the HID-over-I2C touchpad device (ihid) on dwiic0";
      model = "transient";
      start = {
        exec = "/bin/sh ${pkgs.writeText "solnix-touchpad.sh" ''
          # devfsadm -i attaches dwiic (and so its i2cnex) before i2cadm looks for it.
          /usr/sbin/devfsadm -i dwiic >/dev/null 2>&1
          /usr/sbin/i2cadm device list -Hpo path 2>/dev/null | grep -qx dwiic0/0/${cfg.address} && exit 0
          exec /usr/sbin/i2cadm device add dwiic0/0 ihid ${cfg.address}
        ''}";
        timeoutSeconds = 60;
      };
      stop.exec = ":true";
      requires = [ "svc:/system/filesystem/local:default" ];
    };
  };
}
