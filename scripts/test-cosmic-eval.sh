#!/usr/bin/env bash
# test-cosmic-eval.sh -- services.desktopManager.cosmic at EVAL time (run on floki): an enabled COSMIC config must SHIP
# the greeter's SMF services. smf.services entries without `enable = true` are dropped from the manifests
# (smf.nix enabledServices), which left lixi-cosmic with no greetd/seatd/dbus manifests (2026-10-29).
set -u
F=${1:-$(cd "$(dirname "$0")/.." && pwd)}; bad=0
ev() { nix eval --json --impure --expr "let f = builtins.getFlake \"git+file://$F\";
  c = (f.lib.solnixSystem { system = \"x86_64-solaris\"; pkgs = f.lib.mkPkgs { };
    modules = [ $F/configurations/base.nix ($2) ]; }).config; in $1" 2>&1 | tail -1; }
M='{ services.desktopManager.cosmic.enable = true; hardware.graphics.i915.attachAtBoot = true; }'
got=$(ev 'builtins.filter (n: builtins.elem n [ "dbus" "seatd" "cosmic-greeter-daemon" "greetd" ]) (builtins.attrNames (builtins.removeAttrs c.smf.services (builtins.filter (n: !c.smf.services.${n}.enable) (builtins.attrNames c.smf.services))))' "$M")
[ "$got" = '["cosmic-greeter-daemon","dbus","greetd","seatd"]' ] && echo "ok: cosmic ships dbus, seatd, cosmic-greeter-daemon, greetd" || { echo "FAIL: enabled cosmic services: $got"; bad=1; }
got=$(ev 'builtins.length (builtins.filter (n: builtins.elem n [ "dbus" "greetd" ]) (builtins.attrNames c.smf.services))' '{ }')
[ "$got" = 0 ] && echo "ok: default config has no dbus/greetd" || { echo "FAIL: default config: $got"; bad=1; }
[ $bad = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"; exit $bad
