{ config, lib, ... }:
# modules/config/firewall.nix — the NixOS `networking.firewall` analog for illumos.
#
# NixOS defaults its firewall ON (default-deny inbound, allow loopback + established
# + configured ports). The illumos native packet filter is IP Filter (ipf), driven
# by /etc/ipf/ipf.conf and svc:/network/ipfilter:default. (crossbow = the dladm/flow
# network-virtualization layer; the stateful packet FIREWALL is ipfilter.) This module
# renders ipf.conf with a default-deny-inbound / allow-established / allow-ssh policy
# and enables the ipfilter SMF service.
let
  cfg = config.solnix.firewall;
  portRules = lib.concatMapStringsSep "\n"
    (p: "pass in quick proto tcp from any to any port = ${toString p} keep state")
    cfg.allowedTCPPorts;
  udpRules = lib.concatMapStringsSep "\n"
    (p: "pass in quick proto udp from any to any port = ${toString p} keep state")
    cfg.allowedUDPPorts;
in
{
  options.solnix.firewall = {
    enable = lib.mkOption {
      type = lib.types.bool; default = true;
      description = "Enable the illumos ipfilter firewall (default-deny inbound + ssh).";
    };
    allowedTCPPorts = lib.mkOption {
      type = lib.types.listOf lib.types.int; default = [ ];
      description = "Inbound TCP ports to allow. Definitions merge; 22 (sshd) is always one of them.";
    };
    allowedUDPPorts = lib.mkOption {
      type = lib.types.listOf lib.types.int; default = [ ];
      description = "Inbound UDP ports to allow (NixOS networking.firewall.allowedUDPPorts).";
    };
    trustedInterfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str; default = [ "lo0" ];
      description = "Interfaces exempt from filtering (loopback always trusted).";
    };
  };

  config = lib.mkIf cfg.enable {
    # /etc/ipf/ipf.conf — read by svc:/network/ipfilter at enable/boot.
    # Policy (NixOS-firewall-equivalent):
    #   - loopback: pass all (both directions)
    #   - outbound: pass all, keep state (so replies come back)
    #   - inbound:  pass established (via keep state on out) + allowed ports; block rest
    #   - ICMP echo allowed (ping) — NixOS allows ping by default.
    environment.generatedEtc."ipf/ipf.conf" = ''
      # solnix default firewall (ipfilter): default-deny inbound, allow established + ssh.
      # loopback fully trusted
      pass in quick on lo0 all
      pass out quick on lo0 all

      # outbound: allow everything, keep state so return traffic is permitted inbound
      pass out quick proto tcp from any to any keep state
      pass out quick proto udp from any to any keep state
      pass out quick proto icmp from any to any keep state

      # inbound: DHCP replies (a renewal's ACK need not match the request's state: the server may answer from
      # another address or by broadcast), ICMP echo (ping), the allowed ports, then block the rest
      pass in quick proto udp from any port = 67 to any port = 68
      pass in quick proto icmp from any to any icmp-type echo keep state
      ${portRules}
      ${udpRules}

      # default-deny: block + log anything inbound not matched above
      block in log all
    '';

    # IPv6: the same policy (svc:/network/ipfilter reads custom_policy_file_6 = /etc/ipf/ipf6.conf; without the
    # file v6 was unfiltered). ICMPv6 passes in (neighbour discovery and router adverts need it; NixOS passes all
    # of icmpv6 but redirects), and DHCPv6 replies (547 -> 546).
    environment.generatedEtc."ipf/ipf6.conf" = ''
      # solnix default firewall, IPv6 (ipfilter): default-deny inbound, allow established + ssh.
      pass in quick on lo0 all
      pass out quick on lo0 all
      pass out quick proto tcp from any to any keep state
      pass out quick proto udp from any to any keep state
      pass out quick proto ipv6-icmp from any to any keep state
      pass in quick proto ipv6-icmp from any to any
      pass in quick proto udp from any port = 547 to any port = 546
      ${portRules}
      ${udpRules}
      block in log all
    '';

    # The site profile enables svc:/network/ipfilter:default (activation/default.nix reads enableStockServices;
    # before 2026-10-30 nothing did, and ipfilter stayed off on every host). Its start method finds policy
    # version 0 in a BE's fresh repository, switches the policy to custom = /etc/ipf/ipf.conf and loads it.
    # On EC2 the security group is a second layer; ipfilter matches NixOS's host-firewall-on default.
    solnix.defaults.enableStockServices = [ "network/ipfilter" ];
    # sshd's port as a DEFINITION, not the option default: any other module's definition (seed.nix's peer port)
    # replaces a default, which rendered an ipf.conf without 22 (caught at eval 2026-10-30). NixOS: openssh.openFirewall.
    solnix.firewall.allowedTCPPorts = [ 22 ];
  };
}
