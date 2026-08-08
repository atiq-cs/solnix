#!/bin/sh
# metadata-shim.sh — replaces /usr/lib/metadata in the OpenIndiana cloud image.
#
# WHY: the OI cloud image's real metadata-agent is an IMDSv1 client and this AWS
# account enforces IMDSv2, so the agent 401s and hangs to its 300s SMF timeout,
# gating svc:/milestone/network. We swap it for this shim, which brings
# networking up (DHCP on ena0) + enables ssh, then exits FAST so the milestones
# proceed. The slow retry/route/reboot work is BACKGROUNDED so the SMF method
# returns quickly (a long-blocking method is itself killed at the 300s timeout,
# which is how earlier versions lost their reboot/ssh steps).
#
# FRESH-COLD-LAUNCH FAILURES on the solnix AMI (PS-FIRSTBOOT-NETWORK) + fixes:
#   (A) DUAL DHCP ADDROBJ (the ~50% root cause): the baked
#       /etc/ipadm/ipadm.conf carries TWO DHCP addrobjs on ena0 (ena0/dhcp AND
#       ena0/v4). dhcpagent tries to bind BOTH on the one NIC and they collide
#       -> "configure_v4_lease: cannot set IP address on ena0: Cannot assign
#       requested address" / "dhcp_bound failed" -> no lease -> "Hostname:
#       unknown", no net, sshd unreachable. (The old shim RE-created ena0/v4 on
#       every boot, guaranteeing the conflict.) FIX: keep exactly ONE addrobj.
#   (B) NO DEFAULT ROUTE -> ssh "filtered": some boots get an IP but no default
#       route (lease landed on a secondary addrobj) -> SYN-ACKs can't leave ->
#       port 22 looks filtered. FIX: add the VPC default route explicitly.
#   (C) sshd/cryptosvc LEFT IN MAINTENANCE: they can go to maintenance if they
#       start before net/crypto is ready; a plain enable does NOT clear it.
#       FIX: svcadm clear before enable.
#   (D) SPURIOUS REBOOT vs. LOST DHCP DICE-ROLL (the cold-launch failure): the
#       real signal for a usable network is an INSTALLED IPv4 on ena0 (ipadm's
#       ADDR column), NOT the addrobj STATE. On the flaky ena path the addrobj
#       can read STATE=ok while ADDR stays "?" (lease acknowledged but its IP
#       never installed) -- and dhcpagent frequently fails the lease outright
#       ("ena0 has a bad address 0.0.0.0", no dhcp_bound). No in-OS action
#       recovers a wedged dhcpagent on ena (svcadm restart network/physical,
#       ipadm disable/enable-if, pkill+recreate all verified useless); only a
#       fresh boot yields a fresh, sometimes-working lease. So gate the reboot
#       on cur_ip (an installed IP): a host that HAS an IP is never rebooted;
#       a host that lost the dice-roll reboots for another try, bounded by a
#       reboot COUNTER (REBOOT_STAMP holds the count, cap MAX_REBOOTS) so
#       losing hosts get several fresh leases without ever looping forever.
#       Earlier versions either rebooted a host that already had a working IP
#       (STATE=ok/ADDR=? race -> boot-2 dice-roll lost ~7/10) or capped at ONE
#       reboot (one fresh try, ~29% cumulative); both are wrong.
exec >>/var/log/solnix-metadata.log 2>&1
set -x
echo "=== solnix shim $(date) ==="

STATE=/var/lib/solnix; REBOOT_STAMP="$STATE/first-boot-net-reboots"
NET_OK="$STATE/net-ok"
mkdir -p "$STATE" 2>/dev/null || true

# (A) collapse the dual DHCP addrobj to a single ena0/dhcp in the persistent
# config so dhcpagent does not fight itself. Idempotent.
if grep -q '_aobjname=ena0/v4' /etc/ipadm/ipadm.conf 2>/dev/null; then
  echo "-- removing redundant ena0/v4 DHCP addrobj (dual-addrobj bind conflict)"
  grep -v '_aobjname=ena0/v4' /etc/ipadm/ipadm.conf > /etc/ipadm/ipadm.conf.new 2>/dev/null \
    && mv /etc/ipadm/ipadm.conf.new /etc/ipadm/ipadm.conf
fi

NIC=$(dladm show-phys -p -o LINK 2>/dev/null | head -1)
i=0
while [ -z "$NIC" ] && [ $i -lt 15 ]; do
  i=$((i+1)); sleep 2; NIC=$(dladm show-phys -p -o LINK 2>/dev/null | head -1)
done
echo "NIC='$NIC'"

# kill any stray secondary DHCP addrobj so only ena0/dhcp binds (no conflict).
[ -n "$NIC" ] && ipadm delete-addr "$NIC/v4" 2>/dev/null || true

# DNS + ssh up-front (fast, synchronous) — clear maintenance FIRST.
[ -s /etc/resolv.conf ] || printf 'nameserver 169.254.169.253\nnameserver 8.8.8.8\n' > /etc/resolv.conf
[ -e /etc/nsswitch.conf ] || cp /etc/nsswitch.dns /etc/nsswitch.conf 2>/dev/null || true
svcadm clear svc:/network/dns/client 2>/dev/null || true
svcadm enable svc:/network/dns/client 2>/dev/null || true
svcadm clear svc:/system/cryptosvc 2>/dev/null || true
svcadm clear svc:/network/ssh:default 2>/dev/null || true
svcadm enable svc:/system/cryptosvc 2>/dev/null || true
svcadm enable svc:/network/ssh:default 2>/dev/null || true

NN=$(cat /etc/nodename 2>/dev/null); { [ -n "$NN" ] && [ "$NN" != unknown ]; } || NN=solnix
hostname "$NN" 2>/dev/null || true

# ---- backgrounded network worker: waits for the baked ena0/dhcp to install a
#      usable IP, adds the route, re-enables ssh, and (only if no IP appears)
#      reboots for a fresh DHCP dice-roll -- bounded by a reboot counter. Runs
#      detached so the SMF method returns immediately (no 300s-timeout kill).
[ -n "$NIC" ] && (
  cur_ip() {
    ipadm show-addr -po addrobj,addr 2>/dev/null | grep "^${NIC}/" \
      | sed 's,^[^:]*:,,; s,/.*,,' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
      | grep -vE '^0\.0\.0\.0$' | head -1
  }
  add_route() {
    netstat -rn 2>/dev/null | grep -q '^default' && return 0
    ip=$(cur_ip); [ -n "$ip" ] || return 1
    gw=$(echo "$ip" | awk -F. '{printf "%d.%d.%d.%d",$1,$2,int($3/16)*16,1}')
    echo "adding default route via $gw (from $ip/20)"
    route -p add default "$gw" 2>&1 || route add default "$gw" 2>&1 || true
  }

  # Bring up a REAL, usable IP on ena0. "Usable" means cur_ip is non-empty (an
  # actual IPv4 is installed on the NIC) -- NOT merely STATE=ok. On the flaky
  # ena path the addrobj can reach STATE=ok while the lease IP is never
  # installed (ADDR stays "?"): that host has no route and no ssh. And when
  # dhcpagent fails to complete a lease on the ena link (the ~85%/boot ena DHCP
  # dice-roll: "ena0 has a bad address 0.0.0.0", no dhcp_bound), NO in-OS action
  # recovers it -- svcadm restart network/physical, ipadm disable/enable-if,
  # pkill dhcpagent + re-create all leave the agent wedged (verified). The only
  # thing that yields a fresh, working lease is a fresh boot. So: wait for the
  # baked ena0/dhcp to install an IP; if it does not, reboot for another
  # dice-roll -- bounded by a reboot COUNTER so losing hosts get several fresh
  # tries (1 - p_fail^tries) instead of the single retry the old one-shot
  # sentinel allowed, while a working host is NEVER rebooted and the counter
  # caps the loop.

  # phase 1: wait (generously) for the baked ena0/dhcp to install a real IP.
  k=0; while [ $k -lt 30 ] && [ -z "$(cur_ip)" ]; do k=$((k+1)); sleep 2; done
  # phase 2: one cheap in-OS re-kick in case dhcpagent just needs a nudge (does
  # not recover a truly wedged agent, but is free and occasionally helps).
  if [ -z "$(cur_ip)" ]; then
    echo "no usable IP after wait -> one in-OS re-kick (refresh + restart net/phys)"
    ipadm refresh-addr "$NIC/dhcp" 2>&1 || true
    svcadm restart svc:/network/physical:default 2>&1 || true
    w=0; while [ $w -lt 15 ] && [ -z "$(cur_ip)" ]; do w=$((w+1)); sleep 2; done
  fi

  ifconfig "$NIC" mtu 1400 2>&1 || dladm set-linkprop -p mtu=1400 "$NIC" 2>&1 || true
  add_route
  # re-clear/enable ssh now the network is up (in case it raced earlier).
  svcadm clear svc:/network/ssh:default 2>/dev/null || true
  svcadm enable svc:/network/ssh:default 2>/dev/null || true

  echo "-- worker ipadm show-addr:"; ipadm show-addr 2>&1
  echo "-- worker default route:"; netstat -rn 2>&1 | grep default | head -2

  # (D) decide on a reboot using the REAL usability signal (cur_ip = an actual
  # installed IP), never STATE=ok. If we have an IP, mark net-ok and never
  # reboot. If not, the ena DHCP dice-roll was lost this boot and no in-OS fix
  # recovers it -> reboot for a fresh lease, bounded by a reboot COUNTER so a
  # host that keeps losing gets several fresh tries but can never loop forever.
  # reboot budget: a fresh boot recovers hosts that merely lost the DHCP
  # dice-roll, but on many instances the ena data path is dead (link up yet no
  # packet flows: no DHCP, and IMDS/route are unreachable too) and no number of
  # reboots helps -- that is the ena driver, not something this shim can fix.
  # So keep a SMALL budget: it converts the recoverable losers (measured: some
  # hosts pass only on reboot #1) without burning ~4.5 min/reboot on the
  # persistently-dead ones.
  MAX_REBOOTS=3
  if [ -n "$(cur_ip)" ]; then
    : > "$NET_OK" 2>/dev/null || true
    echo "usable IP $(cur_ip) installed; net-ok sentinel set, no reboot"
  elif [ -f "$NET_OK" ]; then
    echo "no IP this pass but net-ok sentinel present; not rebooting"
  else
    n=$(cat "$REBOOT_STAMP" 2>/dev/null); [ -n "$n" ] || n=0
    if [ "$n" -lt "$MAX_REBOOTS" ]; then
      echo "no usable IP (ena DHCP lost); reboot $((n+1))/$MAX_REBOOTS for a fresh lease"
      echo $((n+1)) > "$REBOOT_STAMP" 2>/dev/null || true
      sleep 3; /usr/sbin/reboot
    else
      echo "no usable IP after $MAX_REBOOTS reboots; giving up (ena DHCP driver issue)"
    fi
  fi
  echo "=== worker done $(date) ==="
) >>/var/log/solnix-metadata.log 2>&1 &

echo "=== shim done (worker backgrounded) $(date) ==="
exit 0
