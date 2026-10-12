#!/bin/sh
# aa-netfix: replaces /usr/lib/metadata. Brings up DHCP on the ena NIC and logs
# to the console so get-console-output shows the result. Then enables ssh.
exec >>/var/log/aa-netfix.log 2>&1
log() { echo "AA-NETFIX: $*" > /dev/console 2>/dev/null; echo "AA-NETFIX: $*"; }
set -x
log "start $(date)"
NIC=""
i=0
while [ $i -lt 30 ]; do
  NIC=$(dladm show-phys -p -o LINK 2>/dev/null | head -1)
  [ -n "$NIC" ] && break
  i=$((i+1)); sleep 2
done
log "NIC=$NIC (waited ${i}x2s)"
dladm show-phys > /dev/console 2>&1
if [ -z "$NIC" ]; then log "NO NIC - ena not attached"; exit 0; fi
ipadm create-if "$NIC" 2>&1
ipadm delete-addr "$NIC/v4" 2>/dev/null
ipadm delete-addr "$NIC/dhcp" 2>/dev/null
ipadm create-addr -T dhcp -w 60 "$NIC/dhcp" 2>&1
ADDR=$(ipadm show-addr -p -o ADDR "$NIC/dhcp" 2>/dev/null)
log "lease=$ADDR"
ipadm show-addr > /dev/console 2>&1
netstat -rn > /dev/console 2>&1
printf 'nameserver 169.254.169.253\nnameserver 8.8.8.8\n' > /etc/resolv.conf
cp /etc/nsswitch.dns /etc/nsswitch.conf 2>/dev/null
svcadm enable -s svc:/network/ssh:default 2>&1
hostname solnix-arm64-buildhost 2>/dev/null
log "ssh enabled; done $(date)"
# grow pool
for P in $(zpool list -H -o name 2>/dev/null); do
  DEV=$(zpool status "$P" 2>/dev/null | awk -v p="$P" '$1==p{f=1;next} f&&NF>=5{print $1;exit}')
  [ -n "$DEV" ] && zpool online -e "$P" "$DEV" 2>&1
done
exit 0
