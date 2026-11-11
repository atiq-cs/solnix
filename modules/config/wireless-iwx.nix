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
#
# wirelessIwx mirrors it: hardware.wirelessIwx.attachAtBoot renders iwx's
# name_to_major/driver_aliases/minor_perm lines and lays kernel/drv/amd64/iwx +
# kernel/firmware/iwx/* (pkgs.solnix.iwx-driver, iwx-firmware). The iwx module
# loads on the solnix kernel but has never attached to an AX2xx, so this is
# opt-in too.
#
# hardware.wirelessIntel.onMedia (installer media): both modules and both
# firmware sets are laid into the kernel tree and both drivers get a major and
# minor_perm, but NO alias, so nothing binds at boot (an unproven driver that
# panicked at attach would make the media unusable). One command binds a card
# at run time: `update_drv -a -i '"pciex8086,51f0"' iwx` (see
# docs/x1e-wifi-runtime-bind.md).
{ config, lib, pkgs, options, ... }:

let
  cfg = config.hardware.wirelessIwx;
  iwm = config.hardware.wirelessIwm;
  media = config.hardware.wirelessIntel.onMedia;
  s = pkgs.solnix;

  # The final driver DB and kernel tree, composed from whichever of the three
  # switches are on. iwm first (its helpers take no base), then iwx on top.
  # bind decides only whether the alias lines are written.
  iwmBound = iwm.enable && iwm.attachAtBoot;
  iwxBound = cfg.enable && cfg.attachAtBoot;
  wantIwm = iwmBound || media;
  wantIwx = iwxBound || media;
  iwmDb = if iwmBound then s.mkIwmDriversDb else s.mkIwmDriversDbUnbound;
  dbWithIwm = if wantIwm then iwmDb else s.drivers;
  # the firmware licence opt-in: the per-driver option, or onMedia (whose
  # description says it accepts the licence for the media).
  kernWithIwm = if wantIwm then s.mkIwmKernel (iwm.allowUnfreeFirmware || media) else s.kernel;
  wifiDb = if wantIwx then s.mkIwxDriversDb dbWithIwm iwxBound else dbWithIwm;
  wifiKern = if wantIwx then s.mkIwxKernel kernWithIwm (cfg.allowUnfreeFirmware || media) else kernWithIwm;
  # GPU drivers (options in ./graphics-gpu.nix) on top of the wifi DB/kernel:
  # i915 always when wanted, nvidia only on media; aliases only when bound.
  gfx = config.hardware.graphics;
  i915Bound = gfx.i915.attachAtBoot;
  nvBound = gfx.nvidia.attachAtBoot;
  nvMedia = gfx.onMedia && gfx.nvidia.onMedia;
  wantNv = nvMedia || nvBound;
  wantGpu = gfx.onMedia || i915Bound || nvBound;
  gpuDrivers = [ { name = "i915"; perm = "0666 root sys"; aliases = if i915Bound then s.i915Aliases else [ ]; } ]
    ++ lib.optionals nvMedia nvDrivers;
  nvDrivers = [
      { name = "nvidia"; perm = "0666 root sys"; aliases = if nvBound then s.nvidiaAliases else [ ]; }
      { name = "nvidia_modeset"; perm = "0666 root sys"; aliases = [ ]; }
      { name = "nvidia_i2c"; perm = null; aliases = [ ]; }
    ];
  gpuDb = if wantGpu then s.mkDriversDbWith wifiDb gpuDrivers else wifiDb;
  gpuKern0 = if wantGpu then s.mkGpuKernel wifiKern {
    nvidia = wantNv;
    gspFirmware = if nvMedia && gfx.nvidia.acceptFirmwareLicense then s.nvidiaGspFirmware true else null;
    i915Firmware = if gfx.i915.acceptFirmwareLicense then s.i915Firmware true else null;
  } else wifiKern;
  # nvidia bound at boot: nvidia.conf, tzmon's opt-out (none with rtd3), GSP firmware in usr/kernel (graphics-gpu.nix).
  gpuKern = if nvBound then s.mkNvidiaBootKernel gpuKern0 (s.nvidiaGspFirmware gfx.nvidia.acceptFirmwareLicense)
    { rtd3 = gfx.nvidia.rtd3; } else gpuKern0;
  # the touchpad (options in ./touchpad-i2c-hid.nix) last: dwiic + ihid, the dacf rule.
  wantTouchpad = config.hardware.touchpad.i2cHid.enable;
  tpDb = if wantTouchpad then s.mkTouchpadDriversDb gpuDb else gpuDb;
  # audiohd's extra controller ids (./audio-hda.nix): the stock aliases plus these; the helper checks the count.
  hdaIds = config.hardware.audio.hdaIds;
  wantHda = hdaIds != [ ];
  finalDb0 = if wantHda then s.mkDriversDbWith tpDb [ { name = "audiohd"; perm = null;
    aliases = lib.unique ([ "pci10de,371" "pci8086,2668" "pciclass,0403" "pciexclass,0403" ] ++ hdaIds); } ] else tpDb;
  # nvidia bound at boot: its majors go in LAST, so the drivers already installed keep theirs (dwiic and ihid
  # would move by three if nvidia came before the touchpad layer).
  finalDb = if nvBound then s.mkNvidiaBootDb (s.mkDriversDbWith finalDb0 nvDrivers) else finalDb0;
  finalKern = if wantTouchpad then s.mkTouchpadKernel gpuKern else gpuKern;

  # Networks highest priority first; each line "SSID<TAB>pskFile".
  sortNets = nets: lib.sort (a: b: a.priority > b.priority)
    (lib.mapAttrsToList (ssid: n: { inherit ssid; inherit (n) pskFile priority; }) nets);
  # One join script per driver: the link (iwm0 / iwx0) and that driver's networks. Both drivers run WPA2's 4-way
  # in-kernel through the same OpenBSD net80211 port, so the mechanism below is shared.
  mkWifiJoinScript = link: nets: pkgs.writeText "solnix-wifi-join-${link}.sh" ''
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
    link=${link}
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
    ${lib.concatMapStringsSep "\n    " (n: ''try ${lib.escapeShellArg n.ssid} ${lib.escapeShellArg n.pskFile} && exit 0'') (sortNets nets)}
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

  options.hardware.wirelessIntel.onMedia = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Put BOTH Intel wifi drivers (iwm: AC 7260-9560; iwx: AX210/AX211) and
      their firmware into the kernel tree, with a name_to_major and minor_perm
      entry each but NO driver_aliases line, so neither attaches at boot.
      For installer media: the drivers are present for a one-command runtime
      bind (update_drv -a -i '"pciex8086,51f0"' iwx) without risking a boot-time
      attach of a driver that has never run on that silicon. Accepts Intel's
      redistributable firmware licence (the firmware is laid into the tree).
    '';
  };

  options.hardware.wirelessIwx = {
    enable = lib.mkEnableOption "Intel AX2xx wireless via the iwx driver";

    attachAtBoot = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Bind the iwx driver at boot: render name_to_major / driver_aliases
        (the AX210/AX211 pciex ids, pkgs.solnix.iwxAliases) / minor_perm and
        lay kernel/drv/amd64/iwx + kernel/firmware/iwx/* into the BE kernel
        tree, as hardware.wirelessIwm.attachAtBoot does for iwm. Defaults to
        false: the module loads on the solnix kernel but has never attached to
        an AX2xx. Requires allowUnfreeFirmware.
      '';
    };

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

    networks = lib.mkOption {
      default = { };
      description = ''
        WPA2 networks for the AX2xx (iwx0) to join at boot, by SSID: the same shape as
        hardware.wirelessIwm.networks. The passphrase is never in the store: pskFile names
        a root-owned 0600 file on the installed system whose first line is the passphrase.
        Needs attachAtBoot. After the join, iwx0 gets DHCP from the solnix-wifi-join
        service (DNS from the lease when networking.nameservers is empty).
      '';
      type = options.hardware.wirelessIwm.networks.type;
      example = lib.literalExpression ''{ sedgwick.pskFile = "/etc/wifi/sedgwick.psk"; }'';
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
    # (system.build.driversDb / kernelTree are set in the shared block below,
    # which composes iwm and iwx.)

    # Boot auto-join: scan, pick the highest-priority configured SSID in range,
    # read its PSK from the 0600 file, join. Transient run-once. The driver-DB
    # lines + the module/firmware that make iwm attach at boot are rendered into
    # system.build.{driversDb,kernelTree} above (hardware.wirelessIwm.attachAtBoot);
    # this service runs after the card is up and calls wpa-pmk (on /usr/bin via
    # pkgs.solnix.wpa-pmk) ESSID-only with a bounded retry.

    # With solnix-netd (./solnix-netd.nix, on by default when networks are set) the daemon runs the same join
    # script whenever iwm0 is disconnected, so this one-shot is only for configs that turn the daemon off.
    networking.solnix-netd.wifiJoin = lib.mkIf (iwm.networks != { }) { iwm0 = mkWifiJoinScript "iwm0" iwm.networks; };
    smf.services.solnix-wifi-join = lib.mkIf (iwm.networks != { } && !config.networking.solnix-netd.enable) {
      enable = true;
      category = "site";
      description = "solnix iwm wifi auto-join";
      model = "transient";
      start = {
        exec = "/bin/sh ${mkWifiJoinScript "iwm0" iwm.networks}";
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
        (import ../../pkgs/illumos/iwx-firmware.nix {
          apiRev = cfg.apiRev;
          # Threads the opt-in through to the real gate in the derivation.
          acceptFirmwareLicense = cfg.allowUnfreeFirmware;
        })
      ]
      # The join tool, whenever the card is bound at boot (as for iwm).
      ++ lib.optional cfg.attachAtBoot pkgs.solnix.wpa-pmk;
    }
    {
      assertions = [{
        assertion = cfg.networks == { } || cfg.attachAtBoot;
        message = "hardware.wirelessIwx.networks needs hardware.wirelessIwx.attachAtBoot: an unbound card has no iwx0 to join.";
      }];
    }
    # Boot auto-join on iwx0, then DHCP on it (the join must come first: a lease on an unassociated link never comes).
    # solnix-netd keeps iwx0 joined (and DHCP on it) for as long as the system runs; this one-shot is the
    # fallback for configs that turn the daemon off.
    (lib.mkIf (cfg.networks != { }) {
      networking.solnix-netd.wifiJoin.iwx0 = mkWifiJoinScript "iwx0" cfg.networks;
    })
    (lib.mkIf (cfg.networks != { } && !config.networking.solnix-netd.enable) {
      smf.services.solnix-wifi-join-iwx = {
        enable = true;
        category = "site";
        description = "solnix iwx wifi auto-join + DHCP";
        model = "transient";
        start = {
          exec = "/bin/sh ${pkgs.writeText "solnix-wifi-join-iwx-dhcp.sh" ''
            /bin/sh ${mkWifiJoinScript "iwx0" cfg.networks} || exit 0
            [ "$(/usr/sbin/dladm show-wifi -p -o status iwx0 2>/dev/null)" = connected ] || exit 0
            /usr/sbin/ipadm create-if iwx0 2>/dev/null
            /usr/sbin/ipadm show-addr -p -o type iwx0/ 2>/dev/null | grep -q '^dhcp$' \
              || /usr/sbin/ipadm create-addr -T dhcp -w 60 iwx0/dhcp 2>&1
            ${lib.optionalString (config.networking.nameservers == [ ]) ''
              ns=$(/sbin/dhcpinfo -i iwx0 DNSserv 2>/dev/null)
              [ -n "$ns" ] && [ ! -s /etc/resolv.conf ] && { for x in $ns; do echo "nameserver $x"; done > /etc/resolv.conf; }
            ''}
            exit 0
          ''}";
          timeoutSeconds = 240;
        };
        stop.exec = ":true";
        requires = [ "svc:/network/physical:default" ];
      };
    })
  ]))
  # The driver DB and kernel tree, rendered from iwm/iwx/onMedia and the GPU
  # options together so the drivers compose instead of overriding each other.
  (lib.mkIf (wantIwm || wantIwx || wantGpu || wantTouchpad || wantHda) {
    system.build.driversDb = finalDb;
    system.build.kernelTree = finalKern;
  })
  # With the drivers on the media for a runtime bind, the WPA2 join tool must be
  # there too: docs/x1e-wifi-runtime-bind.md runs wpa-pmk right after update_drv.
  (lib.mkIf media {
    environment.systemPackages = [ pkgs.solnix.wpa-pmk ];
  })
  # nvidia bound at boot (graphics-gpu.nix). tzmon leaves the dGPU powered in this BE, so the thermal guard runs
  # from as early as SMF starts anything (a single-user dependent, like the early services that need no /nix
  # writes) and reboots at maxTempC or an unreadable sensor. The bring-up waits for the guard and the dump device,
  # so a first-attach panic leaves a dump.
  (lib.mkIf nvBound {
    environment.systemPackages = [ s.nvidia-probe ];
    smf.services.solnix-nvidia-guard = {
      enable = true;
      category = "site";
      description = "solnix dGPU thermal guard (EC GPUT)";
      model = "contract";
      dependents = [ "svc:/milestone/single-user:default" ];
      environment = {
        MAXT = toString gfx.nvidia.maxTempC;
        INTERVAL = "3";
        LOG = "/var/log/solnix-nvidia.log";
      } // lib.optionalAttrs gfx.nvidia.rtd3 { EXPECT_OFF = "1"; };
      start.exec = "/bin/sh ${./nvidia-guard.sh} &";
      stop.exec = ":kill";
    };
    smf.services.solnix-nvidia = {
      enable = true;
      category = "site";
      description = "solnix nvidia dGPU bring-up (RmInitAdapter, GSP) after the dump device";
      model = "contract";
      requires = [ "svc:/site/solnix-nvidia-guard:default" "svc:/system/dumpadm:default" "svc:/system/filesystem/local:default" ];
      environment = {
        PROBE = "${s.nvidia-probe}/bin/nvidia-probe";
        LOG = "/var/log/solnix-nvidia.log";
      } // lib.optionalAttrs gfx.nvidia.rtd3 { RTD3 = "1"; };
      start.exec = "/bin/sh ${./nvidia-up.sh} &";
      stop.exec = ":kill";
    };
  })
  ];
}
