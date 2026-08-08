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
#   (D) racey ena link: rarely the ena AENQ link-up event is slow; the
#       backgrounded worker retries DHCP (ipadm + legacy ifconfig, gotcha #15)
#       and, only if there is truly no address, reboots ONCE (sentinel-bounded).
exec >>/var/log/solnix-metadata.log 2>&1
set -x
echo "=== solnix shim $(date) ==="

STATE=/var/lib/solnix; REBOOT_STAMP="$STATE/first-boot-net-rebooted"
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

# ---- backgrounded network worker: brings DHCP up, routes, re-enables ssh, and
#      reboots once if the ena link never yields an address. Runs detached so
#      the SMF method returns immediately (no 300s-timeout kill).
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

  # wait briefly for dhcpagent (baked ena0/dhcp) to bind once the link is up.
  k=0; while [ $k -lt 20 ]; do [ -n "$(cur_ip)" ] && break; k=$((k+1)); sleep 2; done

  # not up yet? re-kick: refresh the baked addrobj, then legacy ifconfig
  # (ignores the ena unknown link STATE — gotcha #15).
  if [ -z "$(cur_ip)" ]; then
    ipadm refresh-addr "$NIC/dhcp" 2>&1 || ipadm create-addr -T dhcp -w 40 "$NIC/dhcp" 2>&1
  fi
  if [ -z "$(cur_ip)" ]; then
    ifconfig "$NIC" plumb 2>&1 || true
    ifconfig "$NIC" up 2>&1 || true
    ifconfig "$NIC" dhcp start wait 40 2>&1
  fi

  ifconfig "$NIC" mtu 1400 2>&1 || dladm set-linkprop -p mtu=1400 "$NIC" 2>&1 || true
  add_route
  # re-clear/enable ssh now the network is up (in case it raced earlier).
  svcadm clear svc:/network/ssh:default 2>/dev/null || true
  svcadm enable svc:/network/ssh:default 2>/dev/null || true

  echo "-- worker ipadm show-addr:"; ipadm show-addr 2>&1
  echo "-- worker default route:"; netstat -rn 2>&1 | grep default | head -2

  # (D) truly no address after all that -> one automatic reboot (sentinel-bounded)
  if [ -z "$(cur_ip)" ]; then
    if [ ! -f "$REBOOT_STAMP" ]; then
      echo "no address after DHCP attempts -> one automatic reboot"
      : > "$REBOOT_STAMP" 2>/dev/null || true
      sleep 3; /usr/sbin/reboot
    else
      echo "no address but already rebooted once; not looping"
    fi
  fi
  echo "=== worker done $(date) ==="
) >>/var/log/solnix-metadata.log 2>&1 &

echo "=== shim done (worker backgrounded) $(date) ==="
exit 0
