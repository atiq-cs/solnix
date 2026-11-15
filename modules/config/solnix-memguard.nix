# services.solnix-memguard -- pause the nix builds while the machine runs short of memory (./solnix-memguard.sh).
# For a machine someone works on that also builds (lixi: the queue builder at profile "opportunistic", agents' builds):
# when free memory drops under floorMiB, or cosmic-comp's RSS passes leakMiB (the i915 flip_done leak), every build
# process is SIGSTOPped until both recover. A build process is one of the build users' (nix.settings.build-users-group,
# NixOS's nixbld), selected by uid and gid, never by name. NixOS has no such guard: systemd-oomd (and earlyoom) KILL a
# cgroup under memory pressure, and nix-daemon's builds would be retried; illumos has neither, and a stopped build loses
# nothing. On by default with the opportunistic builder (builder.nix), which then requires it: no build without the guard.
{ config, lib, ... }:
let
  cfg = config.services.solnix-memguard;
in
{
  options.services.solnix-memguard = {
    enable = lib.mkEnableOption "solnix-memguard, which pauses nix builds (SIGSTOP) while free memory is low";
    floorMiB = lib.mkOption { type = lib.types.ints.positive; default = 4096;
      description = "Pause the builds while free memory (vmstat free) is under this many MiB."; };
    leakMiB = lib.mkOption { type = lib.types.ints.positive; default = 4096;
      description = "Also pause them while cosmic-comp's RSS is over this many MiB (the i915 flip_done leak)."; };
    interval = lib.mkOption { type = lib.types.ints.between 1 300; default = 15; description = "Seconds between checks."; };
  };

  config = lib.mkIf cfg.enable {
    assertions = [ { assertion = (config.nix.settings.build-users-group or "") != "";
      message = "services.solnix-memguard pauses the build users' processes: it needs nix.settings.build-users-group (multi-user nix)"; } ];
    smf.services.solnix-memguard = {
      enable = true;
      category = "site";
      description = "solnix-memguard: pause nix builds while free memory is low";
      model = "contract";
      requires = [ "svc:/system/filesystem/local:default" ];
      environment = {
        PATH = "/usr/bin:/usr/sbin:/bin";
        FLOOR_KB = toString (cfg.floorMiB * 1024);
        LEAK_KB = toString (cfg.leakMiB * 1024);
        MG_INTERVAL = toString cfg.interval;
        MG_GROUP = config.nix.settings.build-users-group;
      };
      start.exec = "/bin/sh ${./solnix-memguard.sh} &";
      # :kill sends TERM; the script CONTs what it paused before it exits
      stop.exec = ":kill";
    };
  };
}
