#!/bin/sh
# metadata-shim.sh — replaces /usr/lib/metadata in the OpenIndiana cloud image.
#
# WHY: the OI cloud image's real metadata-agent is an IMDSv1 client. This AWS
# account enforces IMDSv2 (org guardrail we can't disable), so the agent's IMDS
# GETs 401 and it hangs to its 300s timeout, GATING svc:/milestone/network and
# blocking boot from ever reaching multi-user (no network, no ssh, hostname
# stays "unknown"). We swap the agent for this shim, which does the same
# networking the agent would (ipadm DHCP) and enables ssh, then exits 0 so the
# milestones proceed. It reuses the agent's own SMF service + network ordering.
#
# NIC NOTE: the OI cloud image has NO `ena` driver (not in driver_aliases /
# name_to_major / kernel tree) — only `xnf` (Xen), `vioif` (virtio), `ixgbe`.
# So this host MUST run on a Xen-HVM EC2 type (m4/c4/t2), where the NIC is
# `xnf0`. It will NOT get a NIC on Nitro (c5/m5/...) instances.
exec >>/var/log/solnix-metadata.log 2>&1
set -x
echo "=== solnix shim $(date) ==="
i=0; NIC=""
while [ $i -lt 30 ]; do
  NIC=$(dladm show-phys -p -o LINK 2>/dev/null | head -1)
  [ -n "$NIC" ] && break
  i=$((i+1)); sleep 2
done
echo "waited ${i}x2s; NIC='$NIC'"
if [ -n "$NIC" ]; then
  ipadm create-if "$NIC" 2>&1 || true
  ipadm create-addr -T dhcp -w 30 "$NIC/dhcp" 2>&1 || ipadm create-addr -T dhcp "$NIC/v4" 2>&1 || true
  # Clamp MTU: the AWS->OI-mirror (Hetzner) path black-holes/shapes large
  # packets over xnf, stalling pkg. 1400 keeps pkg fetches alive.
  dladm set-linkprop -p mtu=1400 "$NIC" 2>&1 || true
fi
# DNS (DHCP on illumos here doesn't seed resolv.conf reliably)
[ -s /etc/resolv.conf ] || printf 'nameserver 169.254.169.253\nnameserver 8.8.8.8\n' > /etc/resolv.conf
[ -e /etc/nsswitch.conf ] || cp /etc/nsswitch.dns /etc/nsswitch.conf 2>/dev/null || true
svcadm enable -s svc:/network/dns/client 2>&1 || true
svcadm enable -s svc:/network/ssh:default 2>&1 || true
hostname solnix-builder-build 2>/dev/null || true
echo "=== shim done $(date) ==="
exit 0
