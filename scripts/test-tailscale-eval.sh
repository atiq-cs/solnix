#!/usr/bin/env bash
# test-tailscale-eval.sh -- services.tailscale (modules/config/tailscale.nix) at EVAL time, plus its autoconnect script
# run against a stub CLI (no illumos needed; run on floki):
#  - off by default; on: tailscaled (userspace networking, state/socket paths, port, deps), the CLI in systemPackages;
#  - authKeyFile adds tailscale-autoconnect with the login server and the up flags; disableUpstreamLogging sets the env;
#  - NEG: interfaceName != userspace-networking and a store-path key each fail the assertions; openFirewall opens UDP 41641;
#  - autoconnect: logs in on NeedsLogin, no-op when Running on the same control URL, and REFUSES a tskey- or empty key.
set -u
F=${1:-$(cd "$(dirname "$0")/.." && pwd)}; bad=0
ev() { nix eval --json --impure --expr "let f = builtins.getFlake \"git+file://$F\";
  c = (f.lib.solnixSystem { system = \"x86_64-solaris\"; pkgs = f.lib.mkPkgs { };
    modules = [ $F/configurations/base.nix ($2) ]; }).config; in $1" 2>&1; }
want() { # want <name> <expect-regex> <expr> <module>
  out=$(ev "$3" "$4" | tail -1)
  if echo "$out" | grep -qE "$2"; then echo "ok: $1"; else echo "FAIL: $1: got: $out"; bad=1; fi; }
svcs='builtins.filter (n: builtins.match "tailscale.*" n != null) (builtins.attrNames c.smf.services)'
d='c.smf.services.tailscaled'; chk='c.system.assertionsChecked'
on='services.tailscale.enable = true'
K='authKeyFile = "/var/lib/solnix/tailscale-authkey"; extraUpFlags = [ "--login-server=https://headscale.burd.me" "--accept-routes" ]'
want "default: no tailscale services" '^\[\]$' "$svcs" '{ }'
want "enabled: tailscaled only (no key, no set flags)" '^\["tailscaled"\]$' "$svcs" "{ $on; }"
want "tailscaled: userspace networking, state, socket, port 41641, backgrounded" \
  "/bin/tailscaled '--tun=userspace-networking' '--state=/var/lib/tailscale/tailscaled.state' '--socket=/var/run/tailscale/tailscaled.sock' '--port=41641' &\"$" "$d.start.exec" "{ $on; }"
want "tailscaled: socket dir 0700 root (LocalAPI dial serves any uid; illumos builds are unsandboxed)" \
  '^"mkdir -p -m 0700 /var/lib/tailscale && mkdir -p -m 0700 /var/run/tailscale && chmod 0700 /var/run/tailscale \|\| exit 1' "$d.start.exec" "{ $on; }"
want "tailscaled: contract, needs network + name-services" '^"contract svc:/milestone/network:default svc:/milestone/name-services:default' \
  "$d.model + \" \" + builtins.concatStringsSep \" \" $d.requires" "{ $on; }"
want "CLI in systemPackages" '^true$' 'builtins.elem c.services.tailscale.package c.environment.systemPackages' "{ $on; }"
want "upstream logging on by default (as NixOS)" '^\{\}$' "$d.environment" "{ $on; }"
want "disableUpstreamLogging: TS_NO_LOGS_NO_SUPPORT" '^\{"TS_NO_LOGS_NO_SUPPORT":"true"\}$' "$d.environment" "{ $on; services.tailscale.disableUpstreamLogging = true; }"
want "authKeyFile: autoconnect after tailscaled, login server from extraUpFlags" \
  '"TS_AUTHKEY_FILE":"/var/lib/solnix/tailscale-authkey".*"TS_LOGIN_SERVER":"https://headscale.burd.me"\},"requires":\["svc:/site/tailscaled:default"\]' \
  'let a = c.smf.services.tailscale-autoconnect; in { inherit (a) requires; e = a.environment; }' "{ $on; services.tailscale = { $K; }; }"
want "authKeyFile: up flags passed, key never on the command line" "tailscale-autoconnect.sh '--login-server=https://headscale.burd.me' --accept-routes\"$" \
  'c.smf.services.tailscale-autoconnect.start.exec' "{ $on; services.tailscale = { $K; }; }"
want "extraSetFlags: tailscale-set after autoconnect" '^\["svc:/site/tailscaled:default","svc:/site/tailscale-autoconnect:default"\]$' \
  'c.smf.services.tailscale-set.requires' "{ $on; services.tailscale = { $K; extraSetFlags = [ \"--advertise-routes=10.0.0.1/32\" ]; }; }"
want "assertions pass when enabled" '^true$' "$chk" "{ $on; services.tailscale = { $K; }; }"
want "NEG interfaceName tailscale0 rejected" 'no tailscale TUN device' "$chk" "{ $on; services.tailscale.interfaceName = \"tailscale0\"; }"
want "openFirewall: UDP 41641 in solnix.firewall.allowedUDPPorts" '^\[41641\]$' 'c.solnix.firewall.allowedUDPPorts' "{ $on; services.tailscale.openFirewall = true; }"
want "openFirewall off (default): no UDP port opened" '^\[\]$' 'c.solnix.firewall.allowedUDPPorts' "{ $on; }"
want "NEG authKeyFile in the store rejected" 'is in the Nix store' "$chk" "{ $on; services.tailscale.authKeyFile = builtins.toFile \"k\" \"x\"; }"

# the autoconnect script, on a stub tailscale CLI (STUB_STATE, STUB_CTRL; `up` records its argv in $T/up)
T=$(mktemp -d); trap 'find "$T" -depth -delete' EXIT
printf '%s\n' '#!/usr/bin/env bash' 'case $1 in status) echo "{\"BackendState\":\"$STUB_STATE\"}";;' \
  'debug) echo "{\"ControlURL\":\"$STUB_CTRL\"}";; up) shift; echo "$*" > "$STUB_DIR/up";; esac' > "$T/ts"; chmod +x "$T/ts"
ac() { # ac <name> <state> <ctrl> <key> <want rc> <want up: yes|no>
  rm -f "$T/up"; printf '%s' "$4" > "$T/key"
  TS_CLI=$T/ts TS_JQ=$(command -v jq) TS_AUTHKEY_FILE=$T/key TS_LOGIN_SERVER=https://hs.example STUB_DIR=$T STUB_STATE=$2 STUB_CTRL=$3 \
    bash "$F/modules/config/tailscale-autoconnect.sh" --login-server=https://hs.example >"$T/out" 2>&1; rc=$?
  [ -e "$T/up" ] && up=yes || up=no
  if [ "$rc" = "$5" ] && [ "$up" = "$6" ]; then echo "ok: autoconnect: $1"; else echo "FAIL: autoconnect: $1: rc=$rc up=$up: $(head -2 "$T/out")"; bad=1; fi; }
ac "NeedsLogin + hskey: logs in" NeedsLogin "" hskey-auth-x 0 yes
grep -q -- '--auth-key=file:'"$T/key"' --login-server=https://hs.example' "$T/up" && echo "ok: autoconnect: key passed as file:, flags kept" \
  || { echo "FAIL: autoconnect: up argv: $(cat "$T/up")"; bad=1; }
ac "Running on the same control URL: no-op" Running https://hs.example hskey-auth-x 0 no
ac "Running on another control URL: logs in" Running https://controlplane.tailscale.com hskey-auth-x 0 yes
ac "NEG tskey- key refused" NeedsLogin "" tskey-auth-x 1 no
ac "NEG empty key refused" NeedsLogin "" "" 1 no
exit $bad
