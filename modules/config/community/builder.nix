# modules/config/community/builder.nix -- solnix-builder, the idle-time solnix.io queue drainer (solnix-builder.sh).
# An SMF contract loop, root (nix builds go through nix-daemon; it reads the 0600 bearer), started in its own project
# `solnix-builder` with a CPU cap (project.cpu-cap, resource_controls(7)), and every build runs under nice 19. It only
# claims while the 1-minute load is below loadMax. Without /var/lib/solnix/build-queue-bearer it never claims.
#
# The bearer: one shared X-Solnix-Build secret (infra 2026-10-28), sops solnix secrets/build-queue-bearer.yaml key
# `build-queue-bearer`. It is NEVER in the store: the operator places it, root-only (see docs/community-features.md).
{ config, lib, pkgs, solnixSystem, ... }:

let
  a = config.solnix.community.active;
  cfg = config.solnix.cache.build;
  st = "/var/lib/solnix/builder";
  s = pkgs.solnix;
  path = "${s.jq}/bin:${s.nixChain.curl}/bin:${config.nix.package}/bin:/usr/bin:/usr/sbin";
in
{
  options.solnix.cache.build = {
    cpuCap = lib.mkOption { type = lib.types.ints.between 10 10000; default = 50 * 8;
      description = "project.cpu-cap for the builder, in percent of one CPU (100 = one CPU)."; };
    loadMax = lib.mkOption { type = lib.types.ints.positive; default = 2;
      description = "Claim only while the 1-minute load average is below this."; };
    agentId = lib.mkOption { type = lib.types.strMatching "[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}"; default = config.networking.hostName;
      description = "agent_id sent to the queue (the host name)."; };
  };
  config = lib.mkIf a.build {
    # the generation owns /etc/project: the gate's stock file (./project.stock, sha256 0b4ce25c..., = dixi's and dixa's) + ours
    environment.generatedEtc.project = builtins.readFile ./project.stock
      + "solnix-builder:4242:solnix idle queue builder::root:project.cpu-cap=(privileged,${toString cfg.cpuCap},deny)\n";
    smf.services.solnix-builder = {
      enable = true;
      category = "site";
      description = "solnix idle-time build-queue drainer (telemetry.solnix.io)";
      model = "contract";
      requires = [ "svc:/milestone/network:default" "svc:/milestone/name-services:default" "svc:/system/filesystem/local:default" "svc:/system/nix-daemon:default" ];
      environment = {
        BUILDER_PATH = path;
        CURL_CA_BUNDLE = "${s.nixChain.cacert}/etc/ssl/certs/ca-bundle.crt";
        BUILDER_STATE = st;
        BUILDER_SYSTEM = solnixSystem;
        BUILDER_AGENT = cfg.agentId;
        BUILDER_LOAD_MAX = toString cfg.loadMax;
      };
      start.exec = "mkdir -p -m 0700 ${st} && /usr/bin/newtask -p solnix-builder /usr/bin/ksh93 ${./solnix-builder.sh} &";
      stop.exec = ":kill";
    };
  };
}
