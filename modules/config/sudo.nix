{ config, lib, pkgs, ... }:
# modules/config/sudo.nix -- a `sudo` command over illumos RBAC (scripts/sudo.sh).
# NixOS ships sudo with security.sudo; on illumos the privilege mechanism is RBAC
# (pfexec and the user's profiles), so solnix keeps that authority and gives it
# sudo's command line: sudo cmd, -u, -i, -s, -E, -n, -l, -v/-k as no-ops. A user
# with the Primary Administrator profile can run anything, as a member of wheel
# can on NixOS. No sudoers file and no password prompt: the RBAC profiles are the
# policy, configured with users.users.<n>.profiles.
#
# A real program in system.path (not a shell function), so scripts, ksh93, cron
# jobs and `env sudo ...` find it too.
let
  sudo = pkgs.runCommand "solnix-sudo" { script = ./scripts/sudo.sh; } ''
    mkdir -p $out/bin
    cp $script $out/bin/sudo
    chmod 0555 $out/bin/sudo
  '';
in
{
  options.security.sudo.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Whether the sudo command (RBAC/pfexec underneath) is installed.";
  };
  config = lib.mkIf config.security.sudo.enable {
    environment.systemPackages = [ sudo ];
  };
}
