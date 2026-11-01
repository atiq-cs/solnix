{ config, lib, ... }:
# modules/config/coreadm.nix — core-file policy for solnix systems.
#
# illumos `coreadm` governs core files; the persistent config is /etc/coreadm.conf,
# read by svc:/system/coreadm:default at boot (`coreadm -U` imports it into SMF).
#
# Two kinds of core, both enabled by default, neither littering the CWD:
#
#   GLOBAL  (every crash, incl. setuid/daemons): /var/cores/core.<prog>.<pid>.<time>,
#           owned by root, mode 0600. For the system: daemons and setid programs.
#
#   PER-PROCESS (the user's own programs): /var/cores/<uid>/core.<prog>.<pid>.<time>,
#           written with the crashing process's credentials, so it is owned by
#           the user and readable by them. A developer finds their cores there.
#           %u (effective uid) keys the directory (uts/common/os/core.c expand_string).
#           The init pattern is inherited by every process started after boot.
#
# /var/cores is a shared dataset on <pool>/var systems, so cores survive a
# generation switch. NixOS's analog is systemd-coredump (cores to the journal,
# coredumpctl); illumos has no journal, so cores are files.
#
# solnix.coreadm.developerUsers names the accounts that get a /var/cores/<uid>
# directory they own (created by install-be's per-user pass); the per-process
# pattern then lands their cores where they can read them.
let
  cfg = config.solnix.coreadm;
  devUids = map (n: toString config.users.users.${n}.uid) cfg.developerUsers;
in
{
  options.solnix.coreadm = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Manage the illumos core-file policy (route to /var/cores, no CWD litter).";
    };
    perProcess = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Write each process's core with its own credentials to
        /var/cores/<uid>/, owned by that user (in addition to the global root-owned
        copy). This is what lets a developer read the cores of programs they run.
      '';
    };
    globalEnabled = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Enable the GLOBAL (every-crash) core pattern. The installer LIVE media
        sets this false: its root is a tight RAM UFS ramdisk, and a daemon core
        dumped there (e.g. an aborting svc.configd) fills the filesystem and takes
        SMF down with it (measured). An installed system on a real pool keeps it on.
      '';
    };
    # NixOS bounds cores too (systemd-coredump: MaxUse 10% of the fs, tmpfiles `d /var/lib/systemd/coredump 2w`).
    # The global core ignores RLIMIT_CORE (gate core.c: cg->core_rlimit), so a session ulimit cannot stop them;
    # the bound is a pruning loop. lixi: a COSMIC logout wrote ~16 cores (2 GB) each time, 118 in a day.
    prune = {
      enable = lib.mkOption { type = lib.types.bool; default = true;
        description = "Prune /var/cores (solnix-core-prune): by age, per program, and total size, oldest first."; };
      maxAgeDays = lib.mkOption { type = lib.types.ints.positive; default = 14;
        description = "Remove cores older than this (NixOS: 2 weeks)."; };
      keepPerProgram = lib.mkOption { type = lib.types.ints.positive; default = 3;
        description = "Keep only the newest N cores of each program name."; };
      maxUseMB = lib.mkOption { type = lib.types.ints.positive; default = 4096;
        description = "Remove the oldest cores past this total, in MiB."; };
    };
    developerUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "gburd" ];
      description = ''
        Accounts that get a /var/cores/<uid> directory they own, so the
        per-process core pattern can write their cores there. Each name must be in
        users.users with a uid.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = map (n: {
      assertion = config.users.users ? ${n} && config.users.users.${n}.uid != null;
      message = "solnix.coreadm.developerUsers: ${n} must be a users.users entry with a uid";
    }) cfg.developerUsers;

    environment.generatedEtc."coreadm.conf" = ''
      COREADM_GLOB_PATTERN=/var/cores/core.%f.%p.%t
      COREADM_GLOB_CONTENT=default
      COREADM_INIT_PATTERN=/var/cores/%u/core.%f.%p.%t
      COREADM_INIT_CONTENT=default
      COREADM_GLOB_ENABLED=${if cfg.globalEnabled then "yes" else "no"}
      COREADM_PROC_ENABLED=${if cfg.perProcess then "yes" else "no"}
      COREADM_GLOB_SETID_ENABLED=no
      COREADM_PROC_SETID_ENABLED=no
      COREADM_GLOB_LOG_ENABLED=yes
    '';

    # install-be creates /var/cores/<uid> owned by that uid for each listed account
    # (it reads this list from the generated etc). A process whose user has no
    # such directory still gets the global root-owned core; its per-process write
    # just fails (coreadm logs it).
    environment.generatedEtc."solnix/core-users" =
      lib.concatStringsSep "\n" devUids + lib.optionalString (devUids != [ ]) "\n";

    smf.services.solnix-core-prune = lib.mkIf cfg.prune.enable {
      enable = true;
      category = "site";
      description = "solnix /var/cores bound (age, per program, total size)";
      model = "contract";
      requires = [ "svc:/system/filesystem/local:default" ];
      environment = {
        CORE_DIR = "/var/cores";
        CORE_MAX_AGE_DAYS = toString cfg.prune.maxAgeDays;
        CORE_KEEP_PER_PROGRAM = toString cfg.prune.keepPerProgram;
        CORE_MAX_USE_MB = toString cfg.prune.maxUseMB;
      };
      start.exec = "/usr/bin/ksh93 ${./core-prune.sh} &";
      stop.exec = ":kill";
    };
  };
}
