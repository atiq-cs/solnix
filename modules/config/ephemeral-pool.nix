{ config, lib, pkgs, ... }:
# modules/config/ephemeral-pool.nix -- a ZFS pool on disks that come back blank
# (EC2 instance store: wiped on every stop/start, kept across a reboot).
#
# NixOS's analog is boot.zfs.extraPools (import a pool at boot) plus a unit that
# creates it when the disks are blank. Here one SMF transient service does both:
#   1. imported: nothing.  2. every disk is a vdev of this pool (a reboot): import it
#   from exactly those disks.  3. every disk blank (first boot, or a stop wiped them):
#   create it.  4. anything else: refuse, touch nothing, fail so `svcs -x` says why.
# cachefile=none: a stop must not leave a stale UNAVAIL pool in zpool.cache.
# Config rides in the store start script, not /etc, so a live `switch` (which only
# re-imports SMF manifests) can run it before the new /etc is laid.
let
  cfg = config.solnix.ephemeralPool;
  script = pkgs.writeTextFile {
    name = "solnix-ephemeral-pool.sh";
    executable = true;
    text = builtins.readFile ../../scripts/solnix-ephemeral-pool.sh;
  };
  dsFile = pkgs.writeTextFile {
    name = "solnix-ephemeral-pool-datasets";
    text = lib.concatStrings (lib.mapAttrsToList (n: d:
      "${n}\t${d.mountpoint}\t${d.owner}\t${d.mode}\n") cfg.datasets);
  };
  start = pkgs.writeTextFile {
    name = "solnix-ephemeral-pool-start";
    executable = true;
    text = ''
      #!/bin/sh
      POOL=${cfg.name} DISKS="${lib.concatStringsSep " " cfg.disks}" SOLNIX_EP_DATASETS=${dsFile}
      export POOL DISKS SOLNIX_EP_DATASETS
      exec /bin/sh ${script}
    '';
  };
in
{
  options.solnix.ephemeralPool = {
    enable = lib.mkEnableOption "a ZFS pool created on blank (instance-store) disks at boot";
    name = lib.mkOption { type = lib.types.str; default = "data"; description = "Pool name."; };
    disks = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [ "c2t1d0" "c3t1d0" ];
      description = "Whole disks (cXtYdZ). Striped: scratch data, no redundancy.";
    };
    datasets = lib.mkOption {
      default = { };
      description = "Datasets under the pool, by name relative to it.";
      type = lib.types.attrsOf (lib.types.submodule {
        options.mountpoint = lib.mkOption { type = lib.types.str; };
        options.owner = lib.mkOption { type = lib.types.str; default = "root:root"; description = "user:group of the mountpoint."; };
        options.mode = lib.mkOption { type = lib.types.str; default = "0755"; description = "Mode of the mountpoint (1777 for a TMPDIR)."; };
      });
    };
  };

  config = lib.mkIf cfg.enable {
    smf.services.solnix-ephemeral-pool = {
      enable = true;
      category = "site";
      description = "solnix ZFS pool on blank instance-store disks";
      model = "transient";
      start = { exec = "${start}"; timeoutSeconds = 300; };
      stop.exec = ":true";
      requires = [ "svc:/system/filesystem/local:default" ];
    };
  };
}
