#!/usr/bin/env bash
# test-community-eval.sh -- the community opt-in at EVAL time (no illumos needed; run on floki):
#  - privacy on (default): no community service at all; privacy off: the census service, its record env;
#  - :location assertions accept valid ISO codes and REJECT bad ones (each bad case must fail eval);
#  - census.enable=false or telemetry.enable=false removes the service (group && feature).
set -u
F=${1:-$(cd "$(dirname "$0")/.." && pwd)}; bad=0
ev() { nix eval --json --impure --expr "let f = builtins.getFlake \"git+file://$F\";
  c = (f.lib.solnixSystem { system = \"x86_64-solaris\"; pkgs = f.lib.mkPkgs { };
    modules = [ $F/configurations/base.nix ($2) ]; }).config; in $1" 2>&1; }
want() { # want <name> <expect-regex> <expr> <module>
  out=$(ev "$3" "$4" | tail -1)
  if echo "$out" | grep -qE "$2"; then echo "ok: $1"; else echo "FAIL: $1: got: $out"; bad=1; fi; }
svcs='builtins.filter (n: builtins.match "solnix-(census|cache-proxy|seed|builder).*" n != null) (builtins.attrNames c.smf.services)'
env='c.smf.services.solnix-census.environment'
chk='c.system.assertionsChecked'
want "default private: no community services" '^\[\]$' "$svcs" '{ }'
want "opted in: builder + census + cache-proxy services" '"solnix-builder","solnix-cache-proxy","solnix-cache-proxy-setup","solnix-census","solnix-census-setup"' "$svcs" '{ solnix.privacy.enable = false; }'
want "opted in: proxy is an extra substituter" '"http://127.0.0.1:37515"' 'c.nix.settings.extra-substituters' '{ solnix.privacy.enable = false; }'
want "opted in: cache.solnix.io still a substituter" '"https://cache.solnix.io"' 'c.nix.settings.substituters' '{ solnix.privacy.enable = false; }'
want "opted in: proxy bound to 127.0.0.1, tcp (v4)" "bind_addr' type='astring' value='127.0.0.1'.*proto' type='astring' value='tcp'|proto' type='astring' value='tcp'.*bind_addr' type='astring' value='127.0.0.1'" 'c.smf.services.solnix-cache-proxy.extraManifestXML' '{ solnix.privacy.enable = false; }'
want "opted in: services(5) has the port" 'solnix-cache-proxy\\t37515/tcp' 'c.environment.generatedEtc."inet/services"' '{ solnix.privacy.enable = false; }'
want "default: no proxy substituter" '^null$' 'c.nix.settings.extra-substituters or null' '{ }'
want "seed.enable = false: no proxy" '^false$' 'c.smf.services ? solnix-cache-proxy' '{ solnix.privacy.enable = false; solnix.cache.seed.enable = false; }'
want "opted in: endpoint is telemetry.solnix.io/api/v1/census" '"CENSUS_ENDPOINT":"https://telemetry.solnix.io/api/v1/census"' "$env" '{ solnix.privacy.enable = false; }'
want "opted in: flags = installed services (building: the builder is installed; no seeder yet)" '"CENSUS_builder":"false","CENSUS_building":"true".*"CENSUS_seeding":"false"' "$env" '{ solnix.privacy.enable = false; }'
want "no location unless set (list)" '^\[\]$' "builtins.filter (n: builtins.match \"CENSUS_LOC.*\" n != null) (builtins.attrNames $env)" '{ solnix.privacy.enable = false; }'
want "census.enable = false: census gone, proxy + builder stay" '^\["solnix-builder","solnix-cache-proxy","solnix-cache-proxy-setup"\]$' "$svcs" '{ solnix.privacy.enable = false; solnix.telemetry.census.enable = false; }'
want "telemetry.enable = false: gone" '^\[\]$' "$svcs" '{ solnix.privacy.enable = false; solnix.telemetry.enable = false; solnix.cache.seed.enable = false; solnix.cache.build.enable = false; }'
L='solnix.privacy.enable = false; solnix.telemetry.census.location'
want "location US/MA/Ware accepted" '^true$' "$chk" "{ $L = { country = \"US\"; region = \"MA\"; locality = \"Ware\"; }; }"
want "location env carried" '"CENSUS_LOC_COUNTRY":"US","CENSUS_LOC_LOCALITY":"Ware","CENSUS_LOC_REGION":"MA"' "$env" "{ $L = { country = \"US\"; region = \"MA\"; locality = \"Ware\"; }; }"
want "NEG country 'us' rejected"  'not an ISO 3166-1 alpha-2' "$chk" "{ $L = { country = \"us\"; }; }"
want "NEG country 'XX' rejected"  'not an ISO 3166-1 alpha-2' "$chk" "{ $L = { country = \"XX\"; }; }"
want "NEG region 'US-MA' rejected" 'ISO 3166-2 subdivision' "$chk" "{ $L = { country = \"US\"; region = \"US-MA\"; }; }"
want "NEG locality 65 chars rejected" 'locality must be' "$chk" "{ $L = { country = \"US\"; locality = \"$(printf 'a%.0s' $(seq 65))\"; }; }"
want "NEG locality with a quote rejected" 'locality must be' "$chk" "{ $L = { country = \"US\"; locality = \"a\\\\\\\"b\"; }; }"
want "builder: project with cpu-cap, newtask" 'solnix-builder:4242:.*project.cpu-cap=\(privileged,400,deny\)' 'c.environment.generatedEtc.project' '{ solnix.privacy.enable = false; }'
want "builder: started in its project" 'newtask -p solnix-builder' 'c.smf.services.solnix-builder.start.exec' '{ solnix.privacy.enable = false; }'
want "builder: no bearer in the generated config" '^false$' 'builtins.any (v: builtins.match ".*bearer.*" v != null) (builtins.attrValues c.smf.services.solnix-builder.environment)' '{ solnix.privacy.enable = false; }'
want "cache.build.enable = false: no builder, no /etc/project" '^false$' '(c.smf.services ? solnix-builder) || (c.environment.generatedEtc ? project)' '{ solnix.privacy.enable = false; solnix.cache.build.enable = false; }'
motd='c.environment.generatedEtc.motd'
want "MOTD asks when private" 'solnix.privacy.enable = false;   # opt into' "$motd" '{ }'
want "MOTD silent once opted in" '^"solnix [^"]*docs: *https://solnix.io\\n\\n"$' "$motd" '{ solnix.privacy.enable = false; }'
exit $bad
