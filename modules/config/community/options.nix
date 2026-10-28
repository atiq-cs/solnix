# modules/config/community/options.nix -- the solnix.io community opt-in (infra handoff 2026-10-28 §1,
# docs/design-telemetry-client.md §1). Private by default: with solnix.privacy.enable = true (the default)
# nothing below installs a service, sends a record or joins a swarm. Effective rule, implemented once here:
#   active(feature) = !privacy.enable && <group>.enable && <feature>.enable
# The services (census.nix, cache-proxy.nix, seed.nix, builder.nix) read solnix.community.active.*.
{ config, lib, ... }:

let
  inherit (lib) mkOption types;
  cfg = config.solnix;
  on = d: mkOption { type = types.bool; default = true; description = d + " Only with solnix.privacy.enable = false."; };
in
{
  options.solnix = {
    privacy.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Fully private (the default): no census, no seeding, no queue building. Set false to join the community cache.";
    };
    telemetry.enable = on "Group switch for everything that reports to telemetry.solnix.io.";
    telemetry.census = {
      enable = on "The anonymous daily platform census (arch, flavour, host kind; the edge derives the country and drops the IP).";
      endpoint = mkOption {
        type = types.nullOr types.str;
        default = "https://telemetry.solnix.io/api/v1/census";
        description = "Census ingest URL. null = build the record but never send it.";
      };
      hostKind = mkOption {
        type = types.enum [ "server" "laptop" "workstation" ];
        default = "server";
        description = "The census :host-kind (a closed vocabulary, so it cannot fingerprint).";
      };
      location = mkOption {
        default = null;
        description = ''
          A location the operator chooses to volunteer (never derived on the host). Unset = none is sent and the
          edge derives the country. When set, the edge skips GeoIP and stores exactly this.
        '';
        type = types.nullOr (types.submodule {
          options.country = mkOption { type = types.str; example = "US"; description = "ISO 3166-1 alpha-2."; };
          options.region = mkOption { type = types.nullOr types.str; default = null; example = "MA"; description = "ISO 3166-2 subdivision code: the part after \"US-\"."; };
          options.locality = mkOption { type = types.nullOr types.str; default = null; description = "Free text, at most 64 printable ASCII characters, no \" or \\."; };
        });
      };
    };
    cache.seed.enable = on "Seed what this host fetched or built over BitTorrent (tracker.solnix.io; peers see this host's IP).";
    cache.build.enable = on "Build solnix.io's queued packages in idle time.";
    builder = {
      enable = mkOption { type = types.bool; default = false; description = "Identified builder: send this host's ssh-ed25519 identity (a separate, stronger opt-in)."; };
      contactEmail = mkOption { type = types.nullOr (types.strMatching "[^@[:space:]\"]+@[^@[:space:]\"]+"); default = null; description = "Optional contact address, sent only in the builder enrolment record."; };
      identityKeyFile = mkOption { type = types.str; default = "/etc/ssh/ssh_host_ed25519_key"; description = "The builder identity: the host's own ssh-ed25519 key (kept in sops off the host)."; };
    };
    community.active = mkOption {
      readOnly = true;
      internal = true;
      default = let p = !cfg.privacy.enable; in {
        census = p && cfg.telemetry.enable && cfg.telemetry.census.enable;
        seed = p && cfg.cache.seed.enable;
        build = p && cfg.cache.build.enable;
        builder = p && cfg.builder.enable;
      };
      description = "The effective feature switches (privacy master switch applied).";
    };
  };
}
