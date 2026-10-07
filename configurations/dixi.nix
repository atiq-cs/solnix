# configurations/dixi.nix -- the maintainer's Lenovo X1 Carbon: base.nix plus the
# gburd account, the X1's wired NIC and the tools a nix-config checkout needs.
#
# The maintainer's own copy lives in his nix-config (nixos/solnix/dixi.nix); this
# one is what solnix tests the install path with. Build or install it as
#   nix build .#dixiToplevel
#   solnix-install --flake '<this repo>#dixi' <disk>
{ config, lib, pkgs, ... }:

{
  imports = [ ./base.nix ];

  networking.hostName = "dixi";

  # illumos has no wheel and no sudo in the gate. RBAC's "Primary Administrator"
  # profile (prof_attr: uid=0;gid=0) makes `pfexec <cmd>` root-equivalent; sysadmin
  # (gid 14) is the group half. The home is on the <pool>/home dataset the
  # installer creates (shared by every boot environment). No password here: the
  # installer asks for it, and later generations keep it (users.mutableUsers).
  users.users.gburd = {
    uid = 1000;
    home = "/home/gburd";
    group = "staff";
    extraGroups = [ "sysadmin" ];
    profiles = [ "Primary Administrator" ];
    shell = "/usr/bin/ksh93";
  };

  # From source in this repo. The cache-only pkgs.solnix.starter.{git,curl} were
  # retired from the cache; the core-utils/oamuser/halt/zfs slices are in the world.
  environment.systemPackages = with pkgs.solnix; [ git curl ];

  # The X1's onboard NIC is e1000g0 (measured); base.nix's ena0 is EC2's.
  networking.interfaces = { ena0.dhcp = false; e1000g0.dhcp = true; };
  networking.nameservers = lib.mkForce [ "1.1.1.1" "8.8.8.8" ];
}
