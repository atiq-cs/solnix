# modules/config/community/builder.nix -- solnix-builder, the idle-time solnix.io queue drainer (solnix-builder.sh).
# An SMF contract loop, root (it reads the 0600 bearer; root's nix builds in its own process tree, so the cap covers them),
# started in its own project `solnix-builder` with a CPU cap (project.cpu-cap, resource_controls(7)), every build under
# nice. Each tick it sizes itself from the CPUs other work leaves idle: up to parallelJobs jobs of coresPerJob cores
# (nix.settings.max-jobs/cores, per tick). It only claims a job it has already rebuilt identical to the served NAR.
# profile = "idle" (default): one job, four CPUs, nothing while 2 CPUs are busy, 10-30 min apart (as before qbuild4).
# profile = "opportunistic" (a machine someone uses): 2-core jobs in 2/3 of the CPUs other work leaves idle, a kernel cpu-cap at
#   2/3 of the machine (so running builds yield when the user gets busy), nice 19, 2-10 min apart while it has work.
# profile = "dedicated" (a build host): every idle CPU in 4-core jobs, no cap, back to back (10-30 s) while it has work,
#   2-5 min apart when the queue has nothing it can do.
# Without /var/lib/solnix/build-queue-bearer it never claims.
#
# The bearer: one shared X-Solnix-Build secret (infra 2026-10-28), sops solnix secrets/build-queue-bearer.yaml key
# `build-queue-bearer`. It is NEVER in the store: the operator places it, root-only (see docs/community-features.md).
{ config, lib, pkgs, solnixSystem, ... }:

let
  a = config.solnix.community.active;
  cfg = config.solnix.cache.build;
  st = "/var/lib/solnix/builder";
  s = pkgs.solnix;
  # git: nix 2.24 runs the git CLI to fetch the builder's git+https flake (BUILDER_FLAKE, solnix main)
  path = "${s.jq}/bin:${s.nixChain.curl}/bin:${config.nix.package}/bin:${s.git}/bin:/usr/bin:/usr/sbin";
  ded = cfg.profile == "dedicated";
  opp = cfg.profile == "opportunistic";
  str = v: if v == null then "auto" else toString v;
  # the script's settings (builder-zone.nix exports the same)
  env = {
    BUILDER_AGENT = cfg.agentId;
    BUILDER_LOAD_MAX = str cfg.loadMax;
    BUILDER_JOBS = str cfg.parallelJobs;
    BUILDER_CORES = toString cfg.coresPerJob;
    BUILDER_NICE = toString cfg.nice;
    BUILDER_SHARE = toString cfg.share;
    BUILDER_CAP_SHARE = lib.optionalString (opp && cfg.cpuCap == null) (toString cfg.share);
    BUILDER_TICK_MIN = toString cfg.tickMin; BUILDER_TICK_MAX = toString cfg.tickMax;
    BUILDER_BUSY_TICK_MIN = toString cfg.busyTickMin; BUILDER_BUSY_TICK_MAX = toString cfg.busyTickMax;
    BUILDER_WSWEEP = "${./solnix-wsweep.ksh}";   # stale fixed build dirs of killed builds (wave4)
  };
  cap = lib.optionalString (cfg.cpuCap != null) "project.cpu-cap=(privileged,${toString cfg.cpuCap},deny)";
in
{
  options.solnix.cache.build = {
    profile = lib.mkOption { type = lib.types.enum [ "idle" "opportunistic" "dedicated" ]; default = "idle";
      description = ''
        idle: one job in the host's spare time (the default for a community host).
        opportunistic: a machine someone uses: builds only while it is quiet, in up to 2/3 of the CPUs other work leaves idle,
          re-measured every tick, at nice 19 (a desktop stays responsive).
        dedicated: a build host: every idle CPU, back to back while the queue has work, short sleeps when it has none.
      ''; };
    share = lib.mkOption { type = lib.types.ints.between 1 100; default = if opp then 66 else 100;
      description = "Percent of the CPUs other work leaves idle that the builder may use (dedicated 100, opportunistic 66)."; };
    parallelJobs = lib.mkOption { type = lib.types.nullOr lib.types.ints.positive; default = if ded || opp then null else 1;
      description = "Jobs at once (null: as many as the idle CPUs fit, re-measured each tick)."; };
    coresPerJob = lib.mkOption { type = lib.types.ints.unsigned; default = if ded then 4 else if opp then 2 else 0;
      description = "nix `cores` per job (0: the CPUs divided by parallelJobs)."; };
    cpuCap = lib.mkOption { type = lib.types.nullOr (lib.types.ints.between 10 10000);
      # opportunistic: a kernel cap at share% of the machine, so builds already running when the user gets busy stay within it
      # (the per-tick sample only decides what STARTS). The script sets it from the CPU count once it runs in the project.
      default = if opp then null else if cfg.parallelJobs == null then null
        else cfg.parallelJobs * (if cfg.coresPerJob > 0 then cfg.coresPerJob else 4) * 100;
      description = "project.cpu-cap for the builder, in percent of one CPU (100 = one CPU); null: no fixed cap (opportunistic sets share% of the CPUs at start)."; };
    loadMax = lib.mkOption { type = lib.types.nullOr lib.types.ints.positive; default = if ded || opp then null else 2;
      description = "Start no job while this many CPUs are busy with other work (null: whenever a job's cores are idle)."; };
    nice = lib.mkOption { type = lib.types.ints.between 0 19; default = 19; description = "nice value of every build."; };
    tickMin = lib.mkOption { type = lib.types.ints.positive; default = if ded then 120 else 600; description = "Seconds between ticks after one with nothing to do: at least ..."; };
    tickMax = lib.mkOption { type = lib.types.ints.positive; default = if ded then 300 else 1800; description = "... and at most (random, so a fleet doesn't poll solnix.io in step)."; };
    busyTickMin = lib.mkOption { type = lib.types.ints.positive; default = if ded then 10 else if opp then 120 else cfg.tickMin; description = "Seconds to the next tick after one that rebuilt or completed a job: at least ..."; };
    busyTickMax = lib.mkOption { type = lib.types.ints.positive; default = if ded then 30 else if opp then 600 else cfg.tickMax; description = "... and at most."; };
    agentId = lib.mkOption { type = lib.types.strMatching "[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}"; default = config.networking.hostName;
      description = "agent_id sent to the queue (the host name)."; };
    # what builder-zone.nix runs in the zone: the same script and tools
    internal = lib.mkOption { internal = true; readOnly = true;
      default = { inherit path env; script = ./solnix-builder.sh; cacert = "${s.nixChain.cacert}/etc/ssl/certs/ca-bundle.crt"; }; };
  };
  config = lib.mkIf (a.build && config.solnix.builder.isolation == "none") {
    assertions = [ { assertion = cfg.tickMin <= cfg.tickMax && cfg.busyTickMin <= cfg.busyTickMax;
      message = "solnix.cache.build: tickMin/busyTickMin must not exceed tickMax/busyTickMax."; } ];
    # the generation owns /etc/project: the gate's stock file (./project.stock, sha256 0b4ce25c..., = dixi's and dixa's) + ours
    environment.generatedEtc.project = builtins.readFile ./project.stock
      + "solnix-builder:4242:solnix idle queue builder::root:${cap}\n";
    smf.services.solnix-builder = {
      enable = true;
      category = "site";
      description = "solnix idle-time build-queue drainer (builders.solnix.io)";
      model = "contract";
      requires = [ "svc:/milestone/network:default" "svc:/milestone/name-services:default" "svc:/system/filesystem/local:default" "svc:/system/nix-daemon:default" ];
      environment = env // {
        BUILDER_PATH = path;
        CURL_CA_BUNDLE = "${s.nixChain.cacert}/etc/ssl/certs/ca-bundle.crt";
        BUILDER_STATE = st;
        BUILDER_SYSTEM = solnixSystem;
      };
      start.exec = "mkdir -p -m 0700 ${st} && /usr/bin/newtask -p solnix-builder /usr/bin/ksh93 ${./solnix-builder.sh} &";
      stop.exec = ":kill";
    };
  };
}
