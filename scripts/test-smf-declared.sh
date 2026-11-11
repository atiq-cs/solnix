#!/bin/sh
# test-smf-declared.sh -- modules/system/activation/smf-declared.sh puts a declared service back as its toplevel declares
# it, and leaves an undeclared one alone. Runs ON illumos, as any user: every svccfg call goes to a PRIVATE repository
# (a copy of the seed, SVCCFG_REPOSITORY), never the live one.
#
#   sh scripts/test-smf-declared.sh    # exit 0 iff every check passes AND every mutant fails the check it targets
#   TEST_SMF_LIVE=1 pfexec sh scripts/test-smf-declared.sh   # also on the running SMF, with scratch services (L1-L4)
#
# Fixture: site/desk3-declared (declared on) and site/desk3-undeclared, imported from scratch manifests, then the state
# a running system leaves behind: both disabled the way `svcadm disable` writes it (general/enabled = false), the
# declared one's start/environment changed with setenv, and a site profile applied once under manifest-import's hash
# check. Checks:
#   C1 declared: general/enabled is true again                  (mutant M2: no setprop of general/enabled)
#   C2 declared: start/environment is the manifest's again,
#      in the editing view and in the running snapshot          (mutant M1: no revert, i.e. no delcust analog)
#   C3 undeclared: still disabled, its setenv kept              (negative control)
#   C4 the site profile: skipped by a hash-checked apply before, applied after its hash is forgotten (mutant M3)
set -u
here=$(cd "$(dirname "$0")" && pwd)
SD=${SMF_DECLARED_SH:-$here/../modules/system/activation/smf-declared.sh}
[ "$(uname -s)" = SunOS ] || { echo "SKIP: needs illumos SMF (svccfg, svc.configd)"; exit 0; }
SVCCFG=${SVCCFG:-/usr/sbin/svccfg}
SVCCFG_CONFIGD_PATH=${SVCCFG_CONFIGD_PATH:-/lib/svc/bin/svc.configd}
SEED=${SMF_SEED:-/lib/svc/seed/global.db}
for f in "$SVCCFG" "$SVCCFG_CONFIGD_PATH" "$SEED" "$SD"; do [ -e "$f" ] || { echo "FAIL: missing $f"; exit 1; }; done
export SVCCFG SVCCFG_CONFIGD_PATH
T=$(mktemp -d /tmp/test-smf-declared.XXXXXX) || exit 1
trap 'rm -rf "$T"' EXIT
bad=0

manifest() {   # $1 = service name, $2 = FOO value
  cat <<EOF
<?xml version="1.0"?>
<!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
<service_bundle type="manifest" name="$1">
  <service name="site/$1" type="service" version="1">
    <create_default_instance enabled="true"/>
    <single_instance/>
    <exec_method type="method" name="start" exec=":true" timeout_seconds="10">
      <method_context><method_environment><envvar name="FOO" value="$2"/></method_environment></method_context>
    </exec_method>
    <exec_method type="method" name="stop" exec=":true" timeout_seconds="10"/>
    <property_group name="startd" type="framework"><propval name="duration" type="astring" value="transient"/></property_group>
  </service>
</service_bundle>
EOF
}
mkdir -p "$T/etc/svc/profile/site"
manifest desk3-declared declared > "$T/declared.xml"; manifest desk3-undeclared declared > "$T/undeclared.xml"
cat > "$T/etc/svc/profile/site/solnix.xml" <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
<service_bundle type="profile" name="solnix">
  <service name="site/desk3-undeclared" version="1" type="service"><instance name="default" enabled="false"/></service>
</service_bundle>
EOF
PROF=$T/etc/svc/profile/site/solnix.xml
echo "svc:/site/desk3-declared:default true" > "$T/list"

# a repository holding the fixture; $1 = its path
setup() {
  cp "$SEED" "$1" && chmod 0600 "$1" || return 1
  export SVCCFG_REPOSITORY="$1"
  "$SVCCFG" import "$T/declared.xml" && "$SVCCFG" import "$T/undeclared.xml" || return 1
  for s in desk3-declared desk3-undeclared; do
    "$SVCCFG" -s site/$s:default setprop general/enabled = boolean: false || return 1
  done
  "$SVCCFG" -s site/desk3-declared setenv FOO admin && "$SVCCFG" -s site/desk3-undeclared setenv FOO admin || return 1
  printf 'select site/desk3-declared:default\nrefresh\n' | "$SVCCFG" || return 1
  # manifest-import's first apply of the site profile: it stores the profile's hash. Then an admin re-enables the
  # undeclared service (stock services' state is the admin's, apart from what the profile says).
  SVCCFG_CHECKHASH=1 "$SVCCFG" apply "$PROF" || return 1
  "$SVCCFG" -s site/desk3-undeclared:default setprop general/enabled = boolean: true
}
en()  { "$SVCCFG" -s "site/$1:default" listprop general/enabled 2>/dev/null | awk '{print $3}'; }
env_of() {   # $1 service, $2 snapshot or ""
  if [ -n "${2:-}" ]; then printf 'select site/%s:default\nselectsnap %s\nunselect\nlistprop start/environment\n' "$1" "$2"
  else printf 'select site/%s\nlistprop start/environment\n' "$1"; fi | "$SVCCFG" 2>/dev/null | awk '{print $3}'
}
check() {   # $1 = repo, $2 = label; prints failed check ids
  export SVCCFG_REPOSITORY="$1"; f=""
  [ "$(en desk3-declared)" = true ] || f="$f C1"
  [ "$(env_of desk3-declared)" = FOO=declared ] && [ "$(env_of desk3-declared running)" = FOO=declared ] || f="$f C2"
  [ "$(en desk3-undeclared)" = true ] && [ "$(env_of desk3-undeclared)" = FOO=admin ] || f="$f C3"
  # C4: a hash-checked apply (what manifest-import does) must now apply the profile again
  SVCCFG_CHECKHASH=1 "$SVCCFG" apply "$PROF" >/dev/null 2>&1
  [ "$(en desk3-undeclared)" = false ] || f="$f C4"
  echo "$f"
}

# the fixture really is the bug: before the fix, a hash-checked apply does NOT re-apply the profile
setup "$T/r0.db" || { echo "FAIL: fixture setup"; exit 1; }
SVCCFG_CHECKHASH=1 "$SVCCFG" apply "$PROF" >/dev/null 2>&1
[ "$(en desk3-undeclared)" = true ] && [ "$(en desk3-declared)" = false ] && [ "$(env_of desk3-declared)" = FOO=admin ] \
  || { echo "BAD: the fixture does not reproduce the bug (profile re-applied, or state not kept)"; bad=1; }

# the fix
setup "$T/r1.db" || { echo "FAIL: fixture setup"; exit 1; }
out=$(sh "$SD" "$T/list" "$PROF" 2>&1); echo "$out" | sed 's/^/  | /'
echo "$out" | grep 'desk3-declared:default: drop start/environment' >/dev/null || { echo "FAIL: no log of the dropped property"; bad=1; }
echo "$out" | grep 'desk3-undeclared' >/dev/null && { echo "FAIL: touched the undeclared service"; bad=1; }
r=$(check "$T/r1.db"); [ -z "$r" ] && echo "PASS: C1-C4 with the fix" || { echo "FAIL:$r with the fix"; bad=1; }

# mutants: each must fail the check it targets
mut() {   # $1 = id, $2 = check it must fail, $3 = sed expression
  sed "$3" "$SD" > "$T/$1.sh" && [ "$(wc -l < "$T/$1.sh")" = "$(wc -l < "$SD")" ] || { echo "BAD: mutant $1 not made"; bad=1; return; }
  cmp -s "$SD" "$T/$1.sh" && { echo "BAD: mutant $1 is identical"; bad=1; return; }
  setup "$T/$1.db" || { echo "FAIL: fixture setup ($1)"; bad=1; return; }
  sh "$T/$1.sh" "$T/list" "$PROF" >/dev/null 2>&1
  r=$(check "$T/$1.db")
  case " $r " in *" $2 "*) echo "PASS: mutant $1 fails $2 ($r)" ;; *) echo "BAD: mutant $1 passes $2 ($r)"; bad=1 ;; esac
}
mut M1 C2 's/rev="revert last-import"/rev="listpg"/'
mut M2 C1 's/echo "setprop general\/enabled = boolean: $want"; //'
mut M3 C4 's|listpg "$pg" 2>|listpg "x$pg" 2>|'

# LIVE (opt-in, root): the same against the running svc.configd/svc.startd, with scratch services that are deleted after.
# It also checks what a private repository cannot: svc.startd starts the declared service again, and `svcadm disable -t`
# (the non-persistent general_ovr) outlives the revert, as a systemctl --runtime change does.
if [ -n "${TEST_SMF_LIVE:-}" ]; then
  unset SVCCFG_REPOSITORY SVCCFG_CONFIGD_PATH
  D=svc:/site/desk3-declared:default; U=svc:/site/desk3-undeclared:default
  for f in $D $U; do svcs -H "$f" >/dev/null 2>&1 && { echo "FAIL: $f exists on this system; not touching it"; exit 1; }; done
  trap 'for f in $D $U; do svcadm disable -s "$f" 2>/dev/null; svccfg delete -f "${f%:*}" 2>/dev/null; done; rm -rf "$T"' EXIT
  wait_state() { i=0; while [ "$(svcs -H -o state "$1" 2>/dev/null)" != "$2" ] && [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done
    [ "$(svcs -H -o state "$1" 2>/dev/null)" = "$2" ]; }
  svccfg import "$T/declared.xml" && svccfg import "$T/undeclared.xml" || { echo "FAIL: live import"; exit 1; }
  svcadm disable -s $D $U; svccfg -s site/desk3-declared setenv FOO admin; svccfg -s site/desk3-undeclared setenv FOO admin
  svcadm refresh $D $U
  sh "$SD" "$T/list" | sed 's/^/  | /'
  wait_state $D online && [ "$(svcprop -p start/environment $D)" = FOO=declared ] \
    && echo "PASS: live L1 declared service online again, with the manifest's environment" \
    || { echo "FAIL: live L1 ($(svcs -H -o state $D), $(svcprop -p start/environment $D))"; bad=1; }
  wait_state $U disabled && [ "$(svcprop -p start/environment $U)" = FOO=admin ] \
    && echo "PASS: live L2 undeclared service still disabled, its environment kept" || { echo "FAIL: live L2"; bad=1; }
  # an online declared service with a drifted property: reverted in place, not stopped or restarted
  # (a refresh moves stime on illumos; count start/stop method runs in the service's log instead)
  svccfg -s site/desk3-declared setenv FOO admin2; svcadm refresh $D; sleep 1
  lg=$(svcs -L $D); n0=$(grep -c -E 'Executing (start|stop) method' "$lg")
  sh "$SD" "$T/list" >/dev/null 2>&1; sleep 2
  n1=$(grep -c -E 'Executing (start|stop) method' "$lg")
  [ "$(svcs -H -o state $D)" = online ] && [ "$n1" = "$n0" ] && [ "$(svcprop -p start/environment $D)" = FOO=declared ] \
    && echo "PASS: live L4 online service reverted in place (no stop/start method ran)" \
    || { echo "FAIL: live L4 ($(svcs -H -o state $D), methods $n0 -> $n1, $(svcprop -p start/environment $D))"; bad=1; }
  svcadm disable -t -s $D; sh "$SD" "$T/list" >/dev/null 2>&1; sleep 2
  [ "$(svcs -H -o state $D)" = disabled ] && [ "$(svcprop -p general_ovr/enabled $D 2>/dev/null)" = false ] \
    && [ "$(svcprop -p general/enabled $D)" = true ] \
    && echo "PASS: live L3 svcadm disable -t outlives the revert (general_ovr kept, general/enabled true)" \
    || { echo "FAIL: live L3 ($(svcs -H -o state $D))"; bad=1; }
fi

[ "$bad" = 0 ] && echo "ALL PASS" || echo "FAILED"
exit $bad
