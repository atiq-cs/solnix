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

  # One example SMF service to exercise the generator once it's wired (T1.11).
  # sshd is a contract daemon (docs/design-smf-init.md §1.3). The start.exec
  # references pkgs.openssh, which resolves only against the fork — so this whole
  # attr set is a documented stub until then.
  smf.services.sshd = {
    enable = true;
    category = "network";
    description = "OpenSSH server";
    model = "contract";
    requires = [
      "svc:/milestone/network:default"
      "svc:/system/filesystem/local:default"
    ];
    # TODO(P1): ${pkgs.openssh}/sbin/sshd — pkgs.openssh needs the nixpkgs fork.
    # Left as a literal path placeholder so the option type-checks without pkgs.
    start.exec = "/run/current-system/sw/sbin/sshd -f /etc/ssh/sshd_config";
    stop.exec = ":kill"; # svc.startd kills the contract
    refresh.exec = ":kill -HUP"; # reload config
    properties.config = {
      listen_addr = "0.0.0.0";
      port = "22";
    };
  };

  # No users/networking/fs config here yet — those modules (P2.3) don't
  # exist. This is deliberately the smallest config that names the platform and
  # one service. Grow it as the modules it needs land.
}
