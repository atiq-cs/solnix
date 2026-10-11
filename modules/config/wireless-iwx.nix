# Intel wireless via the OpenBSD driver ports, + their proprietary firmware.
#
#   hardware.wirelessIwx  AX2xx (OpenBSD iwx, src/ports/wifi/iwx)
#   hardware.wirelessIwm  AC 7260..9560 (OpenBSD iwm, src/ports/wifi/iwm). The X1
#                         "dixi" carries an AC 9560 (8086:a370), an iwm device,
#                         not iwx; see src/ports/wifi/iwm/STATUS.md.
#
# The firmware blobs are unfree-redistributable, so they sit behind the standard
# Nix unfree gate. Enabling this option opts in for THIS package only -- it does
# not set allowUnfree globally, which would silently permit unrelated unfree
# packages.
#
# wirelessIwm puts the firmware in the system closure (built and kept) and, when
# hardware.wirelessIwm.attachAtBoot is set, binds the card at boot by rendering
# the final driver database and kernel tree that install-be lays into the BE
# (it copies pkgs.solnix.drivers and the kernel slice verbatim, so the config
# renders the final DB -- the NixOS way -- rather than install-be merging lines):
#   name_to_major  iwm <lowest-free-major>   (allocated like the gate's gen.py)
#   driver_aliases iwm "pciex8086,a370"
#   minor_perm     iwm:* 0666 root sys   and   clone:iwm 0666 root sys
#   kernel/drv/amd64/iwm and kernel/firmware/iwm/iwm-9000-46 in the BE kernel tree.
# The module itself is pkgs.solnix.iwm-driver, a pure derivation built from
# src/ports/wifi/iwm (see pkgs/illumos/iwm-driver.nix). The driver attaches,
# loads firmware, associates (WPA2/CCMP) and passes traffic on the X1 (measured),
# but it is still young, so attachAtBoot is opt-in and defaults to false -- a
# fresh solnix install does not auto-bind an experimental driver. Set it true
# per host (e.g. dixi) to bind the card at boot.
{ config, lib, pkgs, ... }:

let
  cfg = config.hardware.wirelessIwx;
  iwm = config.hardware.wirelessIwm;

  # Networks highest priority first; each line "SSID<TAB>pskFile".
  iwmNets = lib.sort (a: b: a.priority > b.priority)
    (lib.mapAttrsToList (ssid: n: { inherit ssid; inherit (n) pskFile priority; }) iwm.networks);
  wifiJoinScript = pkgs.writeText "solnix-wifi-join.sh" ''
    # Join the first configured SSID that is in range. PSKs are read at RUN
    # time from their 0600 files (never baked into this store-readable script).
    #
    # Mechanism: the OpenBSD iwm port runs WPA2's 4-way handshake IN-KERNEL
    # (not via wpad). wpa-pmk derives the PMK (PBKDF2) from the passphrase and
    # sets it on the link via the _wpa_psk private property; the driver then
    # scans, associates to the strongest matching WPA/CCMP AP, and runs the
    # 4-way. ESSID-only: do NOT pin a BSSID -- a hard pin turns one AP's
    # transient 802.11 status-30 (TRY_AGAIN_LATER) into a persistent cascade,
    # whereas ESSID-only lets the driver pick another AP of the same ESSID
    # (match_bss already excludes WEP/open when RSN is on). The AP's residual
    # occasional status-30 is handled by a bounded retry. Runs as root (SMF).
    set -u
    PATH=/usr/lib/inet:/usr/sbin:/usr/bin:/sbin:/bin
    link=iwm0
    dladm show-phys "$link" >/dev/null 2>&1 || { echo "solnix-wifi-join: no $link"; exit 0; }
    scan=$(dladm scan-wifi -p -o essid "$link" 2>/dev/null)
    joined() { [ "$(dladm show-wifi -p -o status "$link" 2>/dev/null)" = connected ]; }
    try() {
      ssid="$1"; pskfile="$2"
      printf '%s\n' "$scan" | grep -Fxq "$ssid" || return 1
      [ -r "$pskfile" ] || { echo "solnix-wifi-join: $pskfile unreadable"; return 1; }
      # up to 4 attempts to ride through the AP's intermittent status-30.
      i=0
      while [ $i -lt 4 ]; do
        wpa-pmk -f "$pskfile" "$ssid" "$link" >/dev/null 2>&1
        j=0; while [ $j -lt 8 ]; do joined && { echo "solnix-wifi-join: connected $ssid"; return 0; }; sleep 2; j=$((j+1)); done
        i=$((i+1))
      done
      return 1
    }
    ${lib.concatMapStringsSep "\n    " (n: ''try ${lib.escapeShellArg n.ssid} ${lib.escapeShellArg n.pskFile} && exit 0'') iwmNets}
    echo "solnix-wifi-join: no configured SSID in range"; exit 0
  '';
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

    attachAtBoot = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Bind the iwm driver at boot: render the name_to_major / driver_aliases /
        minor_perm lines and lay the module + firmware into the BE kernel tree
        (via system.build.driversDb / system.build.kernelTree), so the AC 9560
        (pciex8086,a370) attaches as iwm0 without a manual add_drv. The module is
        pkgs.solnix.iwm-driver, built from src/ports/wifi/iwm.

        Defaults to false (opt-in): the driver has never attached on hardware
        (src/ports/wifi/iwm/STATUS.md rung 24 is PLANNED), and the module build
        needs the illumos toolchain (dixi/EC2), so a config does not pull it
        unless the wifi is actually wanted. Requires allowUnfreeFirmware (the
        firmware is laid into the kernel tree). Set it true on a system where the
        attach has been approved.
      '';
    };

    networks = lib.mkOption {
      default = { };
      description = ''
        WPA2 networks to join automatically at boot, by SSID. The driver scans
        on boot and joins the first configured SSID that is in range.

        The pre-shared key is NOT stored here (it would land world-readable in
        the Nix store). Set pskFile to a path, present on the installed system,
        that holds the passphrase on its first line, mode 0600. On NixOS this is
        networking.wireless secrets; the analog here is a plain root-owned file
        (sops/agenix can render it).
      '';
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          pskFile = lib.mkOption {
            type = lib.types.str;
            description = "Path to a 0600 file whose first line is the WPA2 passphrase for this SSID.";
          };
          priority = lib.mkOption {
            type = lib.types.int;
            default = 0;
            description = "Higher wins when several configured SSIDs are in range at boot.";
          };
        };
      });
      example = lib.literalExpression ''{ sedgwick.pskFile = "/etc/wifi/sedgwick.psk"; }'';
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
    }
    {
      # attachAtBoot lays the firmware blob into the BE kernel tree (mkIwmKernel
      # pulls iwm-firmware, which throws without the opt-in), so it cannot be set
      # without accepting the licence.
      assertion = !iwm.attachAtBoot || iwm.allowUnfreeFirmware;
      message = ''
        hardware.wirelessIwm.attachAtBoot lays Intel's firmware into the BE
        kernel tree. Set hardware.wirelessIwm.allowUnfreeFirmware = true.
      '';
    }];

    environment.systemPackages = [
      (import ../../pkgs/illumos/iwm-firmware.nix {
        acceptFirmwareLicense = iwm.allowUnfreeFirmware;
      })
    ]
    # When the card attaches at boot, ship wpa-pmk on the system PATH
    # (sw/bin -> /usr/bin/wpa-pmk) so solnix-wifi-join finds it. Only when
    # attachAtBoot: without the driver bound there is nothing for it to talk to.
    ++ lib.optional iwm.attachAtBoot pkgs.solnix.wpa-pmk;

    # attachAtBoot: render the FINAL driver DB and kernel tree so install-be lays
    # an iwm-aware system with no manual add_drv and no install-be change (it
    # copies name_to_major/driver_aliases/minor_perm and the kernel tree
    # verbatim). The DB gets name_to_major iwm <lowest-free-major>, driver_aliases
    # iwm "pciex8086,a370" and minor_perm iwm:*/clone:iwm; the kernel tree gets
    # kernel/drv/amd64/iwm and kernel/firmware/iwm/iwm-9000-46. This is the NixOS
    # model: the config renders the database, the activation step just copies it.
    system.build.driversDb = lib.mkIf iwm.attachAtBoot pkgs.solnix.mkIwmDriversDb;
    system.build.kernelTree = lib.mkIf iwm.attachAtBoot
      (pkgs.solnix.mkIwmKernel iwm.allowUnfreeFirmware);

    # Boot auto-join: scan, pick the highest-priority configured SSID in range,
    # read its PSK from the 0600 file, join. Transient run-once. The driver-DB
    # lines + the module/firmware that make iwm attach at boot are rendered into
    # system.build.{driversDb,kernelTree} above (hardware.wirelessIwm.attachAtBoot);
    # this service runs after the card is up and calls wpa-pmk (on /usr/bin via
    # pkgs.solnix.wpa-pmk) ESSID-only with a bounded retry.

    smf.services.solnix-wifi-join = lib.mkIf (iwm.networks != { }) {
      enable = true;
      category = "site";
      description = "solnix iwm wifi auto-join";
      model = "transient";
      start = {
        exec = "/bin/sh ${wifiJoinScript}";
        timeoutSeconds = 120;
      };
      stop.exec = ":true";
      requires = [ "svc:/network/physical:default" ];
    };
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
