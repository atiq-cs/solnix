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
    types
    mkIf
    mkMerge
    optionalString
    concatStringsSep
    concatMapStringsSep
    mapAttrsToList
    filterAttrs
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
  # With solnix-netd on (./solnix-netd.nix), it runs every DHCP link and solnix-net keeps the static ones.
  netd = cfg.solnix-netd.enable;
  activeIfs = filterAttrs (_: i: (i.dhcp && !netd) || (!i.dhcp && i.ipv4.addresses != [ ])) cfg.interfaces;
  hasNetworking = activeIfs != { } || cfg.nameservers != [ ] || cfg.defaultGateway != null || cfg.useDHCP;
  dhcpIfs = lib.attrNames (filterAttrs (_: i: i.dhcp) activeIfs);
  # Names a config has decided about (any entry, dhcp or not): useDHCP leaves these alone.
  namedIfs = lib.attrNames cfg.interfaces;

  # How long a DHCP interface may take to appear. NixOS's dhcpcd waits for links
  # through its hotplug handling; this path has no hotplug hook, so each DHCP
  # interface polls for its datalink, bounded. A USB NIC attaches after
  # network/physical has run: the X1E's usbecm0 (RTL8153 on the TB4 xHCI) came up
  # 2 min after multi-user (17:10:27 -> 17:12:29).
  linkWaitSeconds = 300;

  # Per-interface bringup shell. ipadm first (clean path), ifconfig fallback
  # (the path that works on the gate ena — gotcha #15). One function, both NIC
  # modes route through it, so the fallback covers every interface.
  ifBringup =
    ifname: i:
    if i.dhcp then
      ''
        echo "-- ${ifname}: DHCP"
        __w=0
        until /usr/sbin/dladm show-phys ${ifname} >/dev/null 2>&1; do
          [ $__w -ge ${toString linkWaitSeconds} ] && break
          sleep 2; __w=$((__w + 2))
        done
        [ $__w -gt 0 ] && echo "   ${ifname}: waited $__w s for the datalink"
        # A link that appeared after network/physical has its persistent ipadm
        # config (made by create-if below on an earlier boot) still disabled:
        # enable it as net-physical's bringup_ipif does. create-if then reports
        # the interface exists, and the existing addrobj gets its lease.
        /usr/sbin/ipadm enable-if -t ${ifname} 2>/dev/null
        /usr/sbin/ipadm create-if ${ifname} 2>/dev/null
        /usr/sbin/ipadm show-addr -p -o type ${ifname}/ 2>/dev/null | grep -q '^dhcp$' || \
          /usr/sbin/ipadm create-addr -T dhcp -w 60 ${ifname}/dhcp 2>/dev/null
        __w=0
        until /usr/sbin/ipadm show-addr -p -o type,state ${ifname}/ 2>/dev/null | grep -q '^dhcp:ok$'; do
          /usr/sbin/ipadm show-addr -p -o type ${ifname}/ 2>/dev/null | grep -q '^dhcp$' || break
          [ $__w -ge 60 ] && break
          sleep 2; __w=$((__w + 2))
        done
        if ! /usr/sbin/ipadm show-addr -p -o type,state ${ifname}/ 2>/dev/null | grep -q '^dhcp:ok$'; then
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

  # networking.useDHCP: DHCP on every wired datalink the config does not name, as
  # NixOS's dhcpcd does for interfaces without static addresses. Instance numbers
  # are not stable on illumos (the X1E's Belkin RTL8153 came up as usbecm1 on a
  # boot where its first connect failed and it re-enumerated on another port), so
  # a config cannot name a USB NIC reliably. Waits (bounded) for at least one such
  # link, then runs the same per-interface bringup on each.
  anyBringup = ''
    __w=0; __links=""
    while :; do
      __links=$(/usr/sbin/dladm show-phys -p -o link,media 2>/dev/null \
        | awk -F: '$2 == "Ethernet" { print $1 }' \
        | grep -vxE '${concatStringsSep "|" (namedIfs ++ [ "lo0" ])}')
      [ -n "$__links" ] && break
      [ $__w -ge ${toString linkWaitSeconds} ] && break
      sleep 2; __w=$((__w + 2))
    done
    [ -z "$__links" ] && echo "-- useDHCP: no unnamed wired link after $__w s"
    for __l in $__links; do
      ( ${ifBringup "$__l" { dhcp = true; ipv4.addresses = [ ]; }} ) &
    done
    wait
  '';

  # The complete first-boot bringup body: every active interface, then the
  # default route + hostname + the dns/client nudge (gotcha #16). Logged to the
  # service's own SMF log (svcs -L site/solnix-net), as NixOS's dhcpcd logs to the
  # journal and not the console. A failure is still visible: svcs -x names the log.
  # resolv.conf itself is generated into /etc statically below; network/location
  # (enabled in the site profile) drives dns/client online — we nudge it here in
  # case its refresh-dep on location missed the boot-time state change.
  # Interfaces come up in parallel, one subshell each, so one late or missing
  # link does not hold the others back.
  netBringup = ''
    echo "=== solnix networking bringup $(date) ==="
    ${concatStringsSep "\n" (mapAttrsToList (n: i: "( ${ifBringup n i} ) &") activeIfs)}
    ${optionalString (cfg.useDHCP && !netd) "( ${anyBringup} ) &"}
    wait
    ${optionalString (cfg.defaultGateway != null) ''
      echo "-- default route via ${cfg.defaultGateway}"
      /usr/sbin/route -p add default ${cfg.defaultGateway} 2>&1 || \
        /usr/sbin/route add default ${cfg.defaultGateway} 2>&1 || true
    ''}
    ${optionalString (cfg.nameservers == [ ] && (dhcpIfs != [ ] || (cfg.useDHCP && !netd))) ''
      # No static nameservers: take them from the DHCP lease, as NixOS's dhcpcd
      # does through resolvconf. The gate's network/service (net-svc) would do it
      # too, but it runs before this service has a lease and finds none (measured
      # on the X1: net-svc at 12:21:35, the lease at 12:22:37, no /etc/resolv.conf,
      # dns/client offline "Dependency file://localhost/etc/resolv.conf is absent").
      __ns=""; __dom=""
      for __if in ${concatStringsSep " " dhcpIfs} $(/usr/sbin/ipadm show-addr -p -o addrobj,type 2>/dev/null | awk -F: '$2 == "dhcp" { sub("/.*", "", $1); print $1 }'); do
        __ns=$(/sbin/dhcpinfo -i $__if DNSserv 2>/dev/null); __dom=$(/sbin/dhcpinfo -i $__if DNSdmain 2>/dev/null)
        [ -n "$__ns" ] && break
      done
      if [ -n "$__ns" ]; then
        { [ -n "$__dom" ] && echo "domain $__dom"; for __s in $__ns; do echo "nameserver $__s"; done; } > /etc/resolv.conf.dhcp
        chmod 0644 /etc/resolv.conf.dhcp; mv -f /etc/resolv.conf.dhcp /etc/resolv.conf
        echo "-- resolv.conf from the DHCP lease: $(echo $__ns)"
      else
        echo "-- no DNS servers in the DHCP lease; /etc/resolv.conf left as it is"
      fi
    ''}
    /usr/bin/hostname ${cfg.hostName} 2>/dev/null || true
    # nudge dns/client online (its refresh-dep on network/location may miss the
    # boot-time state change on our image); harmless if already online.
    /usr/sbin/svcadm enable svc:/network/location:default 2>/dev/null || true
    ( sleep 5; /usr/sbin/svcadm refresh svc:/network/dns/client:default 2>/dev/null; \
      /usr/sbin/svcadm enable svc:/network/dns/client:default 2>/dev/null ) &
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
      description = "DNS servers written to /etc/resolv.conf. Empty (the default, as on NixOS): the DHCP lease's servers.";
    };

    # NixOS networking.hosts / networking.extraHosts (nixos/modules/config/networking.nix).
    hosts = mkOption {
      type = types.attrsOf (types.listOf types.str);
      default = { };
      example = literalExpression ''{ "192.168.0.2" = [ "fileserver.local" "nameserver.local" ]; }'';
      description = "Locally defined maps of hostnames to IP addresses, written to /etc/inet/hosts.";
    };

    extraHosts = mkOption {
      type = types.lines;
      default = "";
      example = "192.168.0.1 lanlocalhost";
      description = "Additional verbatim entries to be appended to /etc/inet/hosts.";
    };

    useDHCP = mkOption {
      type = types.bool;
      default = false;
      description = ''
        DHCP on every wired (Ethernet) datalink that networking.interfaces does
        not name, whatever its instance number (NixOS: networking.useDHCP). For
        machines whose NIC name is not known in advance: a USB adapter's instance
        changes when it re-enumerates. Off by default, because a solnix system
        names its interfaces (EC2's ena0) the way NixOS configs usually do.
      '';
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
      # NixOS: the hostname resolves locally, on 127.0.0.2 (127.0.0.1 stays "localhost" for programs that
      # reverse-map it), so a login does not wait on DNS for its own name.
      networking.hosts."127.0.0.2" = lib.optional (cfg.hostName != "") cfg.hostName;

      # resolv.conf + defaultrouter land in the solnix /etc overlay (activation
      # reads networking.* for nodename; these extend it). Exposed as an internal
      # attr the activation module folds into its `etc` derivation. Built in Nix
      # (not mkIf-per-leaf) so an unset option simply omits the file.
      # inet/hosts: illumos's file (/etc/hosts links to it in the stock tree), NixOS's content: localhost first,
      # then networking.hosts, then networking.extraHosts.
      networking.generatedEtc =
        {
          "inet/hosts" = "127.0.0.1 localhost loghost\n::1 localhost\n"
            + lib.concatStrings (mapAttrsToList (ip: names: "${ip} ${concatStringsSep " " names}\n")
                (filterAttrs (_: v: v != [ ]) cfg.hosts))
            + cfg.extraHosts;
        }
        // (lib.optionalAttrs (cfg.nameservers != [ ]) {
          "resolv.conf" = concatMapStringsSep "" (ns: "nameserver ${ns}\n") cfg.nameservers;
        })
        // (lib.optionalAttrs (cfg.defaultGateway != null) {
          "defaultrouter" = "${cfg.defaultGateway}\n";
        });
    }

    # The DHCP/static bringup runs as an SMF transient oneshot built through the
    # EXISTING smf.services.* module — no new init concept. Only emitted when the
    # config actually declares an interface (YAGNI: no service for an empty net).
    (mkIf (activeIfs != { } || (cfg.useDHCP && !netd)) {
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
          # stdout/stderr of an SMF method go to its log (/var/svc/log/site-solnix-net:default.log),
          # not the console: the boot console shows the login prompt, not this trace.
          { ${netBringup} } 2>&1
          exit $SMF_EXIT_OK
        ''}";
        # the link wait, then create-addr (60 s), the lease poll (60 s) and the
        # ifconfig fallback (60 s), with room to spare
        start.timeoutSeconds = linkWaitSeconds + 240;
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
