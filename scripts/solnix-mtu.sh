#!/bin/sh
# solnix-mtu.sh -- evidence-based, post-DHCP MTU raise for cloud NICs (ena).
#
# See docs/design-mtu-policy.md. The driver boots at a boot-safe MTU (1500) so
# DHCP always completes; this service runs AFTER the network is verified up and
# raises the MTU to the maximum the instance's path actually supports -- only
# when a probe confirms the larger MTU still works, and rolling straight back to
# 1500 if it does not. Boot reliability (a working 1500 lease) always wins.
#
# It is idempotent and logs to /var/log/solnix-mtu.log. It never lowers below
# 1500 and never leaves the link at a size it did not verify.
#
# Policy (EC2, within-VPC): jumbo-capable Nitro types (m5/m6i/c5/c6i/c7i/r5/
# r6i/.../.metal) -> min(9001, ena_max_mtu); everything else / unknown / probe
# failure -> 1500.
#
# NOTE: on the illumos ena driver a MAC_PROP_MTU change is only applied while the
# link is stopped (the driver reallocates its Rx/Tx buffers at ring start and
# refuses a live resize with EBUSY, because its only in-driver reprogram path is
# the error-recovery reset, which is unsafe under an active data path -- it
# latches the device fatal-error bit). So the raise is applied by writing the
# per-instance target to the ena.conf "mtu" property and letting it take effect
# at a clean re-attach; the probe below then confirms the raised link still
# carries traffic and reverts the property to 1500 if it does not. Where the
# link property CAN be set live (a future ena, or another NIC), the same probe/
# rollback path sets it directly with dladm.

exec >>/var/log/solnix-mtu.log 2>&1
set -x
echo "=== solnix-mtu $(date) ==="

STATE=/var/lib/solnix
NET_OK="$STATE/net-ok"
DONE="$STATE/mtu-done"          # set once we have settled on a final MTU
ENACONF=/kernel/drv/ena.conf
JUMBO_VPC=9001                  # AWS supported within-VPC jumbo MTU
SAFE=1500
mkdir -p "$STATE" 2>/dev/null || true

# optional overrides from the generated /etc/default/solnix-mtu (mtu.nix knobs).
if [ -r /etc/default/solnix-mtu ]; then
	. /etc/default/solnix-mtu
	[ -n "$SOLNIX_MTU_JUMBO" ] && JUMBO_VPC=$SOLNIX_MTU_JUMBO
	[ -n "$SOLNIX_MTU_SAFE" ] && SAFE=$SOLNIX_MTU_SAFE
fi

NIC=$(dladm show-phys -p -o LINK 2>/dev/null | head -1)
[ -n "$NIC" ] || { echo "no NIC; nothing to do"; exit 0; }

cur_ip() {
	ipadm show-addr -po addrobj,addr 2>/dev/null | grep "^${NIC}/" \
	    | sed 's,^[^:]*:,,; s,/.*,,' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
	    | grep -vE '^0\.0\.0\.0$' | head -1
}
gw() { netstat -rn 2>/dev/null | awk '/^default/{print $2; exit}'; }

# IMDSv2: fetch a session token (this account enforces v2; v1 GETs 401/empty).
imds_token() {
	curl -s --max-time 5 -X PUT \
	    -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' \
	    http://169.254.169.254/latest/api/token 2>/dev/null
}
imds() {   # imds <path>  -> value, using a v2 token (falls back to v1)
	t=$(imds_token)
	if [ -n "$t" ]; then
		curl -s --max-time 5 -H "X-aws-ec2-metadata-token: $t" \
		    "http://169.254.169.254/latest/$1" 2>/dev/null
	else
		curl -s --max-time 5 "http://169.254.169.254/latest/$1" 2>/dev/null
	fi
}

# link-layer max the device reports (dladm "possible" upper bound), else 0.
ena_max() {
	dladm show-linkprop -p mtu -co possible "$NIC" 2>/dev/null \
	    | tr ',' '\n' | sed 's,.*-,,; s,[^0-9],,g' | sort -n | tail -1
}

# probe: link usable at the CURRENT MTU? gateway reachable AND IMDS reachable.
probe_ok() {
	g=$(gw); [ -n "$g" ] || return 1
	ping "$g" 3 >/dev/null 2>&1 || return 1
	[ -n "$(imds meta-data/instance-type)" ] || return 1
	return 0
}

# jumbo probe: send frames that force a large receive, so a NIC that cannot
# actually carry jumbo (rather than merely being configured for it) is caught.
probe_jumbo_ok() {
	g=$(gw); [ -n "$g" ] || return 1
	# ~8000-byte payload, must round-trip at the raised MTU.
	ping -s "$g" 8000 3 >/dev/null 2>&1 || return 1
	probe_ok || return 1
	return 0
}

set_prop_mtu() {   # set ena.conf mtu= property (applied at next attach)
	m=$1
	grep -v '^mtu' "$ENACONF" > "$ENACONF.new" 2>/dev/null
	echo "mtu=$m;" >> "$ENACONF.new"
	mv "$ENACONF.new" "$ENACONF"
	bootadm update-archive >/dev/null 2>&1 || true
}
prop_mtu() { sed -n 's/^mtu=\([0-9]*\);.*/\1/p' "$ENACONF" 2>/dev/null | tail -1; }
live_mtu() { dladm show-linkprop -p mtu -co value "$NIC" 2>/dev/null; }

# ---- gate on a working network (the metadata-shim sets net-ok on a real lease).
i=0; while [ ! -f "$NET_OK" ] && [ -z "$(cur_ip)" ] && [ $i -lt 30 ]; do
	i=$((i+1)); sleep 2
done
if [ -z "$(cur_ip)" ]; then
	echo "no usable IP; leaving MTU at boot default, will retry next boot"
	exit 0
fi
echo "usable IP $(cur_ip), live MTU $(live_mtu), device max $(ena_max)"

# ---- decide the target from evidence (instance type + device max).
ITYPE=$(imds meta-data/instance-type)
echo "instance-type=$ITYPE"
EMAX=$(ena_max); [ -n "$EMAX" ] || EMAX=$SAFE
TARGET=$SAFE
case "$ITYPE" in
	# jumbo-capable current-gen Nitro families (+ .metal), per policy table.
	m5*|m6*|m7*|c5*|c6*|c7*|r5*|r6*|r7*|i3en*|i4*|*.metal)
		# clamp to min(9001, device max); never the raw device max.
		if [ "$EMAX" -ge "$JUMBO_VPC" ]; then TARGET=$JUMBO_VPC; else TARGET=$EMAX; fi
		;;
	*) TARGET=$SAFE ;;
esac
echo "policy target MTU=$TARGET (device max $EMAX)"

# ---- roll back a previously-attempted raise that did NOT survive to a good boot.
# If the link is somehow already running above the safe MTU (e.g. a stale
# ena.conf "mtu" property from a manual experiment), verify it actually carries
# jumbo; if not, revert the property to 1500 so the next boot is safe again.
PROP=$(prop_mtu); [ -n "$PROP" ] || PROP=$SAFE
LIVE=$(live_mtu); [ -n "$LIVE" ] || LIVE=$SAFE
if [ "$LIVE" -gt "$SAFE" ]; then
	if probe_jumbo_ok; then
		echo "raised MTU $LIVE verified (jumbo round-trips + IMDS/gw ok); keeping"
		: > "$DONE" 2>/dev/null || true
		exit 0
	fi
	echo "raised MTU $LIVE FAILED jumbo probe; reverting property to $SAFE and rebooting"
	set_prop_mtu "$SAFE"
	sleep 2; /usr/sbin/reboot; exit 0
fi

# ---- we are at the safe MTU. Attempt the raise ONLY as a live, same-boot
# change that we can immediately probe and revert. We deliberately do NOT stage
# a raise into a reboot: on the current ena driver a real jumbo *receive* can
# latch the device fatal-error bit (rx_sgl_max=1, single large Rx buffer), and a
# wedge discovered only after a reboot cannot be rolled back from inside the OS
# (the NIC is gone). A live raise, by contrast, is probed here and reverted in
# the same boot if the probe fails, so the link is never left in an unverified
# state. On the current ena, a live MAC_PROP_MTU change on an up link returns
# EBUSY (the driver only resizes buffers at a clean attach) -- so this settles
# safely at 1500 and records that jumbo is unsupported on this host. The same
# code path enables jumbo automatically on any NIC/driver that DOES permit a
# verified live resize.
if [ -f "$DONE" ]; then
	echo "MTU already settled at $LIVE; nothing to do"
	exit 0
fi
if [ "$TARGET" -le "$SAFE" ]; then
	echo "policy MTU is $SAFE; staying at safe MTU"
	: > "$DONE" 2>/dev/null || true
	exit 0
fi

if dladm set-linkprop -t -p mtu="$TARGET" "$NIC" 2>/tmp/mtu.err; then
	echo "live-set MTU=$TARGET ok; probing jumbo reachability"
	sleep 3
	if probe_jumbo_ok; then
		echo "live raise to $TARGET verified; making persistent"
		dladm set-linkprop -p mtu="$TARGET" "$NIC" 2>/dev/null || set_prop_mtu "$TARGET"
		: > "$DONE" 2>/dev/null || true
		exit 0
	fi
	echo "live raise to $TARGET failed probe; reverting to $SAFE"
	dladm set-linkprop -t -p mtu="$SAFE" "$NIC" 2>/dev/null || true
	: > "$DONE" 2>/dev/null || true
	exit 0
fi
echo "live set-linkprop rejected ($(cat /tmp/mtu.err 2>/dev/null)); jumbo not supported live on this driver -- staying at safe MTU $SAFE"
: > "$DONE" 2>/dev/null || true
exit 0
