# Intel AX2xx wireless (OpenBSD `iwx` driver port) + its proprietary firmware.
#
# The firmware blobs are unfree-redistributable, so they sit behind the standard
# Nix unfree gate. Enabling this option opts in for THIS package only -- it does
# not set allowUnfree globally, which would silently permit unrelated unfree
# packages.
{ config, lib, pkgs, ... }:

let
  cfg = config.hardware.wirelessIwx;
in
{
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

  config = lib.mkIf cfg.enable (lib.mkMerge [
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
  ]);
}
