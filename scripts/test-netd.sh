#!/bin/sh
# test-netd.sh -- solnix-netd (modules/config/solnix-netd.sh) against a fake ipadm on PATH:
#  (a) leased(): "dhcp:ok:?" (the addrobj before dhcpagent binds; ipadm prints "?" for 0.0.0.0) is no lease,
#      "dhcp:ok:<address>" is one, "disabled" and static are not. NEG: OLD_REV's leased() (type,state = dhcp:ok) takes
#      ok/? for a lease (lixi: "route add default ... Network is unreachable" 15-37 times a boot, to 2026-11-11).
#
#   sh scripts/test-netd.sh [repo]   # the daemon from the tree and OLD_REV (git)
#   NETD_FILES=dir sh scripts/test-netd.sh   # dir holds new.sh old.sh (an illumos host: NETD_SH=/sbin/sh)
#   NETD_SAVE=dir sh scripts/test-netd.sh    # also copies those files to dir
# Exits 0 on pass, 1 on any FAIL.
set -u
F=${1:-$(cd "$(dirname "$0")/.." && pwd)}
OLD_REV=${NETD_OLD_REV:-ccf0b2d758b448d0806fa24260093d45dde095b2}	# main before the lease-address fix
SH=${NETD_SH:-sh}
T=$(mktemp -d); trap 'find "$T" -depth -type f -exec rm -f {} + ; find "$T" -depth -type d -exec rmdir {} +' EXIT
bad=0
ok() { echo "ok: $1"; }
no() { echo "FAIL: $1"; [ -s "$T/log" ] && sed 's/^/    | /' "$T/log"; bad=1; }

if [ -n "${NETD_FILES:-}" ]; then for f in new.sh old.sh; do cp "$NETD_FILES/$f" "$T/$f" || exit 1; done
else
  cp "$F/modules/config/solnix-netd.sh" "$T/new.sh" && git -C "$F" show "$OLD_REV:modules/config/solnix-netd.sh" > "$T/old.sh" || exit 1
fi
[ -n "${NETD_SAVE:-}" ] && cp "$T/new.sh" "$T/old.sh" "$NETD_SAVE/"

# fakes. $NB/addrs: "addrobj:type:state:addr" lines
mkdir -p "$T/bin"
cat > "$T/bin/ipadm" <<'E'
#!/bin/sh
case "$*" in
"show-addr -p -o type,state,addr "*/) grep "^${5%/}/" "$NB/addrs" | cut -d: -f2- ;;
"show-addr -p -o type,state "*/) grep "^${5%/}/" "$NB/addrs" | cut -d: -f2,3 ;;	# OLD_REV's leased()
*) echo "fake ipadm: $*" >&2; exit 1 ;;
esac
E
chmod +x "$T/bin"/*
st() { NB=$T/st$1; mkdir -p "$NB"; : > "$NB/addrs"; }

# (a) leased(), as it is in the daemon
for v in new old; do
  sed -n '/^leased() /p' "$T/$v.sh" > "$T/$v.fn"
  [ "$(grep -c '^leased() ' "$T/$v.fn")" = 1 ] || { echo "FAIL: no one leased() in $v"; exit 1; }
done
lease() { # lease <new|old> <iwx0's addrobj line>
  st a; echo "$2" > "$NB/addrs"; NB=$NB PATH="$T/bin:$PATH" $SH -c ". '$T/$1.fn'; leased iwx0" ; }
lease new 'iwx0/dhcp:dhcp:ok:?' && no "(a) ok/? is a lease" || ok "(a) dhcp ok with ADDR ? is not a lease"
lease new 'iwx0/dhcp:dhcp:ok:192.168.1.192/24' && ok "(a) dhcp ok with an address is a lease" || no "(a) a bound lease is not one"
lease new 'iwx0/dhcp:dhcp:disabled:?' && no "(a) disabled is a lease" || ok "(a) dhcp disabled is not a lease"
lease new 'iwx0/v4:static:ok:10.0.0.5/24' && no "(a) static is a lease" || ok "(a) a static address is not a lease"
lease old 'iwx0/dhcp:dhcp:ok:?' && ok "(a) NEG $OLD_REV's leased() takes ok/? for a lease" || no "(a) NEG the old leased() should take ok/?"
lease old 'iwx0/dhcp:dhcp:ok:192.168.1.192/24' && ok "(a) $OLD_REV's leased() takes a bound lease (sanity)" || no "(a) old leased() on a bound lease"

[ $bad = 0 ] && echo "RESULT PASS" || echo "RESULT FAIL"
exit $bad
