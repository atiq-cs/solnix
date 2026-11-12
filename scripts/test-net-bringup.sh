#!/bin/sh
# test-net-bringup.sh -- the generated solnix-net start method (modules/config/networking.nix) run against fake
# ipadm/dladm/dhcpinfo/ifconfig/route/svcadm on PATH, with a fake clock (each `sleep` is one tick):
#  (a) the dhcp addrobj is "ok" with ADDR "?" (a reboot's persistent addrobj before dhcpagent binds) for 3 polls,
#      then has an address: the bringup waits for it, takes no ifconfig fallback, and writes resolv.conf;
#  (b) NEG: the method of the pre-fix rev (NET_OLD_REV) with the same fakes stops at the first poll and writes no
#      resolv.conf (dixi, 2026-11-12 07:13:25: "ena0/dhcp ok ?", "no DNS servers in the DHCP lease");
#  (c) the address is there but DNSserv is empty for 2 polls: resolv.conf is written once the servers appear
#      (and NEG: the pre-fix method writes none);
#  (d) no lease ever: the lease wait stops at 60 s and falls back to ifconfig, the DNS wait stops at 30 s;
#  (e) eval: services that need the network at start wait for solnix-net and solnix-netd (smf.networkOnline), solnix-net
#      itself does not.
#
#   sh scripts/test-net-bringup.sh [repo]   # floki: evaluates both methods (nix), then runs them
#   NET_NEW=f NET_OLD=f sh scripts/test-net-bringup.sh   # run already generated methods (an illumos host, /sbin/sh)
# Exits 0 on pass, 1 on any FAIL.
set -u
F=${1:-$(cd "$(dirname "$0")/.." && pwd)}
OLD_REV=${NET_OLD_REV:-5f0960ac258a3e76fc5b15a759ad89343de5c367}	# main before the lease-address fix
SH=${NET_SH:-sh}
T=$(mktemp -d); trap 'find "$T" -depth -type f -exec rm -f {} + ; find "$T" -depth -type d -exec rmdir {} +' EXIT
bad=0

# the start method's text (writeScript's `text`) for configurations/base.nix (ena0 DHCP, nameservers from the lease)
gen() { # gen <flake ref> <out file>
  d=$(nix eval --json --impure --expr "let f = builtins.getFlake \"$1\";
    c = (f.lib.solnixSystem { system = \"x86_64-solaris\"; pkgs = f.lib.mkPkgs { };
      modules = [ \"\${f}/configurations/base.nix\" ]; }).config;
    in builtins.attrNames (builtins.getContext c.smf.services.solnix-net.start.exec)" 2>"$T/eval.err" | jq -r '.[0]')
  case $d in /nix/store/*.drv) ;; *) echo "FAIL: eval $1: $(tail -2 "$T/eval.err")"; exit 1;; esac
  nix derivation show "$d" 2>/dev/null | jq -r '.. | objects | select(has("env")) | .env.text' > "$2"
  grep -q 'solnix networking bringup' "$2" || { echo "FAIL: no bringup text in $d"; exit 1; }
}
if [ -n "${NET_NEW:-}" ]; then cp "$NET_NEW" "$T/new.txt"; cp "$NET_OLD" "$T/old.txt"
else gen "git+file://$F" "$T/new.txt"; gen "git+file://$F?rev=$OLD_REV" "$T/old.txt"; fi

# every absolute tool/file path goes to the fakes; any left over would touch the real host: refuse to run
mkdir -p "$T/bin" "$T/etc"
for v in new old; do
  sed -e 's|/usr/sbin/|@T@/bin/|g' -e 's|/sbin/dhcpinfo|@T@/bin/dhcpinfo|g' -e 's|/usr/bin/|@T@/bin/|g' \
      -e 's|/etc/resolv\.conf|@T@/etc/resolv.conf|g' -e 's|/lib/svc/share/smf_include\.sh|@T@/smf_include.sh|g' \
      "$T/$v.txt" > "$T/$v.sed"
  if sed 1d "$T/$v.sed" | grep -v '^[ 	]*#' | sed 's|/dev/null||g' | grep -nE '(^|[^A-Za-z0-9_.@])/(usr|sbin|bin|etc|lib|var|dev)/'; then
    echo "FAIL: $v method has a host path the fakes do not cover (above)"; exit 1
  fi
  # ksh93 (illumos /sbin/sh) has sleep built in, ahead of PATH; a function comes before a regular builtin
  sed -e "s|@T@|$T|g" -e "1a\\
sleep() { $T/bin/sleep \"\$@\"; }" "$T/$v.sed" > "$T/$v.sh"
done
echo 'SMF_EXIT_OK=0' > "$T/smf_include.sh"

# fakes. $NB/clock counts sleeps; the lease (address, Yiaddr) appears at LEASE_AT, the DNS options at DNS_AT.
fake() { { echo '#!/bin/sh'; echo 'c=$(cat "$NB/clock"); echo "$(basename "$0") $*" >> "$NB/calls"'; cat; } > "$T/bin/$1"
  chmod +x "$T/bin/$1"; }
fake sleep <<'E'
[ "$1" = 2 ] && echo $((c + 1)) > "$NB/clock"	# the polls' tick; the dns/client nudge's `sleep 5` is not one
exit 0
E
fake ipadm <<'E'
if [ "$c" -ge "$LEASE_AT" ]; then a=172.31.32.50/20; else a='?'; fi
case "$*" in
"show-addr -p -o type ena0/") echo dhcp ;;
"show-addr -p -o type,state ena0/") echo dhcp:ok ;;
"show-addr -p -o type,state,addr ena0/") echo "dhcp:ok:$a" ;;
"show-addr -p -o addrobj,type") echo lo0/v4:static; echo ena0/dhcp:dhcp ;;
show-addr) echo "ADDROBJ           TYPE     STATE        ADDR"; echo "ena0/dhcp         dhcp     ok           $a" ;;
esac
exit 0
E
fake dhcpinfo <<'E'
case $3 in
Yiaddr) [ "$c" -ge "$LEASE_AT" ] && echo 172.31.32.50 ;;
DNSserv) [ "$c" -ge "$DNS_AT" ] && echo 172.31.0.2 ;;
DNSdmain) [ "$c" -ge "$DNS_AT" ] && echo us-west-2.compute.internal ;;
esac
exit 0
E
for t in dladm ifconfig route svcadm netstat hostname; do echo 'exit 0' | fake $t; done

run() { # run <new|old> <LEASE_AT> <DNS_AT>: the method's log in $T/log, fake calls in $NB/calls
  NB=$T/st-$1-$2-$3; mkdir -p "$NB"; echo 0 > "$NB/clock"; : > "$NB/calls"; rm -f "$T/etc/resolv.conf"
  NB=$NB LEASE_AT=$2 DNS_AT=$3 PATH="$T/bin:$PATH" $SH "$T/$1.sh" > "$T/log" 2>&1
  sleep_n=$(grep -c '^sleep 2$' "$NB/calls")
}
ok() { echo "ok: $1"; }
no() { echo "FAIL: $1"; sed 's/^/    | /' "$T/log"; bad=1; }
resolv_ok() { grep -qx 'nameserver 172.31.0.2' "$T/etc/resolv.conf" 2>/dev/null &&
  grep -qx 'domain us-west-2.compute.internal' "$T/etc/resolv.conf"; }
waited() { grep -q "ena0: after $1 s: ipadm dhcp:ok:172.31.32.50/20, Yiaddr '172.31.32.50'" "$T/log"; }
fallback() { grep -q '^ifconfig ena0 dhcp start' "$NB/calls"; }

# (a) ok + "?" for 3 polls, then the address
run new 3 3
if waited 6 && ! fallback && resolv_ok; then ok "(a) ok/? for 3 polls: waited 6 s for the address, no ifconfig fallback, resolv.conf written"
else no "(a) ok/? for 3 polls (sleeps $sleep_n)"; fi
grep -q "resolv.conf from the DHCP lease on ena0 after 0 s: DNSserv '172.31.0.2', DNSdmain 'us-west-2.compute.internal'" "$T/log" \
  && ok "(a) the log names what it saw (ipadm, Yiaddr, DNSserv, DNSdmain)" || no "(a) decision log"
# (b) NEG: the pre-fix method under the same fakes
run old 3 3
if [ "$sleep_n" -eq 0 ] && ! resolv_ok && grep -q 'no DNS servers in the DHCP lease' "$T/log" && grep -q 'ena0/dhcp.* ok  *?$' "$T/log"
then ok "(b) NEG pre-fix ($OLD_REV): stops at the first poll on ok/?, no resolv.conf (dixi 07:13:25 reproduced)"
else no "(b) NEG pre-fix should reproduce the bug (sleeps $sleep_n)"; fi
# (c) address at once, DNSserv empty for 2 polls
run new 0 2
if waited 0 && [ "$sleep_n" -eq 2 ] && resolv_ok && grep -q 'DHCP lease on ena0 after 4 s' "$T/log"
then ok "(c) DNSserv empty for 2 polls: resolv.conf written after 4 s"; else no "(c) late DNSserv (sleeps $sleep_n)"; fi
run old 0 2
if ! resolv_ok; then ok "(c) NEG pre-fix: late DNSserv leaves no resolv.conf"; else no "(c) NEG pre-fix wrote resolv.conf"; fi
# (d) never a lease: both waits are bounded
run new 999 999
if fallback && [ "$sleep_n" -eq 45 ] && grep -q 'ena0: after 60 s: ipadm dhcp:ok:?' "$T/log" &&
  grep -q 'no DNS servers in a DHCP lease after 30 s' "$T/log" && ! [ -e "$T/etc/resolv.conf" ]
then ok "(d) no lease: 60 s lease wait, ifconfig fallback, 30 s DNS wait, resolv.conf untouched"; else no "(d) no lease (sleeps $sleep_n)"; fi

# (e) smf.networkOnline, in the rendered manifests (NixOS's network-online.target): the services that need the network at
# start carry <dependency name=solnix-network-online grouping=optional_all> on site/solnix-net and site/solnix-netd
# (optional_all: met by the one a host does not have; svccfg on dixi 2026-11-12: require_all on an absent service never
# starts). solnix-netd's own side, its start method waiting for the network, is scripts/test-netd.sh.
xml() { # xml <config> <service>: the manifest's text, from its writeText drv
  d=$(nix eval --raw "git+file://$F#solnixConfigurations.$1.config.system.build.smfManifests.drvPath" 2>/dev/null)
  [ -n "$d" ] || return 1
  x=$(nix-store -qR "$d" | grep -- "-$2\.xml\.drv$") || return 1
  nix derivation show "$x" 2>/dev/null | jq -r '.. | objects | select(has("env")) | .env.text'; }
online() { tr -d '\n' | grep -q "<dependency name='solnix-network-online' grouping='optional_all' restart_on='none' type='service'> *<service_fmri value='svc:/site/solnix-net:default'/> *<service_fmri value='svc:/site/solnix-netd:default'/> *</dependency>"; }
if [ -z "${NET_NEW:-}" ]; then
  for cs in cloud-ec2:solnix-ec2-first-boot arnold:solnix-mtu; do
    if xml ${cs%%:*} ${cs#*:} | online; then ok "(e) ${cs#*:} (${cs%%:*}) waits for solnix-net and solnix-netd (optional_all)"; else echo "FAIL: (e) ${cs#*:} (${cs%%:*}): no network-online group"; bad=1; fi
  done
  if xml cloud-ec2 solnix-net | grep -q solnix-network-online; then echo "FAIL: (e) NEG solnix-net depends on itself"; bad=1
  elif xml cloud-ec2 solnix-net | grep -q "name='site/solnix-net'"; then ok "(e) NEG solnix-net itself has no network-online group"
  else echo "FAIL: (e) NEG: no solnix-net manifest to check"; bad=1; fi
fi

[ $bad = 0 ] && echo "RESULT PASS" || echo "RESULT FAIL"
exit $bad
