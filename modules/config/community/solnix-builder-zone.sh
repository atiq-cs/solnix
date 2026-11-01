#!/usr/bin/ksh93
# solnix-builder-zone.sh -- the global zone's side of the isolated queue builder (builder-zone.nix): SMF
# site/solnix-builder-zone runs `start` and `stop`.  The zone holds the builder AND its own nix-daemon and store
# (on illumos, sandbox = false runs build code in the daemon's zone, so a zone around the client alone isolates nothing).
# start: (1) refuse unless ipfilter is online with this zone's rules loaded (fail closed: no filter, no zone);
#        (2) the links: etherstub, a GZ vnic with the gateway address, the zone's vnic; forwarding on that vnic and the
#            uplinks; (3) zonecfg from the rendered command file; (4) install when the zone is missing or was laid
#            from another generation (stamp), a fresh root each time; (5) the bearer into the read-only secrets dir;
#        (6) boot.
# stop: halt the zone (its links go with it; the GZ vnic stays for the next start).
set -o pipefail
. "$1" || exit 1	# ZONE_NAME ZONE_PATH ZONE_DATASET ZONE_QUOTA ZONE_CFG ZONE_SPEC ZONE_STUB ZONE_GZLINK ZONE_LINK ZONE_GW ZONE_PREFIX
#                 ZONE_UPLINKS ZONE_UID ZONE_BEARER_SRC ZONE_SECRETS
export PATH=/usr/sbin:/usr/bin:/sbin
log() { print -r -- "solnix-builder-zone: $*"; }
die() { log "FATAL: $*"; exit 95; }	# SMF_EXIT_ERR_FATAL: maintenance, no restart loop
state() { zoneadm -z "$ZONE_NAME" list -p 2> /dev/null | cut -d: -f3; }

start() {
	[[ $(svcs -H -o state network/ipfilter:default) == online ]] || die "svc:/network/ipfilter is not online: not starting an unfiltered zone"
	ipfstat -i | grep -q "on $ZONE_GZLINK " || die "ipf has no rules on $ZONE_GZLINK (solnix.firewall.extraRules not loaded)"
	ipnat -l | grep -q "${ZONE_GW%.*}" || die "ipnat has no map for the zone's subnet"
	dladm show-etherstub "$ZONE_STUB" > /dev/null 2>&1 || dladm create-etherstub -t "$ZONE_STUB" || die "etherstub"
	dladm show-vnic "$ZONE_GZLINK" > /dev/null 2>&1 || dladm create-vnic -t -l "$ZONE_STUB" "$ZONE_GZLINK" || die "vnic $ZONE_GZLINK"
	dladm show-vnic "$ZONE_LINK" > /dev/null 2>&1 || dladm create-vnic -t -l "$ZONE_STUB" "$ZONE_LINK" || die "vnic $ZONE_LINK"
	# IPv4 only, by ifconfig: ipadm create-if would plumb IPv6 too, a link-local path to every GZ v6 listener
	ifconfig "$ZONE_GZLINK" > /dev/null 2>&1 || ifconfig "$ZONE_GZLINK" plumb || die "plumb $ZONE_GZLINK"
	ifconfig "$ZONE_GZLINK" "$ZONE_GW/$ZONE_PREFIX" up || die "address $ZONE_GZLINK"
	ipf -y	# bind the loaded rules that name the new interface
	# forwarding per interface (IFF_ROUTER, ip_input.c checks the ingress ill), not routeadm's global switch
	for l in "$ZONE_GZLINK" $ZONE_UPLINKS; do ifconfig "$l" router || die "forwarding on $l"; done
	# the read-only secrets dir (lofs special): must exist before zonecfg verifies the zone
	mkdir -p "$ZONE_SECRETS" && chown "$ZONE_UID" "$ZONE_SECRETS" && chmod 0500 "$ZONE_SECRETS" || die "secrets dir"
	# zonecfg and the root are the generation's (stamp = the install spec + the zonecfg file, both store paths). zonecfg
	# refuses to re-create an installed zone, so any change re-lays everything. shortcut: a generation change re-copies the
	# whole root (about 1.6 GiB from the local store) and drops the zone's store cache; the builder state is rebuilt from the queue.
	stamp="$ZONE_SPEC $ZONE_CFG"
	if [[ $(state) != @(installed|ready|running) || $(cat "$ZONE_PATH/solnix-stamp" 2> /dev/null) != "$stamp" ]]; then
		[[ $(state) == @(ready|running) ]] && { zoneadm -z "$ZONE_NAME" halt || die "halt"; }
		# a wiped data pool (EC2 stop/start) leaves an "installed" zone with no root: uninstall fails, so mark it
		[[ $(state) == @(installed|incomplete) ]] && { zoneadm -z "$ZONE_NAME" uninstall -F || zoneadm -z "$ZONE_NAME" mark -F configured || die "uninstall"; }
		[[ -n $(state) ]] && { zonecfg -z "$ZONE_NAME" delete -F || die "zonecfg delete"; }
		# uninstall may destroy the zonepath dataset; without one, install would lay the root under the BE's /var/lib
		zfs list -H -o name "$ZONE_DATASET" > /dev/null 2>&1 ||
		    zfs create -p -o mountpoint="$ZONE_PATH" -o quota="$ZONE_QUOTA" -o sharenfs=off -o sharesmb=off "$ZONE_DATASET" || die "dataset $ZONE_DATASET"
		rm -f "$ZONE_PATH/solnix-stamp" "$ZONE_PATH/nix-copy.log" "$ZONE_PATH/missing"
		chmod 0700 "$ZONE_PATH" || die "chmod $ZONE_PATH"
		zonecfg -z "$ZONE_NAME" -f "$ZONE_CFG" || die "zonecfg"
		zoneadm -z "$ZONE_NAME" install || die "install (zonepath $ZONE_PATH, log $ZONE_PATH/nix-copy.log)"
		print -r -- "$stamp" > "$ZONE_PATH/solnix-stamp"
	fi
	# the bearer: a COPY the zone reads (lofs ro), owned by the zone user; the GZ original stays 0600 root
	if [[ -s $ZONE_BEARER_SRC ]]; then
		(umask 077; cp "$ZONE_BEARER_SRC" "$ZONE_SECRETS/.b.$$") && chown "$ZONE_UID" "$ZONE_SECRETS/.b.$$" && chmod 0400 "$ZONE_SECRETS/.b.$$" &&
		    mv -f "$ZONE_SECRETS/.b.$$" "$ZONE_SECRETS/build-queue-bearer" || die "bearer"
	else
		rm -f "$ZONE_SECRETS/build-queue-bearer"; log "no $ZONE_BEARER_SRC: the zone's builder runs dry"
	fi
	[[ $(state) == running ]] || zoneadm -z "$ZONE_NAME" boot || die "boot"
	log "$ZONE_NAME $(state)"
}
case $2 in
start) start ;;
stop) [[ $(state) == running || $(state) == ready ]] && zoneadm -z "$ZONE_NAME" halt; exit 0 ;;
*) print -u2 "usage: $0 <env> start|stop"; exit 2 ;;
esac
