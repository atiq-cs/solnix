# configurations/dixi.nix — the maintainer's x86_64 workstation/dev host.
#
# The target of `solnix-install --flake .#dixi`. It is base.nix (the minimal
# bootable system) plus the things this specific machine needs: a `gburd` account
# whose home is on its own dataset, and the tooling a nix-config + home-manager
# switch needs on first boot.
#
# ⚠️ WHAT THIS DOES **NOT** DO YET, stated up front so nobody reads it as working:
# `solnix-install` does not consume this file. It still copies the live root
# (SELF_INSTALL) rather than building a toplevel and `nix copy`ing its closure,
# because the toplevel cannot yet contain a usable system -- df, useradd, passwd,
# reboot, zpool, svcadm and the kernel are illumos CORE-OS and are not derivations.
# The gate FOD (docs/design-nixos-iso-methodology.md step 1) is what unblocks that.
# See docs/design-solnix-install-flake.md for the full sequencing.
#
# So this file exists to be READY, and to make the gap concrete rather than
# hypothetical: it is the thing `--flake .#dixi` will build.
#
# Select it as:
#   nix build .#dixiToplevel                        (flake, evaluates anywhere)
#   nix-build lib/eval-host.nix -A toplevel \
#     --arg configModule ../configurations/dixi.nix   (on the illumos host)

{ config, lib, pkgs, ... }:

{
  imports = [ ./base.nix ];

  networking.hostName = "dixi";

  # /home, not /export/home. FreeBSD's bsdinstall creates a plain
  # `/home mountpoint=/home` dataset (usr.sbin/bsdinstall/scripts/zfsboot:154) with
  # the comment "Home directories separated so they are common to all BEs" -- the
  # same BE-sharing reason Solaris uses /export/home, without the indirection.
  #
  # ⚠️ The dataset alone is NOT enough on illumos: /etc/auto_master maps
  # `/home auto_home -nobrowse`, so autofs OWNS /home and shadows any local mount
  # at boot. Measured on the maintainer's existing host `sun`, which already runs
  # /home/gburd: the autofs SERVICE is disabled there, and the auto_master line is
  # still present -- harmless only because the service is off. Both halves matter.
  # ⚠️ NO OPTION FOR THIS YET. `solnix.home.style` does not exist -- I nearly
  # shipped it as though it did. Today the choice lives in solnix-install as the
  # SOLNIX_HOME_STYLE env var / interactive prompt (default: home). When
  # --flake lands, that belongs here as a real option in modules/config/.
  # Recording the gap beats inventing an option that silently does nothing.

  # The account the machine exists for. Privilege via illumos-native RBAC rather
  # than a `wheel` group, because illumos HAS no wheel: usr/src/cmd/Adm/group ships
  # staff (10) and sysadmin (14), and the root-equivalent is the "Primary
  # Administrator" profile, which prof_attr defines as uid=0;gid=0. sudo is not in
  # illumos-gate at all (OpenIndiana packages it separately); pfexec is native.
  users.users.gburd = {
    isNormalUser = true;
    home = "/home/gburd";
    group = "staff";
    extraGroups = [ "sysadmin" ];
    shell = "/bin/bash";
    # No password here on purpose: a hash in a git-tracked config is a hazard, and
    # the installer prompts for it. Set with `passwd gburd` if this path is used
    # before the installer learns --flake.
  };

  # What a `home-manager switch --flake ~/ws/nix-config#gburd@dixi` needs present
  # BEFORE it can run. nix itself comes from base.nix; these are its prerequisites.
  #
  # ⚠️ NETWORK IS THE HARD PREREQUISITE and it is not satisfiable over wifi on this
  # machine: the Intel AX2xx has no illumos driver, no OpenSolaris fork has one
  # (checked illumos-gate, omnios, joyent and nexenta -- newest Intel support is the
  # iwn/iwp 6000-series era, and zero forks claim 0x2723/0x2725/0x02f0), and the
  # OpenBSD iwx port was abandoned after measuring that it needs a BSD
  # network-interface layer illumos never had. USB-ethernet is the answer; note
  # illumos's four USB-ethernet drivers are Fast Ethernet only and none claims
  # RTL8153, so an ASIX AX88772-based dongle is the safe choice.
  environment.systemPackages = with pkgs; [
    git          # flake input fetching
    curl
    openssl      # ⚠️ load-bearing: solnix-install hashes passwords with it, and on
                 # the OI AMI /usr/bin/openssl is a symlink into an unstaged
                 # versioned tree whose libssl is ITSELF a symlink -- a
                 # second-order dangling link that made it unrunnable in image l2
                 # build 1. As a derivation this class of bug cannot occur.
  ];

  # NOTE: no system.stateVersion here -- solnix's module set does not define that
  # option (checked modules/), and setting an undefined option is an eval error.
  # base.nix owns whatever versioning exists.
}
