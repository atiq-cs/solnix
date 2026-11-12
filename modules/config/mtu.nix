{ config, lib, pkgs, ... }:
# modules/config/mtu.nix -- evidence-based, post-DHCP MTU raise (docs/design-mtu-policy.md).
#
# The ena driver boots at a boot-safe MTU (1500) so DHCP always completes
# (pkgs/illumos/patches/ena-default-mtu-1500.patch). MAC_PROP_MTU is runtime-
# settable (ena-runtime-mtu.patch: setprop/propinfo now handle MTU instead of
# returning ENOTSUP; dladm show-linkprop -p mtu ena0 reports the possible range,
# and the per-instance target is applied at a clean attach via the ena.conf
# "mtu" property because the driver only resizes its Rx/Tx buffers at ring
# start). This service runs after the network is up, picks the target MTU per
# the policy table from evidence (instance type via IMDS + device max), applies
# it, PROBES reachability + a jumbo round-trip, and reverts to 1500 on failure.
let
  cfg = config.solnix.mtu;

  # The method script (scripts/solnix-mtu.sh). Referenced by absolute store path
  # from the generated SMF manifest, with a PATH that has the illumos net tools.
  mtuScript = pkgs.writeTextFile {
    name = "solnix-mtu.sh";
    executable = true;
    text = builtins.readFile ../../scripts/solnix-mtu.sh;
  };
in
{
  options.solnix.mtu = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable the evidence-based post-DHCP MTU raise (solnix-mtu SMF service).
        The NIC always boots at the boot-safe 1500; this only raises it where a
        probe confirms a larger MTU works, reverting to 1500 otherwise.
      '';
    };
    jumboMtu = lib.mkOption {
      type = lib.types.ints.positive;
      default = 9001;
      description = "Target MTU on jumbo-capable within-VPC Nitro instances (clamped to the device max). AWS supports 9001 within a VPC.";
    };
    safeMtu = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1500;
      description = "Boot-safe MTU and the guaranteed fallback whenever a raise cannot be verified.";
    };
  };

  config = lib.mkIf cfg.enable {
    smf.services.solnix-mtu = {
      enable = true;
      category = "site";
      description = "solnix evidence-based post-DHCP MTU raise";
      # run-once per boot: settle the MTU, then exit.
      model = "transient";
      start = {
        # a clean PATH for dladm/ipadm/netstat/ping/curl/bootadm/reboot.
        exec = "/bin/sh ${mtuScript}";
        timeoutSeconds = 120;
      };
      stop.exec = ":true";
      # Only after the network milestone is up and (on EC2) after the
      # metadata-shim has had a chance to install a lease + net-ok sentinel.
      # network/physical returns before the lease: the network-online group waits for solnix-net.
      dependencies = [ config.smf.networkOnline ];
      requires = [
        "svc:/milestone/network:default"
        "svc:/network/physical:default"
      ];
    };

    # keep the policy knobs visible to the script via a tiny generated env file
    # the script can source if we ever want to override the compiled-in values.
    environment.generatedEtc."default/solnix-mtu" = ''
      SOLNIX_MTU_JUMBO=${toString cfg.jumboMtu}
      SOLNIX_MTU_SAFE=${toString cfg.safeMtu}
    '';
  };
}
