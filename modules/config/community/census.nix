# modules/config/community/census.nix -- solnix-census, the anonymous daily platform ping (options.nix).
# An SMF contract loop (SMF has no periodic model; pgfarm.nix does the same) that runs as `daemon`, not root,
# owns /var/lib/solnix/census, and sends one record per UTC day after a random delay. Installed only when
# active.census; with privacy on (the default) there is no service at all.
{ config, lib, pkgs, solnixSystem, ... }:

let
  c = config.solnix.telemetry.census;
  a = config.solnix.community.active;
  loc = c.location;
  iso = lib.filter (s: s != "") (lib.splitString " " (lib.replaceStrings [ "\n" ] [ " " ] (builtins.readFile ./iso3166-1-alpha2.txt)));
  b = v: if v then "true" else "false";
  checks = lib.optionals (loc != null) [
    { assertion = lib.elem loc.country iso;
      message = "solnix.telemetry.census.location.country = \"${loc.country}\" is not an ISO 3166-1 alpha-2 code (uppercase, e.g. \"US\")."; }
    { assertion = loc.region == null || builtins.match "[A-Z0-9]{1,3}" loc.region != null;
      message = "solnix.telemetry.census.location.region must be the ISO 3166-2 subdivision part (1-3 of A-Z 0-9, e.g. \"MA\" for US-MA)."; }
    { assertion = loc.locality == null || builtins.match "[ !#-\\[-~]{1,64}" loc.locality != null;
      message = "solnix.telemetry.census.location.locality must be 1-64 printable ASCII characters without \" or \\."; }
  ];
in
{
  config = lib.mkMerge [
    { assertions = checks; }
    (lib.mkIf a.census {
      smf.services.solnix-census = {
        enable = true;
        category = "site";
        description = "solnix anonymous daily platform census (telemetry.solnix.io)";
        model = "contract";
        requires = [ "svc:/milestone/network:default" "svc:/site/solnix-census-setup:default" ];
        environment = {
          CENSUS_PATH = "${pkgs.solnix.nixChain.curl}/bin:/usr/bin:/usr/sbin";
          CURL_CA_BUNDLE = "${pkgs.solnix.nixChain.cacert}/etc/ssl/certs/ca-bundle.crt";
          CENSUS_STATE = "/var/lib/solnix/census";
          CENSUS_ENDPOINT = if c.endpoint == null then "" else c.endpoint;
          CENSUS_SYSTEM = solnixSystem;
          CENSUS_HOST_KIND = c.hostKind;
          # true only when the service is really installed, so a flag never runs ahead of the code
          CENSUS_seeding = b (config.smf.services ? solnix-seed);
          CENSUS_building = b (config.smf.services ? solnix-builder);
          CENSUS_builder = b a.builder;   # the operator asserts it: enrolled by hand (dixa/dixi/lixi) or by solnix-builder-identity
        } // lib.optionalAttrs (loc != null) {
          CENSUS_LOC_COUNTRY = loc.country;
          CENSUS_LOC_REGION = if loc.region == null then "" else loc.region;
          CENSUS_LOC_LOCALITY = if loc.locality == null then "" else loc.locality;
        };
        user = "daemon";   # SMF method_credential: the loop never runs as root
        start.exec = "/usr/bin/ksh93 ${./solnix-census.sh} &";
        stop.exec = ":kill";
      };
      # root's part: the state dir, owned by daemon, before the loop starts.
      smf.services.solnix-census-setup = {
        enable = true;
        category = "site";
        description = "solnix census state directory";
        model = "transient";
        requires = [ "svc:/system/filesystem/local:default" ];
        start.exec = "mkdir -p -m 0700 /var/lib/solnix/census && chown daemon /var/lib/solnix/census";
        stop.exec = ":true";
      };
    })
  ];
}
