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
want "opted in: cache.solnix.io still a substituter" '"https://cache.solnix.io[?"]' 'c.nix.settings.substituters' '{ solnix.privacy.enable = false; }'
want "opted in: proxy bound to 127.0.0.1, tcp (v4)" "bind_addr' type='astring' value='127.0.0.1'.*proto' type='astring' value='tcp'|proto' type='astring' value='tcp'.*bind_addr' type='astring' value='127.0.0.1'" 'c.smf.services.solnix-cache-proxy.extraManifestXML' '{ solnix.privacy.enable = false; }'
want "opted in: services(5) has the port" 'solnix-cache-proxy\\t37515/tcp' 'c.environment.generatedEtc."inet/services"' '{ solnix.privacy.enable = false; }'
# nix applies nix.conf top to bottom: a plain substituters line AFTER extra-substituters drops the proxy (dixi, 2026-10-29).
want "opted in: nix.conf puts extra-substituters after substituters" '^true$' 'let t = c.nix.generatedEtc."nix/nix.conf"; l = builtins.filter builtins.isString (builtins.split "\n" t); i = k: builtins.length (builtins.filter (x: x) (builtins.genList (n: true) 0)) + (let f = builtins.filter (x: builtins.match "${k} = .*" (builtins.elemAt l x) != null) (builtins.genList (n: n) (builtins.length l)); in builtins.head f); in i "substituters" < i "extra-substituters"' '{ solnix.privacy.enable = false; }'
want "opted in: cache.solnix.io ranked behind the proxy (?priority=50)" 'cache.solnix.io[?]priority=50"' 'c.nix.settings.substituters' '{ solnix.privacy.enable = false; }'
want "default: cache.solnix.io without a priority suffix" '^\["https://cache.solnix.io","https://cache.nixos.org"\]$' 'c.nix.settings.substituters' '{ }'
want "default: no proxy substituter" '^null$' 'c.nix.settings.extra-substituters or null' '{ }'
want "seed.enable = false: no proxy" '^false$' 'c.smf.services ? solnix-cache-proxy' '{ solnix.privacy.enable = false; solnix.cache.seed.enable = false; }'
want "opted in: endpoint is telemetry.solnix.io/api/v1/census" '"CENSUS_ENDPOINT":"https://telemetry.solnix.io/api/v1/census"' "$env" '{ solnix.privacy.enable = false; }'
want "opted in: flags = installed services (building: the builder is installed; no seeder yet)" '"CENSUS_builder":"false","CENSUS_building":"true".*"CENSUS_seeding":"false"' "$env" '{ solnix.privacy.enable = false; }'
want "no location unless set (list)" '^\[\]$' "builtins.filter (n: builtins.match \"CENSUS_LOC.*\" n != null) (builtins.attrNames $env)" '{ solnix.privacy.enable = false; }'
# cve1: CVE advisories. Off by default: no flag env, no command; on (with the census): the flag, the command, a 0711 state dir
advc='builtins.any (p: builtins.match ".*solnix-advisories.*" (p.name or "") != null) c.environment.systemPackages'
want "advisories default: no flag env, no command" '^\[\[\],false\]$' "[ (builtins.filter (n: builtins.match \"CENSUS_(advisories|ADVISORIES)\" n != null) (builtins.attrNames $env)) ($advc) ]" '{ solnix.privacy.enable = false; }'
want "advisories on: CENSUS_advisories=true + the command, in PATH" '^\["true",true,true\]$' "[ $env.CENSUS_advisories (builtins.match \"/nix/store/.*-solnix-advisories/bin/solnix-advisories\" $env.CENSUS_ADVISORIES != null) ($advc) ]" '{ solnix.privacy.enable = false; solnix.telemetry.census.advisories = true; }'
want "advisories on: state dir 0711" '^true$' 'builtins.match ".*chmod 0711 /var/lib/solnix/census" c.smf.services.solnix-census-setup.start.exec != null' '{ solnix.privacy.enable = false; solnix.telemetry.census.advisories = true; }'
want "advisories off: state dir stays 0700" '^true$' 'builtins.match ".*chmod 0700 /var/lib/solnix/census" c.smf.services.solnix-census-setup.start.exec != null' '{ solnix.privacy.enable = false; }'
want "NEG advisories set but private: no census, no command" '^\[false,false\]$' "[ (c.smf.services ? solnix-census) ($advc) ]" '{ solnix.telemetry.census.advisories = true; }'
want "NEG advisories set, census off: no command" '^false$' "$advc" '{ solnix.privacy.enable = false; solnix.telemetry.census.enable = false; solnix.telemetry.census.advisories = true; }'
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
# qbuild4: profiles. idle (default) = as before; dedicated = every idle CPU, no cap, short busy ticks; explicit settings win
be='builtins.removeAttrs c.smf.services.solnix-builder.environment [ "BUILDER_PATH" "CURL_CA_BUNDLE" "BUILDER_AGENT" "BUILDER_STATE" "BUILDER_SYSTEM" "BUILDER_WSWEEP" ]'
want "builder idle profile: 1 job, loadMax 2, 600-1800 s" '^\{"BUILDER_BUSY_TICK_MAX":"1800","BUILDER_BUSY_TICK_MIN":"600","BUILDER_CAP_SHARE":"","BUILDER_CORES":"0","BUILDER_JOBS":"1","BUILDER_LOAD_MAX":"2","BUILDER_NICE":"19","BUILDER_SHARE":"100","BUILDER_TICK_MAX":"1800","BUILDER_TICK_MIN":"600"\}$' "$be" '{ solnix.privacy.enable = false; }'
want "builder dedicated: auto jobs of 4 cores, loadMax auto, back to back (busy ticks 10-30 s, idle 120-300 s), share 100" '^\{"BUILDER_BUSY_TICK_MAX":"30","BUILDER_BUSY_TICK_MIN":"10","BUILDER_CAP_SHARE":"","BUILDER_CORES":"4","BUILDER_JOBS":"auto","BUILDER_LOAD_MAX":"auto","BUILDER_NICE":"19","BUILDER_SHARE":"100","BUILDER_TICK_MAX":"300","BUILDER_TICK_MIN":"120"\}$' "$be" '{ solnix.privacy.enable = false; solnix.cache.build.profile = "dedicated"; }'
want "builder opportunistic: auto jobs of 2 cores, 66% of the idle CPUs, a 66% cap set at start, busy ticks 120-600 s" '^\{"BUILDER_BUSY_TICK_MAX":"600","BUILDER_BUSY_TICK_MIN":"120","BUILDER_CAP_SHARE":"66","BUILDER_CORES":"2","BUILDER_JOBS":"auto","BUILDER_LOAD_MAX":"auto","BUILDER_NICE":"19","BUILDER_SHARE":"66",' "$be" '{ solnix.privacy.enable = false; solnix.cache.build.profile = "opportunistic"; }'
want "builder opportunistic: no fixed cap in /etc/project (the script sets it from the CPU count)" 'solnix-builder:4242:solnix idle queue builder::root:\\n' 'c.environment.generatedEtc.project' '{ solnix.privacy.enable = false; solnix.cache.build.profile = "opportunistic"; }'
want "builder dedicated: no cpu-cap in /etc/project" 'solnix-builder:4242:solnix idle queue builder::root:\\n' 'c.environment.generatedEtc.project' '{ solnix.privacy.enable = false; solnix.cache.build.profile = "dedicated"; }'
want "builder parallelJobs 4 x 3 cores: cap 1200, jobs 4, cores 3" 'cpu-cap=\(privileged,1200,deny\).*"BUILDER_CORES":"3","BUILDER_JOBS":"4"' '[ c.environment.generatedEtc.project c.smf.services.solnix-builder.environment ]' '{ solnix.privacy.enable = false; solnix.cache.build = { parallelJobs = 4; coresPerJob = 3; }; }'
want "NEG builder tickMin > tickMax rejected" 'tickMin/busyTickMin must not exceed' "$chk" '{ solnix.privacy.enable = false; solnix.cache.build.tickMin = 900; solnix.cache.build.tickMax = 600; }'
want "builder: started in its project" 'newtask -p solnix-builder' 'c.smf.services.solnix-builder.start.exec' '{ solnix.privacy.enable = false; }'
want "builder: no bearer in the generated config" '^false$' 'builtins.any (v: builtins.match ".*bearer.*" v != null) (builtins.attrValues c.smf.services.solnix-builder.environment)' '{ solnix.privacy.enable = false; }'
want "cache.build.enable = false: no builder, no /etc/project" '^false$' '(c.smf.services ? solnix-builder) || (c.environment.generatedEtc ? project)' '{ solnix.privacy.enable = false; solnix.cache.build.enable = false; }'
want "seed: no torrent package (default) -> no seeder, no hook, HTTP-only proxy" '^false$' '(c.smf.services ? solnix-seed) || (c.nix.settings ? post-build-hook) || (builtins.match ".*PROXY_TORRENT_FETCH.*" c.smf.services.solnix-cache-proxy.extraManifestXML != null)' '{ solnix.privacy.enable = false; }'
T='solnix.privacy.enable = false; solnix.cache.seed.torrentPackage = (derivation { name = "fake-torrent"; system = "x86_64-solaris"; builder = "/bin/sh"; })'
want "seed: with a torrent package -> seeder + post-build-hook + proxy fetcher" '^true$' '(c.smf.services ? solnix-seed) && (c.nix.settings ? post-build-hook) && (builtins.match ".*PROXY_TORRENT_FETCH.*solnix-torrent-fetch.*" c.smf.services.solnix-cache-proxy.extraManifestXML != null)' "{ $T; }"
want "seed: census flag seeding=true only then" '"CENSUS_seeding":"true"' "$env" "{ $T; }"
want "seed: seeder + swarm probe run as nobody (not root)" '^\["nobody","nobody"\]$' '[ c.smf.services.solnix-seed.user c.smf.services.solnix-swarm-probe.user ]' "{ $T; }"
want "seed: proxy gates the torrent path on the swarm probe" '^true$' '(c.smf.services ? solnix-swarm-probe) && builtins.match ".*/swarm.*" c.smf.services.solnix-seed-setup.start.exec != null' "{ $T; }"
want "seed.enable = false: no seeder even with the package" '^false$' '(c.smf.services ? solnix-seed) || (c.smf.services ? solnix-swarm-probe) || (c.nix.settings ? post-build-hook)' "{ $T; solnix.cache.seed.enable = false; }"
R='{ pkgs, ... }: { solnix.privacy.enable = false; solnix.cache.seed.torrentPackage = pkgs.solnix.solnix-torrent; }'
want "seed: the real package (pkgs.solnix.solnix-torrent) wires the proxy fetcher" '^"solnix-torrent-1 true"$' 'c.solnix.cache.seed.torrentPackage.name + " " + builtins.toJSON (builtins.match ".*solnix-torrent-fetch.*" c.smf.services.solnix-cache-proxy.extraManifestXML != null)' "$R"

motd='c.environment.generatedEtc.motd'
want "MOTD asks when private" 'solnix.privacy.enable = false;   # opt into' "$motd" '{ }'
want "MOTD silent once opted in" '^"solnix [^"]*docs: *https://solnix.io\\n\\n"$' "$motd" '{ solnix.privacy.enable = false; }'
exit $bad
