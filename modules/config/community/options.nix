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
      advisories = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Ask the census reply for solnix.io's CVE advisory feed (one more boolean in the record, "advisories": true). The
          host fetches the public feed when it changed, verifies its sha256, and matches it against its own store paths
          locally; nothing about the result is sent. Adds the solnix-advisories command and one census-log line a day.
          Only while the census itself is active.
        '';
      };
    };
    cache.seed.enable = on "Seed what this host fetched or built over BitTorrent (tracker.solnix.io; peers see this host's IP).";
    cache.build.enable = on "Build solnix.io's queued packages in idle time.";
    builder = {
      enable = mkOption { type = types.bool; default = false; description = "Identified builder: send this host's ssh-ed25519 identity (a separate, stronger opt-in)."; };
      contactEmail = mkOption { type = types.nullOr (types.strMatching "[^@[:space:]\"]+@[^@[:space:]\"]+"); default = null; description = "Optional contact address, sent only in the builder enrolment record."; };
      # bzone1 (2026-10-30): build as an unprivileged, isolated identity. "zone" = the queue builder AND its nix-daemon
      # in their own zone (builder-zone.nix): on illumos (sandbox = false) build code runs as the daemon's nixbld users
      # in the daemon's zone, so only a zone with its own daemon and store keeps a recipe from the host. "none" = the
      # global-zone service (builder.nix), root in a capped project.
      isolation = mkOption { type = types.enum [ "none" "zone" ]; default = "none";
        description = "Where the queue builder runs: none (global zone, root) or zone (its own zone, an untrusted user)."; };
      shortId = mkOption { type = types.nullOr (types.strMatching "[a-z0-9]{4,12}"); default = null;
        description = "The builder's short id (infra assigns one per enrolled builder key); the zone user is solnix-builder-<shortId>."; };
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
