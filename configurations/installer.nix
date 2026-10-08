# configurations/installer.nix -- the solnix installer media's own system.
#
# NixOS precedent: nixos/modules/installer/cd-dvd/installation-cd-minimal.nix +
# profiles/installation-device.nix. The media is a toplevel like any other; the
# image builder (scripts/make-installer-image.sh, the make-iso9660-image analog)
# puts THIS toplevel's closure on the media and nothing else.
#
# GENERIC BY CONSTRUCTION: no personal users, keys, hostnames or flake refs. The
# person installing supplies their own configuration with
#   solnix-install --flake 'github:<you>/<repo>#<host>'
# and, like NixOS's installer, the live root account is passwordless on the
# media only (installation-device.nix sets initialHashedPassword = "" for root);
# the installer then makes the operator choose a root password or lock root on
# the target, so that never reaches disk.
#
# Hardware: the world's whole kernel tree and the full gate driver database
# (pkgs/illumos/data/drivers, 362 majors / 2,124 aliases), the analog of NixOS's
# hardware.enableAllHardware. Nothing here is specific to one machine.
#
# Every package is a real derivation built in this repo (no cache-only paths, so
# the media's store is fully reproducible from source).
{ config, lib, pkgs, ... }:

let
  live = pkgs.solnix;
  # The live-media scripts, as store paths (NixOS: the installer's services are
  # ordinary config-generated units). They were heredocs inside
  # oi-make-livecd.sh; the bodies are unchanged.
  autonet = pkgs.writeScript "solnix-autonet" (builtins.readFile ../scripts/live/solnix-autonet);
  motd = pkgs.writeScript "solnix-motd" (builtins.readFile ../scripts/live/solnix-motd);
  zap = pkgs.writeScript "solnix-zap" (builtins.readFile ../scripts/solnix-zap);
  diag = pkgs.writeScript "solnix-diag" (builtins.readFile ../scripts/solnix-diag);
  liveMethod = pkgs.writeScript "solnix-live"
    (builtins.replaceStrings [ "@autonet@" "@install@" ]
      [ "${autonet}" "${config.system.build.solnixInstall}" ]
      (builtins.readFile ../scripts/live/solnix-live));
  # SMF methods the read-only UFS ramdisk root needs patched (fs-root rw remount,
  # fs-usr guard, dlmgmtd door dir, non-fatal early-manifest-import), built from
  # the world's stock methods; the image builder links them into the live root's
  # /lib/svc/method. (They are live-root only: an installed BE uses the stock ones.)
  liveMethods = pkgs.runCommand "solnix-live-methods" { } ''
    /sbin/sh ${../scripts/live/mk-live-methods.sh} ${live.world} $out
  '';
  # /run/current-system/sw/bin carries these by name, like any systemPackage.
  liveTools = pkgs.runCommand "solnix-live-tools" { } ''
    mkdir -p $out/bin
    ln -s ${config.system.build.solnixInstall} $out/bin/solnix-install
    ln -s ${zap} $out/bin/solnix-zap
    ln -s ${diag} $out/bin/solnix-diag
    ln -s ${motd} $out/bin/solnix-motd
    ln -s ${autonet} $out/bin/solnix-autonet
    mkdir -p $out/share/solnix
    ln -s ${liveMethods} $out/share/solnix/live-methods
  '';
in
{
  imports = [ ./base.nix ];

  networking.hostName = "solnix-installer";

  # base.nix configures an EC2 Nitro NIC and resolver; the media boots anywhere,
  # so it carries no interface or resolver of its own: the live method plumbs the
  # first wired NIC by DHCP and writes resolv.conf from the lease (solnix-install
  # bring_up_network), as NixOS's installer leaves networking to dhcpcd.
  networking.interfaces = lib.mkForce { };
  networking.nameservers = lib.mkForce [ ];

  # The tools an install needs on PATH, all real derivations: nix (from
  # modules/config/nix.nix), the installer itself (in the toplevel's bin/, linked
  # to /usr/sbin by the image builder), curl for the internet check and the
  # failure-bundle upload, openssl for hashing the passwords the operator types,
  # and the core-OS slices zpool/zfs/format/installboot/useradd/reboot come from.
  # sw/share/solnix/live-methods is read by the image builder; the default
  # pathsToLink (/bin /sbin /share/man /share/info) would leave it out of sw/, as
  # NixOS modules add their own subtrees to environment.pathsToLink.
  environment.pathsToLink = [ "/share/solnix" ];

  environment.systemPackages = [
    live.nixChain.curl
    live.openssl
    # git: `solnix-install --git`, and a config that lists git (NixOS's installer
    # enables programs.git) then finds it already in the store instead of
    # building it, which the media cannot (no compiler on it).
    live.git
    # home-manager, so a user can set up their home from the live system; it
    # brings the GNU coreutils/findutils/sed/grep/gettext/jq its scripts need.
    live.home-manager
    liveTools
  ];

  # The installer's own services (NixOS: installation-device.nix's units).
  # site/solnix-live: banner, auto-network kick-off, devfsadm, and the opt-in
  # unattended install (/etc/solnix-autoinstall or the solnix-autoinstall boot
  # property). Runs after single-user so /dev/dsk exists.
  smf.services.solnix-live = {
    enable = true;
    category = "site";
    description = "solnix live installer";
    model = "transient";
    requires = [ "svc:/milestone/single-user:default" "svc:/milestone/devices:default" ];
    start.exec = "${liveMethod}";
    start.timeoutSeconds = 1800;
    stop.exec = ":true";
  };

  # sshd runs on the media with root login allowed, as NixOS's installation-device
  # profile sets (services.openssh.enable, settings.PermitRootLogin = "yes"). Nobody
  # can log in until root has a password or a key: the media bakes neither, and
  # `solnix-install --ssh` sets one and prints it.
  environment.generatedEtc."ssh/sshd_config" = lib.mkForce ''
    UsePAM yes
    KbdInteractiveAuthentication yes
    PasswordAuthentication yes
    PrintMotd no
    PermitRootLogin yes
    Subsystem sftp ${live.openssh}/libexec/sftp-server
  '';

  # Substitute from cache.solnix.io (trusting only its 8UNr key) or BUILD; plus
  # cache.nixos.org for architecture-independent sources. These are already
  # modules/config/nix.nix's defaults; restated so the media's contract is
  # visible here and cannot drift with a base default.
  nix.settings = {
    substituters = [ "https://cache.solnix.io" "https://cache.nixos.org" ];
    trusted-public-keys = [
      "cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8="
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
    require-sigs = true;
  };

  # pkcs11_tpm.so (listed by the stock pkcs11.conf) needs libtspi, which the media
  # does not ship; `digest` then dies with SIGKILL and bootadm's create_hash
  # leaves a truncated boot_archive on the TARGET (measured on the X1 media). The
  # kernel and softtoken providers are all digest needs.
  environment.generatedEtc."crypto/pkcs11.conf" = ''
    metaslot:metaslot_status=enabled;metaslot_auto_key_migrate=enabled;metaslot_token=Sun Software PKCS#11 softtoken;metaslot_slot=Sun Crypto Softtoken
    /usr/lib/security/$ISA/pkcs11_kernel.so
    /usr/lib/security/$ISA/pkcs11_softtoken.so
  '';

  # X1 Carbon (and other USB-HID laptops): illumos hidparser cannot parse some
  # internal-keyboard report descriptors and hid retries forever, printing an L1
  # message per retry to the console. hid_errlevel=0 suppresses it (hid.c:66-67);
  # harmless on hardware without the defect.
  environment.generatedEtc."system.d/solnix-hid-quiet" = ''
    set hid:hid_errlevel = 0
  '';

  # The live root is a RAM ramdisk: cap the ARC so the target's bootadm/digest
  # always has memory (measured: an uncapped ARC OOM-killed digest on install).
  environment.generatedEtc."system.d/solnix-live-arc" = ''
    set zfs:zfs_arc_max = 0x20000000
  '';
}
