# services.solnix-accounts -- a read-only org.freedesktop.Accounts for COSMIC Settings > Users, over the illumos account
# files: src/solnix-accounts, docs/solnix-accounts.md. NixOS's cosmic module turns on services.accounts-daemon, which
# reports AccountType 1 (administrator) for members of wheel. illumos has no wheel: administration is RBAC, so this
# service reports 1 for root, for users with the "Primary Administrator" profile (users.users.<name>.profiles) or the
# root role in user_attr, and for members of sysadmin. Same bus name and policy shape as accounts-daemon (root owns the
# name, anyone may read it). Every method that would change an account answers NotSupported for now.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.solnix-accounts;
  ac = pkgs.solnix.solnix-accounts;
in
{
  options.services.solnix-accounts = {
    enable = lib.mkEnableOption "solnix-accounts, a read-only org.freedesktop.Accounts for COSMIC Settings > Users (who is an administrator, by RBAC)";
  };

  config = lib.mkIf cfg.enable {
    assertions = [{ assertion = config.services.dbus.enable; message = "services.solnix-accounts needs services.dbus.enable (the system bus)"; }];
    services.dbus.packages = [ ac ];
    # root: it reads /etc/shadow (0400) for Locked, as accounts-daemon does
    smf.services.solnix-accounts = {
      enable = true;
      category = "site";
      description = "solnix-accounts: org.freedesktop.Accounts on the system bus (read-only; RBAC administrators)";
      model = "contract";
      requires = [ "svc:/system/dbus:default" ];
      start.exec = "${ac}/bin/solnix-accounts &";
      stop.exec = ":kill";
    };
  };
}
