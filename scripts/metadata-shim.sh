#!/bin/sh
# metadata-shim.sh — replaces /usr/lib/metadata in the solnix (OpenIndiana-derived)
# cloud image on EC2 Nitro (ena NIC).
#
# WHY: the stock OI metadata-agent is an IMDSv1 client; this account enforces
# IMDSv2, so the agent 401s and hangs to its 300s timeout, gating
# svc:/milestone/network. We swap it for this shim, which brings up DHCP on the
# ena NIC and enables ssh, then exits 0 so the milestones proceed.
#
# Nitro/ena: single DHCP addrobj only (ena0/dhcp). One addrobj, no mtu twiddling
# (the ena driver defaults MTU to 1500 = ETHERMTU).
#
# COLD-BOOT DHCP RACE: the persisted /etc/ipadm/ipadm.conf bakes in the ena0/dhcp
# addrobj, so svc:/network/ip-interface-management starts DHCP on it at boot,
# BEFORE this shim runs — the real lease is driven by the SMF network stack, not
# by this shim's create-addr (which just reports "already exists"). On a cold
# Nitro boot the OFFER and ACK are received (proven) but the first
# configure_v4_lease can lose a timing race and the addrobj comes up with no
# lease. RECOVERY: re-request the lease IN PLACE with `ipadm refresh-addr`, which
# renews WITHOUT destroying the working persisted addrobj (delete-addr would tear
# down the very config the SMF stack already bound and make the race permanent).
# Loop a few times after the stack is warm; a fresh transaction almost always
# binds without a reboot. Only if the in-place loop is exhausted do we fall back
# to a BOUNDED reboot (counter file, not a one-shot mark) so a stubborn instance
# still recovers unattended without ever looping forever.
exec >>/var/log/solnix-metadata.log 2>&1
set -x
echo "=== solnix shim $(date) ==="

# Wait for the NIC to attach.
i=0; NIC=""
while [ $i -lt 45 ]; do
  NIC=$(dladm show-phys -p -o LINK 2>/dev/null | head -1)
  [ -n "$NIC" ] && break
  i=$((i+1)); sleep 2
done
echo "waited ${i}x2s; NIC='$NIC'"

lease_ok() {
  # true if NIC/dhcp holds a real v4 lease (not empty/?/0.0.0.0)
  a=$(ipadm show-addr -p -o ADDR "$NIC/dhcp" 2>/dev/null)
  case "$a" in
    ""|\?|0.0.0.0*) return 1 ;;
    *) echo "lease=$a"; return 0 ;;
  esac
}

if [ -n "$NIC" ]; then
  ipadm create-if "$NIC" 2>&1 || true
  # Drop only a STALE Xen-era ena0/v4 addrobj (never the persisted ena0/dhcp).
  ipadm delete-addr "$NIC/v4" 2>/dev/null || true
  # Ensure the dhcp addrobj exists (persisted config normally already made it;
  # this only matters on an image without the baked ipadm.conf). NEVER delete it.
  if ! ipadm show-addr -p -o ADDROBJ "$NIC/dhcp" >/dev/null 2>&1; then
    ipadm create-addr -T dhcp -w 30 "$NIC/dhcp" 2>&1 || true
  fi

  # Enable ssh + dns NOW (not after the DHCP loop) so the instant a lease binds
  # the box is reachable -- no extra serialized delay on the recovery path.
  [ -s /etc/resolv.conf ] || printf 'nameserver 169.254.169.253\nnameserver 8.8.8.8\n' > /etc/resolv.conf
  [ -e /etc/nsswitch.conf ] || cp /etc/nsswitch.dns /etc/nsswitch.conf 2>/dev/null || true
  svcadm enable -s svc:/network/dns/client 2>&1 || true
  svcadm enable -s svc:/network/ssh:default 2>&1 || true

  # Wait for the SMF-stack-driven DHCP to bind (widened watchdog for the heavy image).
  j=0
  while [ $j -lt 30 ]; do
    lease_ok && break
    j=$((j+1)); sleep 2
  done

  # In-place re-request loop: NON-DESTRUCTIVELY force a fresh DHCP transaction
  # (keeps the working persisted addrobj -- delete-addr would tear down the config
  # the SMF stack bound and make the race permanent). Each pass tries two gentle
  # levers: refresh-addr (renew), then an interface bounce (down/up drives a fresh
  # DISCOVER). The OFFER/ACK are proven to arrive on the ena Rx path, so a fresh
  # in-place transaction after the stack is warm binds -- we AVOID rebooting
  # entirely on the DHCP path, because a reboot re-rolls the (separate) rare
  # early-boot kernel-init hang. Many patient in-place passes >> one reboot.
  k=0
  while [ $k -lt 8 ] && ! lease_ok; do
    k=$((k+1))
    echo "no lease yet; in-place DHCP recovery pass $k $(date)"
    ipadm refresh-addr "$NIC/dhcp" 2>&1 || true
    ipadm disable-if -t "$NIC" 2>&1 || true
    sleep 1
    ipadm enable-if -t "$NIC" 2>&1 || true
    j=0
    while [ $j -lt 15 ]; do
      lease_ok && break
      j=$((j+1)); sleep 2
    done
  done

  # Last resort ONLY after ~8 in-place passes (~5min) have all failed: a single
  # bounded reboot (counter, max 1). In-place recovery is strongly preferred; the
  # reboot exists purely so a truly wedged network stack still self-heals
  # unattended. Kept to 1 to minimize exposure to the early-boot hang on re-roll.
  if ! lease_ok; then
    CNT=/var/lib/solnix-dhcp-reboots
    mkdir -p /var/lib
    n=$(cat "$CNT" 2>/dev/null || echo 0)
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    if [ "$n" -lt 1 ]; then
      echo "$((n+1))" > "$CNT"
      echo "in-place recovery exhausted; single bounded reboot $((n+1))/1 $(date)"
      sync
      /usr/sbin/reboot
    else
      echo "reboot budget (1) exhausted; giving up cleanly $(date)"
    fi
  else
    rm -f /var/lib/solnix-dhcp-reboots 2>/dev/null || true
  fi
fi

# DNS/ssh already enabled above (before the DHCP wait). Re-assert idempotently
# in case the NIC path was skipped, then finish so milestones proceed.
[ -s /etc/resolv.conf ] || printf 'nameserver 169.254.169.253\nnameserver 8.8.8.8\n' > /etc/resolv.conf
svcadm enable -s svc:/network/ssh:default 2>&1 || true
hostname solnix-builder-build 2>/dev/null || true

# Grow the root pool to the whole slice. A cloud image is authored at a small size
# (~1.9GiB), so on a larger EBS volume the pool would otherwise leave the extra
# space unused and the image runs out of room almost immediately. This cannot be
# done from the image-build helper: the vdev is whole_disk=1, and expanding it
# requires relabeling the slice, which OpenZFS-on-Linux refuses ("unable to read
# disk capacity") -- only the illumos ZFS/EFI label code does it. So it happens
# here, on the first boot that reaches this shim. `online -e` is a no-op once the
# vdev already covers its device, so this is idempotent and costs nothing on
# subsequent boots. Deliberately LAST: network bring-up must never wait on it.
for P in $(zpool list -H -o name 2>/dev/null); do
  DEV=$(zpool status "$P" 2>/dev/null | awk -v p="$P" '$1==p{f=1;next} f&&NF>=5{print $1;exit}')
  [ -n "$DEV" ] && zpool online -e "$P" "$DEV" 2>&1
done
zpool list 2>&1

echo "=== shim done $(date) ==="
exit 0
