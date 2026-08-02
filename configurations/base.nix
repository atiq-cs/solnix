# configurations/base.nix — the minimal example solnix system.
#
# The Phase-1 target config (roadmap P1, "minimal bootable amd64 system"). This
# is what `solnixConfigurations.base` in flake.nix evaluates. It does NOT
# evaluate/build yet: it needs the nixpkgs fork (pkgs.illumos.*) and the seed
# toolchain. It fixes the SHAPE of a solnix config so the module tree has a real
# consumer.
#
# The minimal bootable service set (svc.startd, manifest-import, the milestones,
# filesystem/*, console-login, loopback) comes from the *world's* stock manifests
# shipped by pkgs.illumos.*, NOT from smf.services.* here — see
# docs/design-smf-init.md §5.2. We add only what this config declares on top.

{ config, lib, pkgs, ... }:

{
  # Target platform. Canonical Nix system is x86_64-solaris; "illumos" is
  # branding at the attribute layer. See docs/design-nixpkgs-illumos.md §1.
  # This is currently informational — the real nixpkgs.system/pkgs
  # wiring lands with the fork (P1.3). Recorded so the config is self-describing.
  # nixpkgs.system = "x86_64-solaris";

  networking.hostName = lib.mkDefault "solnix";

  # Stage-A declarative userland (design §D). The intended default package set is
  # `with pkgs.solnix; [ nix file less vim curl htop git ]`. Today:
  #   - nix is shipped by modules/config/nix.nix (nix.package -> systemPackages),
  #     so it is NOT re-listed here (would duplicate the store path).
  #   - base-tools (coreutils-equiv) is seeded by modules/config/system-path.nix.
  #   - file/less/vim/curl/htop/git come from pkgs.solnix.cached — the wave-built
  #     cache index (pkgs/illumos/cached.nix, keyed by pname). Each is a
  #     builtins.storePath that substitutes from cache.solnix.io at realise time
  #     (verified present in the x86_64-solaris manifest).
  environment.systemPackages = with pkgs.solnix.cached; [ file less vim curl htop git ];

  # Declarative networking (T2.9): the primary NIC via DHCP. This GENERATES the
  # illumos bringup (ipadm create-if/create-addr with the legacy-ifconfig
  # fallback the gate ena driver needs, gotcha #15) as an SMF transient oneshot,
  # plus /etc/resolv.conf from nameservers — replacing the ad-hoc solnix-netcfg
  # in oi-make-be.sh. "ena0" is the EC2 Nitro NIC; on other hardware set the
  # matching datalink name (dladm show-phys).
  networking.interfaces.ena0.dhcp = true;
  networking.nameservers = [ "169.254.169.253" "8.8.8.8" ];

  # Declarative users (T2.9): a login user + root, both with the maintainer's
  # ssh key. This GENERATES /etc/{passwd,shadow,group} entries (illumos format)
  # merged over the base system accounts, and seeds ~/.ssh/authorized_keys —
  # replacing the metadata-shim / ROOT_AUTHKEY key injection.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKCqHOIyYwbp42C7MxnRFxOcy+ZE8cNOWdsdvCgVFm1L Greg Burd <greg@burd.me>"
  ];
  # scott: primary admin login for cloud test hosts. Secure hashed password
  # (SHA-512 crypt) — password delivered out-of-band, never committed in clear.
  users.users.scott = {
    uid = 1001;
    group = "staff";
    description = "Scott (admin)";
    shell = "/usr/bin/ksh93";
    extraGroups = [ "adm" "sys" ];
    hashedPassword = "$6$ArPWLrn2ySFy0yku$UT8DvBWBxdrSJ0LLGgznIBjfBwa.hBG6td1UjoOiue.FaNsp3sHs6yLwjDSWN7Aa6TT/aQJgMTEzGUtw//yJ40";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKCqHOIyYwbp42C7MxnRFxOcy+ZE8cNOWdsdvCgVFm1L Greg Burd <greg@burd.me>"
    ];
  };
  users.users.greg = {
    uid = 1000;
    group = "staff";
    description = "Greg Burd";
    shell = "/usr/bin/ksh93";
    extraGroups = [ "adm" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKCqHOIyYwbp42C7MxnRFxOcy+ZE8cNOWdsdvCgVFm1L Greg Burd <greg@burd.me>"
    ];
  };

  # Two example SMF services exercise the generator (T1.11) end-to-end: each
  # renders to a DTD-valid manifest in system.build.toplevel, which make-be
  # stages at /lib/svc/manifest/solnix and activation imports via svccfg.
  #
  # sshd: a contract daemon (design-smf-init §1.3). Kept DISABLED because the
  # image's real SSH is the stock modern-OpenSSH network/ssh make-be stages
  # (gotchas #12-#15) which already owns port 22 — enabling this too would
  # collide on :22. It is the canonical generator example; once pkgs.openssh
  # lands in the fork (P1) this becomes the pure-closure sshd and network/ssh
  # is dropped. enable=false keeps `svcs -x` clean while still generating the
  # manifest into the toplevel (proves generation without a port clash).
  smf.services.sshd = {
    enable = false;
    category = "network";
    description = "OpenSSH server (generator example; stock network/ssh serves :22)";
    model = "contract";
    requires = [
      "svc:/milestone/network:default"
      "svc:/system/filesystem/local:default"
    ];
    # TODO(P1): ${pkgs.openssh}/sbin/sshd once the fork ships openssh.
    start.exec = "/usr/sbin/sshd -f /etc/ssh/sshd_config";
    stop.exec = ":kill"; # svc.startd kills the contract
    refresh.exec = ":kill -HUP"; # reload config
    properties.config = {
      listen_addr = "0.0.0.0";
      port = "22";
    };
  };

  # A transient oneshot (design-smf-init §1.4): the smallest ENABLED
  # config-generated service that actually runs on-target and reaches online
  # (transient = start method returning OK means done). Proves the whole path:
  # generate -> toplevel -> make-be stage -> manifest-import -> svc.startd runs
  # it -> online. Uses only proto-shipped tools so it has no external dep.
  smf.services.solnix-marker = {
    enable = true;
    category = "site";
    description = "solnix config-generated marker (T2.8 toplevel proof)";
    model = "transient";
    requires = [ "svc:/system/filesystem/local:default" ];
    start.exec = "/usr/bin/echo solnix config-generated service online";
    start.timeoutSeconds = 30;
    stop.exec = ":true";
  };

  # T2.5 GATE A witness: a SECOND transient oneshot, added by the config change
  # under test. Its presence live (svcs shows site/solnix-switch-witness online)
  # after `switch-to-configuration switch <newtop>` — with no reboot — is the
  # proof that the live SMF reconcile (svccfg import + svcadm) took effect.
  # Toggle via SOLNIX_WITNESS at eval; enabled by default so the built toplevel
  # carries it. Harmless if it stays (transient oneshot, no port, proto tools).
  smf.services.solnix-switch-witness = {
    enable = true;
    category = "site";
    description = "solnix T2.5 live-switch witness oneshot";
    model = "transient";
    requires = [ "svc:/system/filesystem/local:default" ];
    start.exec = "/usr/bin/echo solnix switch-to-configuration live-switch witness online";
    start.timeoutSeconds = 30;
    stop.exec = ":true";
  };

  # Networking + users are now declarative (T2.9, above). Remaining config-
  # surface (filesystems, more services) grows as those modules land.

  # Binary cache: pull prebuilt pkgs.illumos.* / image closures from solnix.io
  # instead of rebuilding (see .kiro/steering/dev-environment.md + docs/cache.md).
  # The cache is the solnix-cache bucket on solnix.io's S3-compatible endpoint,
  # served path-style over plain HTTPS (no credentials needed for reads) as a
  # standard Nix binary cache: nix-cache-info + <hash>.narinfo + nar/*.nar.xz.
  # Signed with cache.solnix.io-1 (secret in secrets/cache-signing.yaml, sops).
  # Publish side: scripts/oi-cache-publish.sh. Verified: T2.3 gate fetched the
  # system-path closure through this URL into a fresh store with require-sigs.
  # Read endpoint: the DB-backed cache service at cache.solnix.io (the flat
  # s3.solnix.io/solnix-cache bucket is now only the publish/staging side; the
  # authoritative substituter fronting the full history is cache.solnix.io).
  nix.settings.substituters = [ "https://cache.solnix.io" ];
  nix.settings.trusted-public-keys = [
    "cache.solnix.io-1:5HAVNxgJW1VK0O6lHSq45MSUwddLO6EM2Rz4NEjRUVk="
  ];
}
