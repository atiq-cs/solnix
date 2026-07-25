# modules/system/activation/default.nix — system.build.toplevel + activation.
#
# solnix analog of NixOS's system/activation (activatable-system.nix +
# top-level.nix). The toplevel is the derivation whose closure IS the bootable
# world: the composed illumos systemPath + the solnix-generated SMF manifests +
# an SMF activation script (design-smf-init.md §3.1: svccfg import each manifest,
# apply enable/disable, svcadm to the target milestone) + a small /etc generation.
#
# It is NOT a full disk image — lib/make-be.nix consumes this toplevel and lays
# it into a bootable ZFS-root BE (the make-be boundary; some steps need root+ZFS
# on the host). The toplevel is the reproducible, store-resident part; make-be is
# the host-side assembly that turns it into a disk.
#
# ADD-not-replace (design-smf-init §5.1): the world's stock manifests come from
# the proto (make-be lays the proto as root). solnix's toplevel adds systemPath
# (the composed slices) + its own manifests + the activate script.

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption types concatStringsSep mapAttrsToList filterAttrs optionalString;

  cfg = config.system;

  # target milestone the activation script drives to (Phase-1 gate).
  targetMilestone = "svc:/milestone/multi-user-server:default";

  enabledServices = filterAttrs (_: s: s.enable) config.smf.services;

  # SMF site profile enabling our services + the disable/enable deltas the boot
  # gotchas require (design-make-be §5 gotcha #16 + the site profile in
  # oi-make-be.sh §8). Generated from smf.services.* so the config drives it,
  # rather than the hand-written XML in the script. sendmail/hal/keymap/intrd/
  # ipmp/ipsecalgs are peripheral services that fail cleanly on headless EC2;
  # network/location drives dns/client online. These are NOT in smf.services
  # (they are world-stock), so they stay as fixed profile lines here.
  siteProfile = pkgs.writeText "solnix-site.xml" ''
    <?xml version="1.0"?>
    <!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
    <service_bundle type="profile" name="solnix">
    ${concatStringsSep "\n" (mapAttrsToList (name: svc:
      "  <service name='${svc.category}/${name}' version='1' type='service'><instance name='${svc.instance}' enabled='${if svc.enable then "true" else "false"}'/></service>")
      config.smf.services)}
      <service name="network/location" version="1" type="service"><instance name="default" enabled="true"/></service>
      <service name="network/smtp" version="1" type="service"><instance name="sendmail" enabled="false"/></service>
      <service name="network/sendmail-client" version="1" type="service"><instance name="default" enabled="false"/></service>
      <service name="system/hal" version="1" type="service"><instance name="default" enabled="false"/></service>
      <service name="system/keymap" version="1" type="service"><instance name="default" enabled="false"/></service>
      <service name="system/intrd" version="1" type="service"><instance name="default" enabled="false"/></service>
      <service name="network/ipmp" version="1" type="service"><instance name="default" enabled="false"/></service>
      <service name="network/ipsec/ipsecalgs" version="1" type="service"><instance name="default" enabled="false"/></service>
      <service name="network/ipsec/policy" version="1" type="service"><instance name="default" enabled="false"/></service>
      <service name="system/filesystem/rmvolmgr" version="1" type="service"><instance name="default" enabled="false"/></service>
    </service_bundle>
  '';

  # The SMF activation script (design-smf-init §3.1). Runs ON-TARGET (svc.startd/
  # configd are already up). Idempotent: svccfg import is create-or-update.
  # `svcadm enable` per enabled service (import sets initial state; enforce so a
  # config flip takes effect). Removal-on-switch deferred to P2.1 (generation
  # diff) — a stale enabled service does not block the milestone gate.
  activate = pkgs.writeScript "solnix-activate" ''
    #!/sbin/sh
    # solnix activation — switch-to-configuration analog (design-smf-init §3.1).
    set -u
    SYS="''${1:-@toplevel@}"    # the toplevel store path (this system)

    # 1. Apply the solnix site profile (enable/disable deltas).
    /usr/sbin/svccfg apply ${siteProfile} 2>&1 || true

    # 2. Import / reconcile our generated manifests (idempotent).
    for m in "$SYS/manifest/solnix"/*.xml; do
      [ -e "$m" ] || continue
      /usr/sbin/svccfg import "$m" 2>&1 || true
    done

    # 3. Enforce enabled state for solnix-declared services.
    ${concatStringsSep "\n    " (mapAttrsToList (name: svc:
      "/usr/sbin/svcadm ${if svc.enable then "enable" else "disable"} ${svc.fmri} 2>/dev/null || true")
      config.smf.services)}

    # 4. Bring the system to the target milestone (idempotent).
    /usr/sbin/svcadm milestone '${targetMilestone}' 2>&1 || true

    echo "solnix activation complete (milestone ${targetMilestone})"
  '';

  # /etc generation: the minimal, config-driven /etc bits. Grows lazily. For now:
  # the hostname + a release stamp. The bulk of /etc comes from the proto (make-be
  # lays it down); this is the solnix-owned overlay staged by make-be.
  etc = pkgs.runCommand "solnix-etc" { } ''
    mkdir -p $out/etc
    printf '%s\n' '${config.networking.hostName}' > $out/etc/nodename
    printf 'solnix system toplevel\nhostname: %s\n' '${config.networking.hostName}' > $out/etc/solnix-release
  '';

  # THE TOPLEVEL — the derivation whose closure is the bootable world.
  #   $out/systemPath      -> composed illumos world (kernel + rtld + libc + ld
  #                           + base-tools + externalLibs), the current-system sw.
  #   $out/manifest/solnix -> DTD-validated generated SMF manifests (smf.nix).
  #   $out/activate        -> the SMF activation script (svccfg import + milestone).
  #   $out/site-profile.xml-> the enable/disable site profile.
  #   $out/etc             -> solnix-owned /etc overlay.
  #   $out/kernel, $out/platform -> symlinks into systemPath so a make-be /
  #                           closure walker finds the kernel by a stable name
  #                           (mirrors NixOS's system/toplevel exposing `kernel`).
  toplevel = pkgs.runCommand "solnix-system-${config.networking.hostName}" { } ''
    mkdir -p $out
    ln -s ${pkgs.illumos.systemPath}                 $out/systemPath
    ln -s ${config.system.build.smfManifests}/manifest/solnix $out/manifest/solnix 2>/dev/null || \
      { mkdir -p $out/manifest; ln -s ${config.system.build.smfManifests}/manifest/solnix $out/manifest/solnix; }
    ln -s ${activate}                                 $out/activate
    ln -s ${siteProfile}                              $out/site-profile.xml
    ln -s ${etc}/etc                                  $out/etc
    # kernel + platform: stable-named entrypoints into systemPath (the closure
    # walker / make-be reads $out/kernel + $out/platform to find unix/genunix).
    ln -s ${pkgs.illumos.systemPath}/kernel           $out/kernel
    ln -s ${pkgs.illumos.systemPath}/platform         $out/platform
    # a manifest of what this system is (for `nix-store -q --tree` legibility).
    cat > $out/system-manifest <<EOF
    hostName=${config.networking.hostName}
    milestone=${targetMilestone}
    systemPath=${pkgs.illumos.systemPath}
    smfManifests=${config.system.build.smfManifests}
    EOF
    # sanity: the closure must have the kernel + a service manager + libc.
    [ -e $out/systemPath/platform/i86pc/kernel/amd64/unix ] || { echo "FATAL: no unix in toplevel" >&2; exit 1; }
    [ -e $out/systemPath/kernel/amd64/genunix ]             || { echo "FATAL: no genunix in toplevel" >&2; exit 1; }
    [ -e $out/systemPath/lib/svc/bin/svc.startd ]           || { echo "FATAL: no svc.startd in toplevel" >&2; exit 1; }
    [ -e $out/systemPath/lib/amd64/libc.so.1 ]              || { echo "FATAL: no libc in toplevel" >&2; exit 1; }
    [ -e $out/activate ]                                    || { echo "FATAL: no activate script" >&2; exit 1; }
  '';
in
{
  options.system.build = {
    toplevel = mkOption {
      type = types.package;
      description = ''
        The full solnix system: a derivation whose closure is the bootable world
        (systemPath + generated SMF manifests + activation script + /etc). The
        NixOS system.build.toplevel analog. lib/make-be.nix consumes this.
      '';
    };
    activate = mkOption {
      type = types.package;
      description = "The SMF activation script (svccfg import + svcadm milestone).";
    };
    etc = mkOption {
      type = types.package;
      description = "The solnix-owned /etc overlay.";
    };
    smfSiteProfile = mkOption {
      type = types.package;
      description = "The generated SMF site profile (enable/disable deltas).";
    };
    smfManifests = mkOption {
      type = types.package;
      description = ''
        The DTD-validated generated SMF manifest directory (set by smf.nix).
        Declared here so smf.nix's `system.build.smfManifests` has a home.
      '';
    };
  };

  config.system.build = {
    inherit toplevel activate etc;
    smfSiteProfile = siteProfile;
  };
}
