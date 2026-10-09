# Intel wireless via the OpenBSD driver ports, + their proprietary firmware.
#
#   hardware.wirelessIwx  AX2xx (OpenBSD iwx, src/wifi-port/iwx)
#   hardware.wirelessIwm  AC 7260..9560 (OpenBSD iwm, src/wifi-port/iwm). The X1
#                         "dixi" carries an AC 9560 (8086:a370), an iwm device,
#                         not iwx; see src/wifi-port/iwm/STATUS.md.
#
# The firmware blobs are unfree-redistributable, so they sit behind the standard
# Nix unfree gate. Enabling this option opts in for THIS package only -- it does
# not set allowUnfree globally, which would silently permit unrelated unfree
# packages.
#
# wirelessIwm today only puts the firmware in the system closure (built and
# kept). NOT yet emitted (PLANNED; needs install-be.sh to merge extra
# driver-database lines, since it copies pkgs.solnix.drivers verbatim at
# install-be.sh:221, and the driver to be packaged):
#   name_to_major  iwm <N>
#   driver_aliases iwm "pciex8086,a370"
#   minor_perm     iwm:* 0666 root sys   and   clone:iwm 0666 root sys
#   kernel/drv/amd64/iwm and kernel/firmware/iwm/iwm-9000-46 in the BE's kernel tree.
# Those make the card attach at boot; the driver has never attached on hardware,
# so a config option that binds it at boot is deliberately not offered yet.
{ config, lib, pkgs, ... }:

let
  cfg = config.hardware.wirelessIwx;
  iwm = config.hardware.wirelessIwm;
in
{
  options.hardware.wirelessIwm = {
    enable = lib.mkEnableOption "Intel AC 7260-9560 wireless via the iwm driver (firmware only, for now)";

    allowUnfreeFirmware = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Permit fetching Intel's proprietary iwlwifi firmware
        (iwlwifi-9000-pu-b0-jf-b0-46.ucode, installed as iwm-9000-46). The
        driver is BSD-licensed; the firmware is redistributable but not open.
      '';
    };
  };

  options.hardware.wirelessIwx = {
    enable = lib.mkEnableOption "Intel AX2xx wireless via the iwx driver";

    allowUnfreeFirmware = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Permit fetching Intel's proprietary iwlwifi firmware blobs.

        The driver is BSD-licensed, but the firmware is not open. Without this
        the build stops with an unfree-licence error naming the package. The
        installer sets this to true, since a laptop with no ethernet jack cannot
        be installed over the network otherwise.
      '';
    };

    apiRev = lib.mkOption {
      type = lib.types.str;
      default = "77";
      description = ''
        Firmware API revision. Must match what the vendored driver expects --
        iwx verifies it at attach and refuses a mismatch, so a bump here without
        a corresponding driver update yields a card that never associates.
      '';
    };
  };

  config = lib.mkMerge [
  (lib.mkIf iwm.enable {
    assertions = [{
      assertion = iwm.allowUnfreeFirmware;
      message = ''
        hardware.wirelessIwm.enable requires Intel's proprietary firmware; the
        AC 9560 does not run without it. Set
        hardware.wirelessIwm.allowUnfreeFirmware = true to accept
        LICENCE.iwlwifi_firmware.
      '';
    }];
    environment.systemPackages = [
      (import ../../pkgs/illumos/iwm-firmware.nix {
        acceptFirmwareLicense = iwm.allowUnfreeFirmware;
      })
    ];
  })
  (lib.mkIf cfg.enable (lib.mkMerge [
    {
      # Fail at EVAL with an actionable message rather than at fetch time with an
      # opaque licence error from deep inside the firmware derivation.
      assertions = [{
        assertion = cfg.allowUnfreeFirmware;
        message = ''
          hardware.wirelessIwx.enable requires proprietary Intel firmware.

          AX2xx hardware does not function without it -- there is no free
          alternative blob, on any operating system.

          Set hardware.wirelessIwx.allowUnfreeFirmware = true to accept
          Intel's redistributable-firmware licence, or leave this module
          disabled and use USB ethernet / a USB wifi adapter with a chipset
          illumos already drives (urtw, rum, ural, zyd, atu).
        '';
      }];

      environment.systemPackages = [
        (pkgs.callPackage ../../pkgs/illumos/iwx-firmware.nix {
          apiRev = cfg.apiRev;
          # Threads the opt-in through to the real gate in the derivation.
          acceptFirmwareLicense = cfg.allowUnfreeFirmware;
        })
      ];
    }
  ]))
  ];
}
