# modules/config/community/builder.nix -- solnix-builder, the idle-time solnix.io queue drainer (solnix-builder.sh).
# An SMF contract loop, root (it reads the 0600 bearer; root's nix builds in its own process tree, so the cap covers them),
# started in its own project `solnix-builder` with a CPU cap (project.cpu-cap, resource_controls(7)), every build under
# nice. Each tick it sizes itself from the CPUs other work leaves idle: up to parallelJobs jobs of coresPerJob cores
# (nix.settings.max-jobs/cores, per tick). It only claims a job it has already rebuilt identical to the served NAR.
# profile = "idle" (default): one job, four CPUs, nothing while 2 CPUs are busy, 10-30 min apart (as before qbuild4).
# profile = "dedicated" (a build host): as many 4-core jobs as idle CPUs allow, no cap, 1-5 min apart while it has work.
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
  str = v: if v == null then "auto" else toString v;
  # the script's settings (builder-zone.nix exports the same)
  env = {
    BUILDER_AGENT = cfg.agentId;
    BUILDER_LOAD_MAX = str cfg.loadMax;
    BUILDER_JOBS = str cfg.parallelJobs;
    BUILDER_CORES = toString cfg.coresPerJob;
    BUILDER_NICE = toString cfg.nice;
    BUILDER_TICK_MIN = toString cfg.tickMin; BUILDER_TICK_MAX = toString cfg.tickMax;
    BUILDER_BUSY_TICK_MIN = toString cfg.busyTickMin; BUILDER_BUSY_TICK_MAX = toString cfg.busyTickMax;
  };
  cap = lib.optionalString (cfg.cpuCap != null) "project.cpu-cap=(privileged,${toString cfg.cpuCap},deny)";
in
{
  options.solnix.cache.build = {
    profile = lib.mkOption { type = lib.types.enum [ "idle" "dedicated" ]; default = "idle";
      description = "idle: one job in the host's spare time. dedicated: a build host, every idle CPU (the defaults below)."; };
    parallelJobs = lib.mkOption { type = lib.types.nullOr lib.types.ints.positive; default = if ded then null else 1;
      description = "Jobs at once (null: as many as the idle CPUs fit, re-measured each tick)."; };
    coresPerJob = lib.mkOption { type = lib.types.ints.unsigned; default = if ded then 4 else 0;
      description = "nix `cores` per job (0: the CPUs divided by parallelJobs)."; };
    cpuCap = lib.mkOption { type = lib.types.nullOr (lib.types.ints.between 10 10000);
      default = if cfg.parallelJobs == null then null else cfg.parallelJobs * (if cfg.coresPerJob > 0 then cfg.coresPerJob else 4) * 100;
      description = "project.cpu-cap for the builder, in percent of one CPU (100 = one CPU); null: no cap."; };
    loadMax = lib.mkOption { type = lib.types.nullOr lib.types.ints.positive; default = if ded then null else 2;
      description = "Start no job while this many CPUs are busy with other work (null: whenever a job's cores are idle)."; };
    nice = lib.mkOption { type = lib.types.ints.between 0 19; default = 19; description = "nice value of every build."; };
    tickMin = lib.mkOption { type = lib.types.ints.positive; default = 600; description = "Seconds between ticks after one with nothing to do: at least ..."; };
    tickMax = lib.mkOption { type = lib.types.ints.positive; default = 1800; description = "... and at most (random, so a fleet doesn't poll solnix.io in step)."; };
    busyTickMin = lib.mkOption { type = lib.types.ints.positive; default = if ded then 60 else cfg.tickMin; description = "Seconds to the next tick after one that rebuilt or completed a job: at least ..."; };
    busyTickMax = lib.mkOption { type = lib.types.ints.positive; default = if ded then 300 else cfg.tickMax; description = "... and at most."; };
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
      description = "solnix idle-time build-queue drainer (telemetry.solnix.io)";
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
