#!/bin/sh
# test-netd.sh -- solnix-netd (modules/config/solnix-netd.{sh,nix}) against fake ipadm/netstat/ksh93/sleep on PATH:
#  (a) leased(): "dhcp:ok:?" (the addrobj before dhcpagent binds; ipadm prints "?" for 0.0.0.0) is no lease,
#      "dhcp:ok:<address>" is one, "disabled" and static are not. NEG: OLD_REV's leased() (type,state = dhcp:ok) takes
#      ok/? for a lease (lixi: "route add default ... Network is unreachable" 15-37 times a boot, to 2026-11-11);
#  (b) online(): NETD_ONLINE appears once there is a default route and an IPv4 address off lo0, not before, logged once;
#  (c) the start method returns when NETD_ONLINE appears (so svc:/site/solnix-netd goes online with the network, which
#      smf.networkOnline waits for), when the daemon dies, or after 60 s, and drops a marker left from before.
#      NEG: OLD_REV's method returns at once. The SMF side (svccfg services on dixi, 2026-11-12): net2 in
#      floki /scratch/solnix/net2/dixi-svc-test.log.
#
#   sh scripts/test-netd.sh [repo]   # floki: functions from the tree and OLD_REV (git), the start methods by nix eval
#   NETD_FILES=dir sh scripts/test-netd.sh   # dir holds new.sh old.sh new.m old.m (an illumos host: NETD_SH=/sbin/sh)
#   NETD_SAVE=dir sh scripts/test-netd.sh    # also copies those four files to dir
# Exits 0 on pass, 1 on any FAIL.
set -u
F=${1:-$(cd "$(dirname "$0")/.." && pwd)}
OLD_REV=${NETD_OLD_REV:-ccf0b2d758b448d0806fa24260093d45dde095b2}	# main before the lease-address fix and the online point
SH=${NETD_SH:-sh}
T=$(mktemp -d); trap 'find "$T" -depth -type f -exec rm -f {} + ; find "$T" -depth -type d -exec rmdir {} +' EXIT
bad=0
ok() { echo "ok: $1"; }
no() { echo "FAIL: $1"; [ -s "$T/log" ] && sed 's/^/    | /' "$T/log"; bad=1; }

if [ -n "${NETD_FILES:-}" ]; then for f in new.sh old.sh new.m old.m; do cp "$NETD_FILES/$f" "$T/$f" || exit 1; done
else
  cp "$F/modules/config/solnix-netd.sh" "$T/new.sh" && git -C "$F" show "$OLD_REV:modules/config/solnix-netd.sh" > "$T/old.sh" || exit 1
  m() { # m <flake ref> <out>: the start method's exec text, configurations/base.nix with solnix-netd on
    nix eval --raw --impure --expr "let f = builtins.getFlake \"$1\"; in (f.lib.solnixSystem { system = \"x86_64-solaris\";
      pkgs = f.lib.mkPkgs { }; modules = [ \"\${f}/configurations/base.nix\" { networking.solnix-netd.enable = true; } ];
      }).config.smf.services.solnix-netd.start.exec" > "$2" 2>"$T/eval.err" || { echo "FAIL: eval $1: $(tail -2 "$T/eval.err")"; exit 1; }
  }
  m "git+file://$F" "$T/new.m"; m "git+file://$F?rev=$OLD_REV" "$T/old.m"
fi
[ -n "${NETD_SAVE:-}" ] && cp "$T/new.sh" "$T/old.sh" "$T/new.m" "$T/old.m" "$NETD_SAVE/"

# fakes. $NB/addrs: "addrobj:type:state:addr" lines; $NB/routes: netstat -rn lines; $NB/clock counts sleeps.
mkdir -p "$T/bin"
cat > "$T/bin/ipadm" <<'E'
#!/bin/sh
case "$*" in
"show-addr -p -o type,state,addr "*/) grep "^${5%/}/" "$NB/addrs" | cut -d: -f2- ;;
"show-addr -p -o type,state "*/) grep "^${5%/}/" "$NB/addrs" | cut -d: -f2,3 ;;	# OLD_REV's leased()
"show-addr -p -o addrobj,state,addr") cut -d: -f1,3- "$NB/addrs" ;;
*) echo "fake ipadm: $*" >&2; exit 1 ;;
esac
E
printf '#!/bin/sh\ncat "$NB/routes"\n' > "$T/bin/netstat"
cat > "$T/bin/sleep" <<'E'
#!/bin/sh
c=$(($(cat "$NB/clock") + 1)); echo $c > "$NB/clock"
[ $c -ge "$ONLINE_AT" ] && : > "$NETD_ONLINE"	# the daemon got the network
exit 0
E
cat > "$T/bin/ksh93" <<'E'
#!/bin/sh
echo $$ > "$NB/dpid"; [ "$DIES" = 1 ] && exit 3
PATH=$RPATH exec sleep 120	# the daemon, alive until the test kills it
E
chmod +x "$T/bin"/*
st() { NB=$T/st$1; mkdir -p "$NB"; echo 0 > "$NB/clock"; : > "$NB/addrs"; : > "$NB/routes"; : > "$NB/log"; }

# (a) leased(), (b) online(): the functions as they are in the daemon, a plain log()
for v in new old; do
  { echo 'log() { echo "$*" >> "$NB/log"; }'; sed -n '/^leased() /p; /^online() {/,/^}/p' "$T/$v.sh"; } > "$T/$v.fn"
  [ "$(grep -c '^leased() ' "$T/$v.fn")" = 1 ] || { echo "FAIL: no one leased() in $v"; exit 1; }
done
lease() { # lease <new|old> <iwx0's addrobj line>
  st a; echo "$2" > "$NB/addrs"; NB=$NB PATH="$T/bin:$PATH" $SH -c ". '$T/$1.fn'; leased iwx0" ; }
lease new 'iwx0/dhcp:dhcp:ok:?' && no "(a) ok/? is a lease" || ok "(a) dhcp ok with ADDR ? is not a lease"
lease new 'iwx0/dhcp:dhcp:ok:192.0.2.10/24' && ok "(a) dhcp ok with an address is a lease" || no "(a) a bound lease is not one"
lease new 'iwx0/dhcp:dhcp:disabled:?' && no "(a) disabled is a lease" || ok "(a) dhcp disabled is not a lease"
lease new 'iwx0/v4:static:ok:10.0.0.5/24' && no "(a) static is a lease" || ok "(a) a static address is not a lease"
lease old 'iwx0/dhcp:dhcp:ok:?' && ok "(a) NEG $OLD_REV's leased() takes ok/? for a lease" || no "(a) NEG the old leased() should take ok/?"
lease old 'iwx0/dhcp:dhcp:ok:192.0.2.10/24' && ok "(a) $OLD_REV's leased() takes a bound lease (sanity)" || no "(a) old leased() on a bound lease"

st b; : > "$T/log"
cat > "$T/b.sh" <<E
. '$T/new.fn'
echo 'lo0/v4:static:ok:127.0.0.1/8' > "\$NB/addrs"; echo 'iwx0/dhcp:dhcp:ok:?' >> "\$NB/addrs"
online; [ -e "\$NETD_ONLINE" ] && echo "1: online with no route, no address"
echo 'default 192.0.2.1 UG 1 0 iwx0' > "\$NB/routes"
online; [ -e "\$NETD_ONLINE" ] && echo "2: online with a route and no address (ok/?)"
echo 'lo0/v4:static:ok:127.0.0.1/8' > "\$NB/addrs"; echo 'iwx0/dhcp:dhcp:ok:192.0.2.10/24' >> "\$NB/addrs"
: > "\$NB/routes"; online; [ -e "\$NETD_ONLINE" ] && echo "3: online with an address and no route"
echo 'default 192.0.2.1 UG 1 0 iwx0' > "\$NB/routes"
online; [ -e "\$NETD_ONLINE" ] || echo "4: not online with a route and an address"
online; online
E
NB=$NB NETD_ONLINE=$NB/online PATH="$T/bin:$PATH" $SH "$T/b.sh" > "$T/log" 2>&1
if ! [ -s "$T/log" ] && [ "$(grep -c '^online: ' "$NB/log")" = 1 ] &&
  grep -qx 'online: default via 192.0.2.1, iwx0/dhcp:ok:192.0.2.10/24' "$NB/log"
then ok "(b) online(): marker only with a default route and an address (not ok/?), logged once"
else cat "$NB/log" >> "$T/log"; no "(b) online()"; fi

# (c) the start method, its daemon a fake that stays (or dies), the marker written at sleep ONLINE_AT
for v in new old; do
  { echo "sleep() { $T/bin/sleep \"\$@\"; }"	# ksh93 (illumos /sbin/sh) has sleep built in, ahead of PATH
    sed "s|/usr/bin/ksh93|$T/bin/ksh93|g" "$T/$v.m"; } > "$T/$v.ms"
  grep -q "^$T/bin/ksh93 /nix/store/[a-z0-9]*-solnix-netd.sh &" "$T/$v.ms" || { echo "FAIL: $v method does not start the daemon"; exit 1; }
  if sed 1d "$T/$v.ms" | grep -v '^[ 	]*#' | sed 's|/dev/null||g; s|/nix/store/[^ ]*||g' | grep -vF "$T/bin/" | grep -nE '(^|[^A-Za-z0-9_.@])/(usr|sbin|bin|etc|lib|var|dev)/'
  then echo "FAIL: $v method has a host path the fakes do not cover (above)"; exit 1; fi
done
meth() { # meth <new|old> <ONLINE_AT> <DIES> [stale]: the method's output in $T/log, sleeps in $n, daemon alive in $alive
  st "c-$1-$2-$3"; [ -n "${4:-}" ] && : > "$NB/online"
  NB=$NB ONLINE_AT=$2 DIES=$3 RPATH=$PATH NETD_ONLINE=$NB/online PATH="$T/bin:$PATH" $SH "$T/$1.ms" > "$T/log" 2>&1
  n=$(cat "$NB/clock"); i=0
  while ! [ -s "$NB/dpid" ] && [ $i -lt 5 ]; do sleep 1; i=$((i + 1)); done	# the old method returns before its & child ran
  p=$(cat "$NB/dpid" 2>/dev/null); alive=no
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null && { alive=yes; kill "$p"; }
}
meth new 5 0
[ "$n" = 5 ] && [ $alive = yes ] && ! [ -s "$T/log" ] && ok "(c) returns when the daemon is online (5 s), the daemon running" || no "(c) online at 5 s (sleeps $n, daemon $alive)"
meth new 3 0 stale
[ "$n" = 3 ] && ok "(c) a marker left from before does not count (3 s)" || no "(c) stale marker (sleeps $n)"
meth new 999 0
[ "$n" = 60 ] && [ $alive = yes ] && grep -qx 'solnix-netd: not online after 60 s; the service goes online without it' "$T/log" &&
  ok "(c) never online: returns after 60 s, says so, the daemon running" || no "(c) never online (sleeps $n, daemon $alive)"
meth new 999 1
[ "$n" -lt 60 ] && grep -q 'solnix-netd: not online after' "$T/log" && ok "(c) the daemon dies: returns at once ($n s)" || no "(c) daemon died (sleeps $n)"
meth old 5 0
[ "$n" = 0 ] && [ $alive = yes ] && ok "(c) NEG $OLD_REV's method returns at once (online before the network)" || no "(c) NEG old method (sleeps $n, daemon $alive)"

[ $bad = 0 ] && echo "RESULT PASS" || echo "RESULT FAIL"
exit $bad
