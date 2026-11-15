#!/usr/bin/env bash
# test-memguard.sh -- services.solnix-memguard (modules/config/solnix-memguard.{nix,sh}).
#  eval (floki; any host with nix): the opportunistic builder turns the guard on and requires it (require_all, restart_on
#    restart); idle/dedicated builders and a private host have no guard; the guard alone can be turned on; its environment
#    follows the options and nix's build-users-group. NEG: build-users-group "" is rejected.
#  run (an illumos host, MG_RUN=1, as an unprivileged user): `solnix-memguard list` against a fake passwd/group whose build
#    group holds the CALLER's own uid/gid (so the caller's processes are the "builds"): a child of this test is listed,
#    every listed pid is the build user's, init is not; a uid-0 user named <group>N and a user not named <group>N are no
#    build users (NEG: with only those, it exits 1 listing nothing); NEG: a non-numeric gid exits 1. No signals (list only).
#   bash scripts/test-memguard.sh [repo]          # eval checks
#   MG_RUN=1 sh scripts/test-memguard.sh [repo]   # the run checks only (illumos)
# Exits 0 on pass, 1 on any FAIL.
set -u
F=${1:-$(cd "$(dirname "$0")/.." && pwd)}; bad=0
ok() { echo "ok: $1"; }; no() { echo "FAIL: $1"; bad=1; }
if [ "${MG_RUN:-0}" = 1 ]; then
  S=$F/modules/config/solnix-memguard.sh
  T=$(mktemp -d); trap 'rm -f "$T"/passwd "$T"/group "$T"/out; rmdir "$T"' EXIT
  u=$(id -u); g=$(id -g); [ "$u" != 0 ] || { echo "FAIL: run as a non-root user"; exit 1; }
  sleep 30 & c=$!
  printf 'mgt1:x:%s:%s::/:/bin/false\nmgt2:x:0:%s::/:/bin/false\nother:x:%s:%s::/:/bin/false\n' "$u" "$g" "$g" "$u" "$g" > "$T/passwd"
  printf 'mgt::%s:\n' "$g" > "$T/group"
  MG_PASSWD=$T/passwd MG_GROUP_FILE=$T/group MG_GROUP=mgt /bin/sh "$S" list > "$T/out" 2>&1; rc=$?
  # every process of mine is a "build" here (my uid/gid): the child must be listed, and the list holds only my processes
  grep -qx "$c" "$T/out" && ok "list: the build-group child $c is listed (rc $rc)" || no "list: child $c missing: $(head -3 "$T/out")"
  # a listed pid that has exited since (the list's own short-lived ps children run as me) has no ruid: skipped
  n=$(grep -c . "$T/out"); m=0; for p in $(cat "$T/out"); do r=$(ps -o ruid= -p "$p" 2>/dev/null | tr -d ' '); [ -z "$r" ] || [ "$r" = "$u" ] || m=$((m+1)); done
  [ "$m" = 0 ] && ok "list: all $n listed pids are the build user's" || no "list: $m listed pids are not the build user's"
  grep -qx 1 "$T/out" && no "list: pid 1 listed" || ok "list: init is not listed"
  # NEG: a uid-0 mgt2 and a non-<group>N name (other, with my uid) are no build users
  printf 'mgt2:x:0:%s::/:/bin/false\nother:x:%s:%s::/:/bin/false\n' "$g" "$u" "$g" > "$T/passwd"
  MG_PASSWD=$T/passwd MG_GROUP_FILE=$T/group MG_GROUP=mgt /bin/sh "$S" list > "$T/out" 2>&1; rc=$?
  [ $rc = 1 ] && ! grep -qx "$c" "$T/out" && ok "NEG only a uid-0 mgt2 and 'other': exit 1, nothing listed" || no "NEG no build user: rc $rc, $(head -2 "$T/out")"
  printf 'mgt::abc:\n' > "$T/group"
  MG_PASSWD=$T/passwd MG_GROUP_FILE=$T/group MG_GROUP=mgt /bin/sh "$S" list > "$T/out" 2>&1; rc=$?
  [ $rc = 1 ] && grep -q FATAL "$T/out" && ok "NEG non-numeric gid: exit 1" || no "NEG gid abc: rc $rc"
  kill "$c" 2>/dev/null
  [ $bad = 0 ] && echo "PASS" || echo "FAILED"; exit $bad
fi
ev() { nix eval --json --impure --expr "let f = builtins.getFlake \"git+file://$F\";
  c = (f.lib.solnixSystem { system = \"x86_64-solaris\"; pkgs = f.lib.mkPkgs { };
    modules = [ $F/configurations/base.nix ($2) ]; }).config; in $1" 2>&1; }
want() { # want <name> <expect-regex> <expr> <module>
  out=$(ev "$3" "$4" | tail -1)
  if echo "$out" | grep -qE "$2"; then ok "$1"; else no "$1: got: $(echo "$out" | cut -c1-300)"; fi; }
O='solnix.privacy.enable = false; solnix.cache.build.profile = "opportunistic";'
dep='builtins.filter (d: d.name == "solnix-memguard") c.smf.services.solnix-builder.dependencies'
want "opportunistic builder: the guard is on" '^true$' 'c.smf.services ? solnix-memguard' "{ $O }"
want "opportunistic builder: it requires the guard (require_all, restart_on restart)" '^\[\{"fmris":\["svc:/site/solnix-memguard:default"\],"grouping":"require_all","name":"solnix-memguard","restartOn":"restart"\}\]$' "$dep" "{ $O }"
want "the guard's environment: 4 GiB floor and leak, 15 s, group nixbld" '^\{"FLOOR_KB":"4194304","LEAK_KB":"4194304","MG_GROUP":"nixbld","MG_INTERVAL":"15","PATH":"/usr/bin:/usr/sbin:/bin"\}$' 'c.smf.services.solnix-memguard.environment' "{ $O }"
want "the guard runs the store script, a contract daemon stopped with :kill" '^\["/bin/sh /nix/store/[a-z0-9]{32}-solnix-memguard.sh &",":kill","contract"\]$' 'with c.smf.services.solnix-memguard; [ start.exec stop.exec model ]' "{ $O }"
want "options: floorMiB 2048 leakMiB 8192 interval 5" '"FLOOR_KB":"2097152","LEAK_KB":"8388608",.*"MG_INTERVAL":"5"' 'c.smf.services.solnix-memguard.environment' "{ $O services.solnix-memguard = { floorMiB = 2048; leakMiB = 8192; interval = 5; }; }"
want "dedicated builder: no guard, no dependency" '^\[false,\[\]\]$' "[ (c.smf.services ? solnix-memguard) ($dep) ]" '{ solnix.privacy.enable = false; solnix.cache.build.profile = "dedicated"; }'
want "idle builder (default profile): no guard" '^false$' 'c.smf.services ? solnix-memguard' '{ solnix.privacy.enable = false; }'
want "private host: no builder, no guard" '^false$' 'c.smf.services ? solnix-memguard' '{ }'
want "opportunistic, guard turned off: the builder does not require it" '^\[false,\[\]\]$' "[ (c.smf.services ? solnix-memguard) ($dep) ]" "{ $O services.solnix-memguard.enable = false; }"
want "the guard alone (no builder): on, with nix's group" '"MG_GROUP":"nixbld"' 'c.smf.services.solnix-memguard.environment' '{ services.solnix-memguard.enable = true; }'
want "NEG build-users-group \"\" rejected" 'needs nix.settings.build-users-group' 'c.system.assertionsChecked' '{ services.solnix-memguard.enable = true; nix.settings.build-users-group = ""; }'
[ $bad = 0 ] && echo "PASS" || echo "FAILED"; exit $bad
