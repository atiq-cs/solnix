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
  #
  # ⚠️ `isNormalUser` DOES NOT EXIST in solnix's module set -- this said
  # `isNormalUser = true` and the eval failed with "The option
  # users.users.gburd.isNormalUser does not exist". That is a NixOS option name;
  # modules/config/users.nix models the inverse (`isRoot`, defaulting to `name ==
  # "root"`), so a normal user is simply one that does not set it. Same class as the
  # system.stateVersion / solnix.home.style traps this file's own header warns about --
  # a NixOS option name assumed to exist here.
  #
  # ⚠️ AND `uid` IS REQUIRED for a non-root user: users.nix documents it as "Required
  # unless isRoot" and defaults it to null. 1000 matches the NixOS convention for the
  # first human account and is above illumos's reserved range.
  users.users.gburd = {
    uid = 1000;
    home = "/home/gburd";
    group = "staff";
    extraGroups = [ "sysadmin" ];
    # ⚠️ /bin/sh, not /bin/bash: BASH IS NOT IN THE GATE PROTO AT ALL (measured --
    # `find` over the proto for a file named bash returns nothing; it is an
    # OpenIndiana package, not illumos core-OS). users.nix's own default is
    # /usr/bin/ksh93 with the comment "bash may not [ship]", which is now confirmed.
    shell = "/usr/bin/ksh93";
    # No password here on purpose: a hash in a git-tracked config is a hazard, and
    # the installer prompts for it. Set with `passwd gburd` if this path is used
    # before the installer learns --flake.
  };

  # What a `home-manager switch --flake ~/ws/nix-config#gburd@dixi` needs present
  # BEFORE it can run. nix itself comes from base.nix; these are its prerequisites.
  #
  # ⚠️ THE NAMESPACE MATTERS AND `pkgs.<name>` IS WRONG HERE. This list was
  # `with pkgs; [ git curl openssl ]`, which fails on the HOST eval path with
  # `error: undefined variable 'git'`: lib/host-pkgs.nix builds a MINIMAL pkgs shim
  # (solnix.* plus writeText/writeScript/runCommand/buildEnv) and has no top-level
  # package attributes at all -- there is no nixpkgs on the illumos host, which is the
  # entire reason the shim exists. The real names live under pkgs.solnix.starter.*,
  # keyed off docs/registry/real-derivations.tsv, exactly as base.nix uses them.
  #
  # ⚠️ AND openssl IS NOT AVAILABLE, which is worth stating rather than quietly
  # dropping: every openssl row in real-derivations.tsv is `staged`, not `published`,
  # so pkgs.solnix.starter has no openssl and referencing it is an eval error. The
  # comment below called it "load-bearing" for password hashing -- that need is real,
  # and it is now an explicit gap rather than a line that looks satisfied. solnix-install
  # already carries fallbacks for hashing; when openssl is published, add it back here.
  #
  # ⚠️ NETWORK IS THE HARD PREREQUISITE and it is not satisfiable over wifi on this
  # machine: the Intel AX2xx has no illumos driver, no OpenSolaris fork has one
  # (checked illumos-gate, omnios, joyent and nexenta -- newest Intel support is the
  # iwn/iwp 6000-series era, and zero forks claim 0x2723/0x2725/0x02f0), and the
  # OpenBSD iwx port was abandoned after measuring that it needs a BSD
  # network-interface layer illumos never had. USB-ethernet is the answer; note
  # illumos's four USB-ethernet drivers are Fast Ethernet only and none claims
  # RTL8153, so an ASIX AX88772-based dongle is the safe choice.
  environment.systemPackages = (with pkgs.solnix.starter; [
    git          # flake input fetching
    curl
  ]) ++ (with pkgs.solnix; [
    # The illumos CORE-OS slices, as REAL DERIVATIONS (pkgs/illumos/slices.nix, carved
    # from the gate proto with a COMPUTED DT_NEEDED closure). These are precisely the
    # tools docs/image-nixification-gap.md measured as "NOT available as derivations":
    # df comes from core-utils, useradd/passwd from oamuser, reboot/halt/poweroff from
    # halt (one inode, three names), zpool/zfs from zfs. Listing them here is what puts
    # them in the toplevel's CLOSURE, which is the whole point of
    # `storeContents = [ toplevel ]`.
    #
    # ⚠️ NOT a new option: these go through environment.systemPackages, the option that
    # already exists (modules/config/system-path.nix). I started to add a
    # `solnix.corePackages` for this and checked -- it does not exist in modules/, and
    # setting an undefined option is an eval error, the same trap dixi.nix's own header
    # warns about for system.stateVersion and solnix.home.style.
    #
    # ⚠️ illumos-smf is deliberately ABSENT: its svccfg cannot run (it NEEDs
    # libxml2.so.16, which exists in no reachable build -- see slices.nix). The SMF
    # stack still comes from pkgs.solnix.base-tools via systemPath as before; adding
    # illumos-smf here would put a knowingly-broken svccfg on PATH ahead of it.
    core-utils
    oamuser
    halt
    zfs
  ]);

  # NOTE: no system.stateVersion here -- solnix's module set does not define that
  # option (checked modules/), and setting an undefined option is an eval error.
  # base.nix owns whatever versioning exists.
}
