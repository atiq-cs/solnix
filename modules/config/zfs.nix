{ config, lib, pkgs, ... }:
# modules/config/zfs.nix -- services.zfs.expandOnBoot, NixOS's option (nixos/modules/tasks/filesystems/zfs.nix
# zpool-expand-pools; amazon-image.nix sets it to "all"): after import, `zpool online -e` every disk of the pools.
# On illumos this relabels a whole-disk (zpool create -B) vdev onto a grown disk (libzfs zpool_relabel_disk);
# a vdev on a slice (whole_disk=0) is left as it is, so it never edits a partition table under a slice.
# The kernel already does the same at import when autoexpand=on; this makes it explicit and lets other
# services (site/solnix-dump-size) order after the grow.
let
  cfg = config.services.zfs.expandOnBoot;
  pools = if cfg == "all" then "$(zpool list -H -o name)" else lib.escapeShellArgs cfg;
  script = pkgs.writeTextFile {
    name = "solnix-zpool-expand";
    executable = true;
    text = ''
      #!/bin/sh
      PATH=/usr/sbin:/usr/bin:/sbin
      for p in ${pools}; do
        for d in $(zpool status "$p" | awk '$1 ~ /^c[0-9]+t[0-9A-Fa-f]+d[0-9]+(s[0-9]+)?$/ {print $1}'); do
          zpool online -e "$p" "$d" && echo "online -e $p $d" || echo "WARN: zpool online -e $p $d failed"
        done
        zpool list -H -o name,size "$p"
      done
      exit 0
    '';
  };
in
{
  options.services.zfs.expandOnBoot = lib.mkOption {
    type = lib.types.either (lib.types.enum [ "disabled" "all" ]) (lib.types.listOf lib.types.str);
    default = "disabled";
    example = [ "spool" ];
    description = ''After importing, expand each device in the given pools ("all": every imported pool).'';
  };

  config = lib.mkIf (cfg != "disabled") {
    smf.services.solnix-zpool-expand = {
      enable = true;
      category = "site";
      description = "solnix: zpool online -e the pools' disks (services.zfs.expandOnBoot)";
      model = "transient";
      start = { exec = "${script}"; timeoutSeconds = 300; };
      stop.exec = ":true";
      requires = [ "svc:/system/filesystem/local:default" ];
    };
  };
}
