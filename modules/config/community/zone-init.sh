#!/usr/bin/ksh93
# zone-init.sh -- PID 1 of the solnix builder zone (the brand's initname is a store wrapper that runs this with the env
# file). No SMF in the zone (milestone 2): the zone runs three things, so init starts them itself.
#   1. ipmgmtd, then the zone's exclusive-IP address and default route (bzz0, allowed-address clamps it to ZONE_ADDR);
#   2. the zone's own nix-daemon (zone root), the store's only writer;
#   3. the queue builder as the untrusted user, restarted a minute after it exits.
# Logs go to /var/log/zone-init.log INSIDE the zone (read them with zlogin, never through the GZ path: the zone owns it).
. "$1" || exit 1
export PATH=/usr/bin:/usr/sbin:/sbin
umask 022
exec < /dev/null >> /var/log/zone-init.log 2>&1
log() { printf '%(%Y-%m-%dT%H:%M:%SZ)T zone-init: %s\n' now "$*"; }
log "start"
# what the zone's svc:/system/filesystem/minimal would mount from vfstab: fdfs (bash's <(...) and /dev/fd/N need it;
# the gate's ts-errno-gate.sh failed "/dev/fd/63: No such file or directory" without it)
mount -F fd fd /dev/fd || log "/dev/fd mount failed"
# ipmgmtd -f runs in the foreground and reports its start on fd 0 (ipmgmt_main.c: pfds[1] is 0 without a fork), so
# it needs a WRITABLE fd 0. Not `ipmgmtd <> /dev/null &`: ksh gives a background job a read-only /dev/null stdin
# first, the write fails EBADF and ipmgmtd exits 1 (truss, 2026-10-30).
( exec 0<> /dev/null; exec /lib/inet/ipmgmtd -f ) &
typeset -i n=0
until ipadm show-if > /dev/null 2>&1 || (( n++ > 20 )); do sleep 1; done
ipadm create-if -t lo0 2> /dev/null	# a zone boots with no lo0 (the GZ's net-loopback does this)
ipadm create-addr -t -T static -a 127.0.0.1/8 lo0/v4 || log "lo0 failed"
# the address zonecfg allows (allowed-address clamps the link to it; ipadm shows it "from-gz")
ipadm create-if -t "$ZONE_LINK" || log "$ZONE_LINK create-if failed"
ipadm create-addr -t -T static -a "$ZONE_ADDR/$ZONE_PREFIX" "$ZONE_LINK/v4" || log "$ZONE_LINK address failed"
route -n add default "$ZONE_GW" || log "default route failed"
log "net: $(ipadm show-addr -p -o addrobj,addr | tr '\n' ' ')"
"$ZONE_NIX/bin/nix-daemon" --daemon > /dev/null 2>&1 &	# it logs every client connection
n=0
until [[ -S /nix/var/nix/daemon-socket/socket ]] || (( n++ > 20 )); do sleep 1; done
log "nix-daemon $(pgrep -x nix-daemon | head -1)"
while :; do
	log "builder start"
	su "$ZONE_USER" -c "exec /usr/bin/ksh93 $ZONE_RUN" >> "/var/log/zone-builder.log" 2>&1
	log "builder exited rc=$?"
	sleep 60
done
