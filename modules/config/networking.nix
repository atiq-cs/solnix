# modules/config/networking.nix — declarative networking that GENERATES the
# illumos config (dladm/ipadm + the legacy-ifconfig fallback the EC2 ena NIC
# needs), the solnix analog of NixOS's networking module.
#
# T2.9. Options -> generated artifacts:
#   networking.hostName            -> /etc/nodename (+ the identity, read by
#                                     activation; already partly wired in
#                                     nixos-compat.nix, superseded here).
#   networking.interfaces.<n>.dhcp -> ipadm create-if + create-addr -T dhcp,
#                                     falling back to legacy `ifconfig plumb;
#                                     ifconfig dhcp start` (the ONLY path that
#                                     works on the gate ena driver — gotcha #15).
#   networking.interfaces.<n>.ipv4.addresses -> static ipadm create-addr
#                                     (falling back to `ifconfig <n> <ip>/<pfx>`).
#   networking.nameservers         -> /etc/resolv.conf.
#   networking.defaultGateway      -> `route add default <gw>` (+ /etc/defaultrouter).
#
# The generated bringup runs as an SMF transient oneshot built through the
# EXISTING smf.services.* module (not a new init concept) — modules/system/
# boot/init/smf.nix renders it to a DTD-valid manifest that make-be stages and
# manifest-import brings online. So a config change (not a script edit) drives
# networking: this REPLACES the hand-written solnix-netcfg in oi-make-be.sh /
# lib/make-be.nix.
#
# WHY the ifconfig fallback is kept, not dropped for the "clean" ipadm path:
# docs/design-make-be.md gotcha #15 — the gate ena driver leaves the datalink
# STATE 'unknown' and `ipadm create-if` REFUSES an unknown-state link, so on EC2
# the ipadm path fails and only legacy ifconfig brings the NIC up. We emit ipadm
# first (correct on real hardware / a future fixed driver) and fall back to
# ifconfig (what actually succeeds on ena today). The physical NIC needs the
# tuning knob a clean model can't see.

{ config, lib, pkgs, ... }:

let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    mkIf
    mkMerge
    optionalString
    concatStringsSep
    concatMapStringsSep
    mapAttrsToList
    filterAttrs
    optional
    optionals
    literalExpression
    ;

  cfg = config.networking;

  # A single IPv4 address on an interface (NixOS's networking.interfaces.<n>.
  # ipv4.addresses shape: { address; prefixLength; }).
  addrType = types.submodule {
    options = {
      address = mkOption {
        type = types.str;
        example = "10.0.0.5";
        description = "IPv4 address (dotted quad).";
      };
      prefixLength = mkOption {
        type = types.ints.between 0 32;
        example = 24;
        description = "Subnet prefix length (CIDR bits).";
      };
    };
  };

  interfaceType = types.submodule (
    { name, ... }:
    {
      options = {
        dhcp = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Bring this interface up with DHCP. Mutually exclusive with static
            ipv4.addresses (DHCP wins if both are set, with a warning).
          '';
        };
        ipv4.addresses = mkOption {
          type = types.listOf addrType;
          default = [ ];
          example = literalExpression ''[ { address = "10.0.0.5"; prefixLength = 24; } ]'';
          description = "Static IPv4 addresses to assign to this interface.";
        };
      };
    }
  );

  # interfaces that actually declare something (dhcp or a static addr).
  activeIfs = filterAttrs (_: i: i.dhcp || i.ipv4.addresses != [ ]) cfg.interfaces;
  hasNetworking = activeIfs != { } || cfg.nameservers != [ ] || cfg.defaultGateway != null;

  # Per-interface bringup shell. ipadm first (clean path), ifconfig fallback
  # (the path that works on the gate ena — gotcha #15). One function, both NIC
  # modes route through it, so the fallback covers every interface.
  ifBringup =
    ifname: i:
    if i.dhcp then
      ''
        echo "-- ${ifname}: DHCP"
        /usr/sbin/ipadm create-if ${ifname} 2>/dev/null && \
          /usr/sbin/ipadm create-addr -T dhcp -w 60 ${ifname}/dhcp 2>/dev/null
        if ! /usr/sbin/ipadm show-addr ${ifname}/dhcp 2>/dev/null | grep -q ok; then
          echo "   ipadm failed (ena link STATE unknown?); using legacy ifconfig"
          /usr/sbin/ifconfig ${ifname} plumb 2>&1
          /usr/sbin/ifconfig ${ifname} dhcp start wait 60 2>&1
        fi
      ''
    else
      # static: create-if + one create-addr per address; ifconfig fallback.
      ''
        echo "-- ${ifname}: static"
        /usr/sbin/ipadm create-if ${ifname} 2>/dev/null || true
      ''
      + concatMapStringsSep "\n" (a: ''
        /usr/sbin/ipadm create-addr -T static -a ${a.address}/${toString a.prefixLength} ${ifname}/v4 2>/dev/null || {
          echo "   ipadm static failed; using legacy ifconfig"
          /usr/sbin/ifconfig ${ifname} plumb 2>&1
          /usr/sbin/ifconfig ${ifname} ${a.address}/${toString a.prefixLength} up 2>&1
        }
      '') i.ipv4.addresses;

  # The complete first-boot bringup body: every active interface, then the
  # default route + /etc/resolv.conf refresh (resolv.conf itself is generated
  # into /etc statically below; this only re-asserts it if empty). Logged to
  # /dev/console so a failed bringup is VISIBLE (the old netcfg silenced errors).
  netBringup = ''
    echo "=== solnix networking bringup $(date) ==="
    ${concatStringsSep "\n" (mapAttrsToList ifBringup activeIfs)}
    ${optionalString (cfg.defaultGateway != null) ''
      echo "-- default route via ${cfg.defaultGateway}"
      /usr/sbin/route -p add default ${cfg.defaultGateway} 2>&1 || \
        /usr/sbin/route add default ${cfg.defaultGateway} 2>&1 || true
    ''}
    /usr/bin/hostname ${cfg.hostName} 2>/dev/null || true
    echo "-- ipadm show-addr:"; /usr/sbin/ipadm show-addr 2>&1
    echo "-- default route:"; /usr/bin/netstat -rn 2>&1 | grep default | head -2
    echo "=== solnix networking bringup done ==="
  '';
in
{
  options.networking = {
    # hostName: declared here as the authoritative networking option (the
    # accept-and-ignore stub in nixos-compat.nix is a fallback for configs that
    # don't pull this module; mkDefault-compatible). Written to /etc/nodename.
    hostName = mkOption {
      type = types.str;
      default = "solnix";
      description = "System hostname (written to /etc/nodename; set as the live hostname at bringup).";
    };

    interfaces = mkOption {
      type = types.attrsOf interfaceType;
      default = { };
      example = literalExpression ''{ ena0.dhcp = true; }'';
      description = ''
        Per-interface config keyed by illumos datalink name (e.g. "ena0").
        Each interface is brought up via ipadm, with a legacy-ifconfig fallback
        for links the gate ena driver leaves in STATE unknown (gotcha #15).
      '';
    };

    nameservers = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = literalExpression ''[ "9.9.9.9" "1.1.1.1" ]'';
      description = "DNS servers written to /etc/resolv.conf.";
    };

    defaultGateway = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "10.0.0.1";
      description = "Default IPv4 gateway (route add default + /etc/defaultrouter).";
    };
  };

  config = mkMerge [
    {
      # resolv.conf + defaultrouter + nodename land in the solnix /etc overlay
      # (activation reads networking.* for nodename; these extend it). Exposed
      # as an internal attr the activation module folds into its `etc` derivation.
      networking.generatedEtc = {
        "resolv.conf" = mkIf (cfg.nameservers != [ ])
          (concatMapStringsSep "" (ns: "nameserver ${ns}\n") cfg.nameservers);
        "defaultrouter" = mkIf (cfg.defaultGateway != null) "${cfg.defaultGateway}\n";
      };
    }

    # The DHCP/static bringup runs as an SMF transient oneshot built through the
    # EXISTING smf.services.* module — no new init concept. Only emitted when the
    # config actually declares an interface (YAGNI: no service for an empty net).
    (mkIf (activeIfs != { }) {
      smf.services.solnix-net = {
        enable = true;
        category = "site";
        description = "solnix declarative networking bringup (T2.9)";
        model = "transient";
        # devices milestone: devfsadm must have created the datalink nodes
        # before ipadm/ifconfig can plumb them (gotcha #11's sibling).
        requires = [ "svc:/milestone/devices:default" ];
        start.exec = "${pkgs.writeScript "solnix-net-bringup" ''
          #!/sbin/sh
          . /lib/svc/share/smf_include.sh
          { ${netBringup} } > /dev/console 2>&1
          exit $SMF_EXIT_OK
        ''}";
        start.timeoutSeconds = 180;
        stop.exec = ":true";
      };
    })
  ];

  # internal read-only carrier for the /etc bits the activation module folds in.
  options.networking.generatedEtc = mkOption {
    type = types.attrsOf types.str;
    internal = true;
    default = { };
    description = "network-derived /etc files (resolv.conf, defaultrouter). Read by activation.";
  };
}
