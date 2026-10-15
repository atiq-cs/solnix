# configurations/installer-x1ediag.nix -- the minimal live installer plus a
# diagnostic agent, for chasing an unexplained reboot/shutdown on real hardware
# (first target: ThinkPad X1 Extreme Gen5, which reboots on its own while idle at
# the login prompt). It is the installer-live image with three additions, so a
# booted diag stick is still a working installer:
#
#   1. site/solnix-x1ediag: scripts/live/solnix-x1ediag -- heartbeat + system log
#      on the boot stick's p3, boot inventory, LAN stream to
#      scripts/x1ediag-receiver.py, previous-boot evidence uploaded first.
#   2. halt_on_panic = 1: a panic prints its message + stack on the framebuffer,
#      then waits at "Press any key to reboot." (panic.c halt_on_panic ->
#      prom_reboot_prompt) instead of resetting -- so it can be photographed. A
#      crash dump is not configured: scsa2usb drops all I/O while in panic, so a
#      dump on the USB stick would be empty, and the internal NVMe is the
#      owner's disk.
#   3. the ACPI thermal shutdown (tzmon _HOT -> SIGPWR -> inittab powerfail
#      `shutdown -i5`) is one of the suspects; tzmon logs a CE_WARN before
#      acting, which lands in /var/adm/messages and so in the stick log.
{ lib, pkgs, ... }:

let
  agent = pkgs.writeScript "solnix-x1ediag" (builtins.readFile ../scripts/live/solnix-x1ediag);
in
{
  imports = [ ./installer-live.nix ];

  # Hostname stays solnix-installer (installer-live mkForce's it); the agent tags
  # every upload with the boot id, which is what tells iterations apart.

  environment.generatedEtc."system.d/solnix-x1ediag" = ''
    * Stop at the panic message instead of rebooting (configurations/installer-x1ediag.nix).
    set halt_on_panic = 1
  '';

  smf.services.solnix-x1ediag = {
    enable = true;
    category = "site";
    description = "solnix x1ediag diagnostic agent";
    model = "contract";
    requires = [ "svc:/milestone/multi-user:default" ];
    start.exec = "${agent} &";
    start.timeoutSeconds = 60;
  };
}
