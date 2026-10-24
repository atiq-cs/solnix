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
# Accepted deviation from NixOS (maintainer, 2026-10-09): no `nixos` user and no
# console autologin. The user logs in as root with no password and installs from
# there (docs/installer-contract.md, "Accepted deviations").
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
  # the console temperature line (svc:/site/solnix-templine below)
  templine = pkgs.writeScript "solnix-templine"
    (builtins.replaceStrings [ "@cputemp@" ] [ "${live.solnix-cputemp}/bin/solnix-cputemp" ]
      (builtins.readFile ../scripts/live/solnix-templine));
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
  # The live root's writable store: a tmpfs upper with the ramdisk's store paths
  # lofs-mounted into it read-only (NixOS: /nix/.rw-store + overlay). Run from
  # inittab, which make-installer-image.sh points at share/solnix/live-store.
  liveStore = pkgs.writeScript "solnix-live-store" (builtins.readFile ../scripts/live/solnix-live-store);
  # /run/current-system/sw/bin carries these by name, like any systemPackage.
  liveTools = pkgs.runCommand "solnix-live-tools" { } ''
    mkdir -p $out/bin
    ln -s ${config.system.build.solnixInstall} $out/bin/solnix-install
    ln -s ${zap} $out/bin/solnix-zap
    ln -s ${diag} $out/bin/solnix-diag
    ln -s ${templine} $out/bin/solnix-templine
    ln -s ${motd} $out/bin/solnix-motd
    ln -s ${autonet} $out/bin/solnix-autonet
    ln -s ${generateConfig} $out/bin/solnix-generate-config
    # Linux-named wrappers over the illumos tools (docs/nixos-iso-tool-parity.md).
    ${lib.concatMapStrings (w: "ln -s ${w} $out/bin/${w.name}\n") compat}
    # GNU coreutils names the illumos world does not have at all (shred, stat,
    # readlink, realpath, timeout, sha256sum ...). Only these: the full set would
    # replace ls/cp/dd/df on /usr/bin, which links to sw/bin. coreutils is already
    # in the closure (home-manager's dependency), so this adds no bytes.
    for t in ${lib.concatStringsSep " " gnuOnly}; do
      [ -e ${live.coreutils}/bin/$t ] || { echo "FATAL: coreutils has no $t" >&2; exit 1; }
      ln -s ${live.coreutils}/bin/$t $out/bin/$t
    done
    mkdir -p $out/share/solnix
    ln -s ${liveMethods} $out/share/solnix/live-methods
    ln -s ${liveStore} $out/share/solnix/live-store
    # /root/README on the media (make-installer-image.sh copies it there).
    ln -s ${readme} $out/share/solnix/README
  '';
  generateConfig = pkgs.writeScript "solnix-generate-config" (builtins.readFile ../scripts/solnix-generate-config);
  readme = pkgs.writeText "solnix-installer-README" (builtins.readFile ../scripts/live/README);
  compat = map (n: pkgs.writeScript n (builtins.readFile (../scripts/live/compat + "/${n}")))
    [ "lsblk" "lspci" "lsusb" "ip" ];
  gnuOnly = [ "shred" "stat" "readlink" "realpath" "timeout" "truncate" "nproc" "seq" "tac"
              "sha1sum" "sha256sum" "sha512sum" "md5sum" "b2sum" "base64" "numfmt" "stdbuf" "whoami" ];
in
{
  imports = [ ./base.nix ];

  networking.hostName = "solnix-installer";

  # Both Intel wifi drivers on the media (iwm: AC 7260-9560, the X1; iwx:
  # AX210/AX211, the X1E) with their firmware in the kernel tree, but bound to
  # NO device at boot: neither has a proven attach on that silicon, and a panic
  # at boot would make the media unusable. Bind at run time with one command
  # (docs/x1e-wifi-runtime-bind.md), e.g. update_drv -a -i '"pciex8086,51f0"' iwx.
  hardware.wirelessIntel.onMedia = true;

  # The GPU drivers on the media the same way: i915 (the X1E's Iris Xe, the X1's
  # UHD 630) and the NVIDIA open modules (the X1E's RTX 3080 Ti) have a major
  # and minor_perm but no alias, so the console stays on vgatext and nothing
  # attaches at boot. Load-test them at run time (docs/x1e-gpu-runtime-bind.md).
  # The GSP firmware is unfree, so it is not on the media: an nvidia attach
  # needs hardware.graphics.nvidia.acceptFirmwareLicense in a later image.
  hardware.graphics.onMedia = true;

  # The edition this media ships (same pin as cloud-ec2.nix); without it the
  # release label falls back to "unstable" and /etc/release misreports the image.
  solnix.release = "26.11";

  # This image ships solnix-dev-full (gcc + binutils + make + pkgconf): the "build
  # host in the image" role. Declaring buildCapable exempts the compiler + its
  # gate-proto sysroot from the toplevel's disallowed-runtime-refs gate (they are
  # present on purpose). See modules/system/activation/default.nix.
  #
  # mkDefault so the MINIMAL live edition (installer-live.nix) can set it false:
  # then solnix-dev-full is dropped from the live ramdisk closure (it rides in the
  # read-only media store instead) and the disallowed-refs gate stays ACTIVE --
  # a free check that the 219 MB build-only gate proto does NOT leak into the
  # minimal ramdisk by accident.
  system.buildCapable = lib.mkDefault true;

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
    # NixOS minimal-ISO tools the illumos world lacks (profiles/base.nix,
    # installation-cd-base.nix; table in docs/nixos-iso-tool-parity.md). jq and
    # xz are already in the closure (home-manager, nix); tmux + libevent add
    # ~2.7 MB, gzip/nano/rsync/smartmontools ~3 MB. gzip's zcat/uncompress replace
    # the world's (they read .Z as well as .gz).
    live.jq
    live.xz
    live.tmux
    live.gzip
    live.nano
    live.rsync
    live.smartmontools
    # The maintainer-required interactive CLI set (curl above; vi/nano editors).
    # All real from-source derivations in pkgs.solnix (base-src.nix), so they
    # close in the media's from-source store like everything else here. Each
    # ships its own man page under share/man (worldMan carries the base pages),
    # so `man wget`, `man tree`, `man top`, `man htop`, `man less`, `man vi` work
    # through the system MANPATH, and `man fetch` (bsdfetch, FreeBSD fetch(1)).
    # nvi (nvi2) is the shipped vi: live.nvi carries
    # bin/nvi plus vi/ex/view links to it.
    live.nvi
    live.top
    live.htop
    live.less
    live.tree
    live.wget
    live.bsdfetch
    # The build toolchain, so the booted installer/system can rebuild solnix
    # packages on the image (the "build host in the image" capability): gcc
    # 14.3.0 + gas (binutils) + GNU make + pkg-config, all real from-source
    # derivations (keeps this media reproducible-from-source). This is the solnix
    # analog of a NixOS build host; NixOS's base ISO omits a compiler, but solnix
    # ships one because an illumos system cannot otherwise build its own packages
    # (docs/pending/builders-need-store-tools.md, docs/devtools-in-closure.md).
    # NOT included: Rust (cached seed payload retired from the cache, 404 -- see
    # the devtools doc) and autoconf/automake/libtool (need from-source perl).
    #
    # GATED ON buildCapable: solnix-dev-full (gcc + gate-proto sysroot, ~1.2 GB)
    # is the single largest thing in the closure, 2.5x the live-ramdisk ceiling.
    # The MINIMAL live edition (installer-live.nix) sets buildCapable=false, which
    # drops it HERE and moves it to the read-only media store; install-from-flake
    # then builds the target FROM that media store, so the SHIPPED system is still
    # fully build-capable while the LIVE ramdisk fits (design doc #1+#2).
    liveTools
  ] ++ lib.optional config.system.buildCapable live.solnix-dev-full;

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

  # One console line every 30 s with the CPU, thermal-zone and ThinkPad EC
  # temperatures (scripts/live/solnix-templine). If the machine powers off by
  # itself, the last readings are still on the screen to photograph. It only
  # reads (one ioctl per CPU sensor, one kstat read per zone); `svcadm disable
  # solnix-templine` silences it.
  smf.services.solnix-templine = {
    enable = true;
    category = "site";
    description = "solnix live temperature line";
    model = "contract";
    requires = [ "svc:/milestone/multi-user:default" ];
    start.exec = "${templine} &";
    stop.exec = ":kill";
  };

  # sshd runs on the media with root login allowed, as NixOS's installation-device
  # profile sets (services.openssh.enable, settings.PermitRootLogin = "yes"). Nobody
  # can log in until root has a password or a key: the media bakes neither. On the
  # LIVE root it is not started at boot (make-installer-image.sh disables it in the
  # ramdisk's repository; an installed system keeps it on): solnix-live starts it
  # once solnix-autonet has a DHCP lease (`solnix-install --sshd-now`), which sets a
  # random one-time root password and prints it with the address on the console,
  # above the login prompt and in the motd. A key in the stick's ESP at
  # /solnix/authorized_keys is installed for root too. Before that, port 22 is
  # closed. `solnix-install --ssh` does the same by hand.
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

  # No automatic GC on the media. The ramdisk runs with ~44 MB free, below the
  # 128 MB min-free first-boot-defaults.nix sets, so the first nix command at boot
  # (solnix-channel-init's nix-env) started a GC on the live store (measured
  # under KVM: "error: executing 'lsof'" on the console at the login prompt). The
  # media's store is fixed, and the installer writes to the target pool's store.
  nix.settings.min-free = 0;
  nix.settings.max-free = 0;

  # CPU power management on the media (svc:/system/power is on: solnix.
  # powerManagement.enable). The stock power.conf has `cpupm enable` (cpupm_default_
  # mode = event: the kernel's elastic P-state policy, falling back to polling where
  # PAD is unavailable, pm.c) and leaves autoS3 / autoshutdown at "default"; on a
  # laptop that answers estar_v2/v3 the default may suspend or power off an idle
  # machine. A live installer must never do that, so both are pinned off here.
  # speedstep (P-states via _PSS + IA32_PERF_CTL) supports family 6 model >= 0xe
  # with CPUID EST, i.e. Alder Lake too (speedstep.c speedstep_supported).
  environment.generatedEtc."power.conf" = ''
    device-dependency-property removable-media /dev/fb
    autopm                  default
    autoS3                  disable
    autoshutdown            30 9:00 9:00 noshutdown
    cpupm                   enable
    cpu-threshold           1s
  '';

  # The live root is a RAM ramdisk: cap the ARC so the target's bootadm/digest
  # always has memory (measured: an uncapped ARC OOM-killed digest on install).
  environment.generatedEtc."system.d/solnix-live-arc" = ''
    set zfs:zfs_arc_max = 0x20000000
  '';

  # No GLOBAL core dumps on the installer media. The live root is a tight RAM UFS
  # ramdisk; a daemon core written to /var/cores there (e.g. an aborting
  # svc.configd) fills the filesystem and takes the SMF repository down behind the
  # login prompt -- measured: "svc.configd no space left on device" -> "ufs
  # realloccg /: file system full" -> "svc.startd: Repository server out of
  # resources." An installed system on a real pool keeps global cores on (base.nix
  # default). This is a live-media setting like the empty resolv.conf.
  solnix.coreadm.globalEnabled = false;
}
