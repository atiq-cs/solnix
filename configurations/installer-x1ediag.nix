# configurations/installer-x1ediag.nix -- the minimal live installer plus a
# diagnostic agent, for chasing an unexplained power-off on real hardware (first
# target: ThinkPad X1 Extreme Gen5, which powers itself off silently while idle,
# even in single-user and with ACPI in legacy mode). It is the installer-live
# image with these additions, so a booted diag stick is still a working
# installer:
#
#   1. site/solnix-x1ediag: scripts/live/solnix-x1ediag -- a heartbeat line every
#      second (with per-CPU C-state) + system log on the boot stick's p3, boot
#      inventory, LAN stream to scripts/x1ediag-receiver.py, previous-boot
#      evidence uploaded first.
#   2. halt_on_panic = 1: a panic prints its message + stack on the framebuffer,
#      then waits at "Press any key to reboot." (panic.c halt_on_panic ->
#      prom_reboot_prompt) instead of resetting -- so it can be photographed.
#      Proven on the X1E. No crash dump: scsa2usb drops all I/O while in panic.
#   3. /etc/system.alt/<variant>: complete alternate /etc/system files for the
#      boot-time-only kernel tunables (idle_cpu_no_deep_c is read once in
#      mp_machdep.c startup). `boot -a` asks "Name of system file"; naming one
#      replaces /etc/system AND the system.d self-assembly (modctl.c
#      mod_askparams sets self_assembly = NULL), so install-be assembles each as
#      the full normal configuration plus its extra lines, as a real file.
{ lib, pkgs, ... }:

let
  agent = pkgs.writeScript "solnix-x1ediag" (builtins.readFile ../scripts/live/solnix-x1ediag);
  watch = pkgs.writeScript "solnix-x1ewatch" (builtins.readFile ../scripts/live/solnix-x1ewatch);
in
{
  imports = [ ./installer-live.nix ];

  # Hostname stays solnix-installer (installer-live mkForce's it); the agent tags
  # every upload with the boot id, which is what tells iterations apart.

  environment.generatedEtc."system.d/solnix-x1ediag" = ''
    * Stop at the panic message instead of rebooting (configurations/installer-x1ediag.nix).
    set halt_on_panic = 1
  '';

  # Boot-time variants for `boot -a` (install-be assembles each one as the full
  # normal /etc/system + system.d + these lines, at /etc/system.alt/<name>).
  environment.generatedEtc."system.alt/nodeepc.extra" = ''
    * no deep C-states: CPUs idle in C1 only (mp_machdep.c idle_cpu_no_deep_c)
    set idle_cpu_no_deep_c = 1
  '';
  environment.generatedEtc."system.alt/nomwait.extra" = ''
    * no deep C-states and no MWAIT: plain HLT idle (mp_machdep.c idle_cpu_prefer_mwait)
    set idle_cpu_no_deep_c = 1
    set idle_cpu_prefer_mwait = 0
  '';
  environment.generatedEtc."system.alt/nodeadman.extra" = ''
    * ZFS deadman off (spa_misc.c zfs_deadman_enabled)
    set zfs:zfs_deadman_enabled = 0
  '';

  # Iteration 3. The X1E stops at a bare "Press any key to reboot." ~6 min after
  # boot: an AD_POWEROFF/suspend request whose firmware entry did not take, from a
  # requester that printed nothing. powerd (svc:/system/power) is the prime
  # suspect, so it is off here; solnix-x1ewatch names the requester on the
  # console if it is something else.
  solnix.powerManagement.enable = false;

  smf.services.solnix-x1ewatch = {
    enable = true;
    category = "site";
    description = "solnix x1ewatch: name the power-off/suspend requester on the console";
    model = "contract";
    requires = [ "svc:/system/filesystem/minimal:default" ];
    dependents = [ "svc:/milestone/single-user" ];
    start.exec = "${watch} &";
    start.timeoutSeconds = 60;
  };

  smf.services.solnix-x1ediag = {
    enable = true;
    category = "site";
    description = "solnix x1ediag diagnostic agent";
    model = "contract";
    # In `boot -s` only single-user's dependency subgraph runs, and the X1E dies
    # there too, so single-user is made to (optionally) depend on the agent. The
    # agent itself needs only devices + the minimal filesystems.
    requires = [ "svc:/milestone/devices:default" "svc:/system/filesystem/minimal:default" ];
    dependents = [ "svc:/milestone/single-user" ];
    start.exec = "${agent} &";
    start.timeoutSeconds = 60;
  };
}
