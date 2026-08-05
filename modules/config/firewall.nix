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
in
{
  options.solnix.firewall = {
    enable = lib.mkOption {
      type = lib.types.bool; default = true;
      description = "Enable the illumos ipfilter firewall (default-deny inbound + ssh).";
    };
    allowedTCPPorts = lib.mkOption {
      type = lib.types.listOf lib.types.int; default = [ 22 ];
      description = "Inbound TCP ports to allow (default: 22/ssh, matching NixOS's ssh-open default).";
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

      # inbound: allow ICMP echo (ping), then the allowed TCP ports, then block the rest
      pass in quick proto icmp from any to any icmp-type echo keep state
      ${portRules}

      # default-deny: block + log anything inbound not matched above
      block in log all
    '';

    # Enable svc:/network/ipfilter (the SMF site profile / activation enables it).
    # NOTE: the SMF generator brings up svc:/network/ipfilter:default and applies
    # ipf.conf; recorded here as the intent the activation layer wires (see
    # docs/design-first-boot-defaults.md T3.14). On EC2 the security group is a
    # second layer; ipfilter matches NixOS's host-firewall-on default.
    solnix.defaults.enableStockServices = [ "network/ipfilter" ];
  };
}
