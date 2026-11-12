#!/usr/bin/ksh93
# solnix-netd -- solnix's analog of NixOS's dhcpcd (modules/config/solnix-netd.nix).
# One SMF-supervised loop (contract model). On every routing-socket message (route -n
# monitor) and every NETD_TICK seconds it:
#  - runs DHCP on each managed link that is up, as links come and go (a new usbecmN);
#  - keeps each configured wifi link associated (its join script, with backoff);
#  - prefers wired: a wifi default route exists only while no wired one does. dhcpcd
#    does this with metrics (200+ifindex wired, 300+ifindex wireless); illumos has no
#    route metrics and round-robins equal defaults, so the losing route is removed;
#  - probes each wired default gateway: after NETD_MISS misses its default route is
#    removed, after NETD_OK answers it is put back.
# Config comes from the SMF method environment (see the module).
PATH=/usr/sbin:/usr/bin:/sbin
: ${NETD_TICK:=3} ${NETD_MISS:=3} ${NETD_OK:=5} ${NETD_DHCP_ALL:=0} ${NETD_RESOLV:=0}
typeset -A media state wjoin wst wpid wnext wback seen miss okc dgw fdef armed pnext dpid
log() { printf '%(%Y-%m-%dT%H:%M:%S)T %s\n' now "$*"; }
[ -n "$NETD_TRACE" ] && { exec 2>>"$NETD_TRACE"; PS4='+${SECONDS%.*} '; set -x; }	# a test aid: timed xtrace
for w in $NETD_WIFI; do wjoin[${w%%=*}]=${w#*=}; done

scan_links() {	# media[] and state[] of every datalink
	unset media state; typeset -A media state
	dladm show-phys -p -o link,media,state 2>/dev/null |
	    while IFS=: read l m s; do media[$l]=$m state[$l]=$s; done
}

managed() {	# is DHCP on link $1 ours to run?
	case " $NETD_SKIP_LINKS " in *" $1 "*) return 1;; esac
	[ -n "${wjoin[$1]}" ] && return 0
	case " $NETD_DHCP_LINKS " in *" $1 "*) return 0;; esac
	[ "$NETD_DHCP_ALL" = 1 ] && [ "${media[$1]}" = Ethernet ]
}

# an address that is not disabled (RCM leaves "usbecm1/dhcp disabled" after a forced detach)
hasaddr() { ipadm show-addr -p -o addrobj,state "$1/" 2>/dev/null | grep -v ':disabled$' | grep -q .; }

ensure_dhcp() {	# $1 link: an IPv4 DHCP address, unless it has an address already
	hasaddr "$1" && return
	[ -n "${dpid[$1]}" ] && kill -0 "${dpid[$1]}" 2>/dev/null && return	# a create-addr in flight
	# a link that appeared after network/physical keeps its persistent config disabled
	ipadm enable-if -t "$1" 2>/dev/null
	hasaddr "$1" && { log "$1: enabled its persistent ipadm config"; return; }
	log "$1: up with no address: DHCP"
	ipadm create-if -t "$1" 2>/dev/null
	ipadm create-addr -t -T dhcp -w 30 "$1/dhcp" 2>&1 | while read -r x; do log "$1: $x"; done &
	dpid[$1]=$!
}

wifi_keep() {	# $1 link: rejoin while disconnected, backoff 10 s doubling to 5 min
	wst[$1]=$(dladm show-wifi -p -o status "$1" 2>/dev/null)
	if [ "${wst[$1]}" = connected ]; then
		[ "${wback[$1]:-0}" = 0 ] || log "$1: associated"
		wback[$1]=0 wnext[$1]=0; return
	fi
	[ -n "${wpid[$1]}" ] && kill -0 "${wpid[$1]}" 2>/dev/null && return
	# solnix-nm (services.solnix-nm) holds a link it disconnected, or is joining itself
	[ -n "$NETD_HOLD_DIR" ] && [ -e "$NETD_HOLD_DIR/$1.down" ] && return
	(( SECONDS < ${wnext[$1]:-0} )) && return
	log "$1: ${wst[$1]:-absent}: joining"
	/bin/sh "${wjoin[$1]}" 2>&1 | while read -r x; do log "$1: $x"; done &
	wpid[$1]=$!
	b=${wback[$1]:-0}; (( b = b == 0 ? 10 : (b >= 150 ? 300 : b * 2) ))
	wback[$1]=$b; (( wnext[$1] = SECONDS + b ))
}

wifi_gw() {	# $1 link: its lease's router. dhcpinfo hides option 3 when the link's
	# PARAM_IGNORE_LIST has it (agent.c), so read the ACK dhcpagent saved in
	# /etc/dhcp/<link>.dhc: magic, time_t, length, then the packet.
	dhcpinfo -i "$1" Router 2>/dev/null | awk '{print $1; exit}' | grep . && return
	od -A n -t u1 -v "/etc/dhcp/$1.dhc" 2>/dev/null | awk '
	    { for (i = 1; i <= NF; i++) b[n++] = $i + 0 }	# od pads ("001"); route reads that as octal
	    END { p = (b[248] == 99 && b[249] == 130) ? 12 : 16	# 32- or 64-bit dhcpagent
		for (i = p + 240; i < n && b[i] != 255; ) {
			if (b[i] == 0) { i++; continue }
			if (b[i] == 3) { print b[i+2] "." b[i+3] "." b[i+4] "." b[i+5]; exit }
			i += 2 + b[i+1] } }'
}

# a bound lease: until dhcpagent binds, the addrobj is already "ok" with ADDR "?" (0.0.0.0, ipadm.c print_sa_cb), and a
# route via the last lease's router (the saved .dhc) fails "Network is unreachable" (lixi's log, every boot 10-28..11-11)
leased() { ipadm show-addr -p -o type,state,addr "$1/" 2>/dev/null | grep -q '^dhcp:ok:[0-9][0-9]*\.'; }
online() {	# once: NETD_ONLINE when there is a default route and an IPv4 address off lo0. The start method waits for it,
	# so svc:/site/solnix-netd goes online with the network, as dhcpcd's wait=any forks (smf.networkOnline names netd).
	# Any default counts (netstat leaves Interface empty for one added without -ifp, as a static defaultGateway is).
	[ -n "$NETD_ONLINE" ] && [ -z "$onl" ] || return 0
	ogw=$(netstat -rn -f inet 2>/dev/null | awk '$1 == "default" { print $2; exit }')
	oad=$(ipadm show-addr -p -o addrobj,state,addr 2>/dev/null | grep -v '^lo0/' | grep ':ok:[0-9][0-9]*\.' | sed -n 1p)
	[ -n "$ogw" ] && [ -n "$oad" ] && : > "$NETD_ONLINE" || return 0
	onl=1; log "online: default via $ogw, $oad"
}
rt() {	# NETD_DRY=1 logs the route change instead of making it (a test aid)
	[ "${NETD_DRY:-0}" = 1 ] && { log "dry: route $*"; return; }
	route -n "$@" 2>&1 | while read -r x; do log "route $*: $x"; done
}

probe() {	# $1 wired link, $2 "alt" if another link could carry the default.
	# Demote its default after NETD_MISS straight misses, restore after NETD_OK straight answers.
	# Armed only once the gateway has answered (a gateway that ignores ICMP is never demoted),
	# and a demotion needs somewhere else to go (removing the only default gains nothing).
	g=$(dhcpinfo -i "$1" Router 2>/dev/null | awk '{print $1; exit}')
	[ -n "$g" ] || return
	if ping -i "$1" "$g" 2 >/dev/null 2>&1; then
		miss[$1]=0; (( okc[$1]++ )); armed[$1]=1
		if [ -n "${dgw[$1]}" ] && (( okc[$1] >= NETD_OK )); then
			log "$1: gateway $g answered ${okc[$1]} probes: default route restored"
			rt add default "$g" -ifp "$1"; unset dgw[$1]
		fi
	else
		okc[$1]=0; (( miss[$1]++ ))
		if [ -z "${dgw[$1]}" ] && [ -n "${armed[$1]}" ] && [ "$2" = alt ] && (( miss[$1] >= NETD_MISS )); then
			log "$1: gateway $g silent for ${miss[$1]} probes: default route demoted"
			dgw[$1]=$g
		fi
	fi
	# while demoted, keep it off even if dhcpagent re-adds it (a rebind)
	[ -n "${dgw[$1]}" ] && [ -n "${fdef[$1]}" ] && rt delete default "${fdef[$1]}" -ifp "$1"
}

resolv() {	# $1 link holding the default: its lease's DNS into /etc/resolv.conf
	ns=$(dhcpinfo -i "$1" DNSserv 2>/dev/null); [ -n "$ns" ] || return
	dom=$(dhcpinfo -i "$1" DNSdmain 2>/dev/null)
	new=$( [ -n "$dom" ] && echo "domain $dom"; for s in $ns; do echo "nameserver $s"; done )
	[ "$new" = "$(cat /etc/resolv.conf 2>/dev/null)" ] && return
	printf '%s\n' "$new" > /etc/resolv.conf.netd && mv -f /etc/resolv.conf.netd /etc/resolv.conf
	log "resolv.conf from $1: $(echo $ns)"
	svcadm refresh svc:/network/dns/client:default; svcadm enable svc:/network/dns/client:default
}

wireless() { [ -n "${wjoin[$1]}" ] || [ "${media[$1]}" = WiFi ]; }

apply() {
	scan_links
	for l in "${!state[@]}"; do
		[ "${state[$l]}" = up ] && managed "$l" && ensure_dhcp "$l"
		[ -n "${seen[$l]}" ] && [ "${seen[$l]}" != "${state[$l]}" ] && log "$l: link ${state[$l]}"
		seen[$l]=${state[$l]}
	done
	for l in "${!seen[@]}"; do [ -n "${state[$l]}" ] || { log "$l: link gone"; unset seen[$l] dgw[$l] armed[$l]; }; done
	for w in "${!wjoin[@]}"; do wifi_keep "$w"; done
	unset fdef; typeset -A fdef
	netstat -rn -f inet 2>/dev/null | awk '$1 == "default" { print $6, $2 }' |
	    while read -r i g; do fdef[$i]=$g; done
	wired="" alt=""
	for w in "${!state[@]}"; do wireless "$w" && [ "${state[$w]}" = up ] && leased "$w" && alt=alt; done
	for l in "${!state[@]}"; do
		wireless "$l" && continue
		if [ "${state[$l]}" != up ]; then
			unset dgw[$l]	# routes netd added are not dhcpagent's to remove
			managed "$l" && [ -n "${fdef[$l]}" ] && { log "$l: link down: default route removed"; rt delete default "${fdef[$l]}" -ifp "$l"; }
			continue
		fi
		leased "$l" && (( SECONDS >= ${pnext[$l]:-0} )) && { probe "$l" "$alt"; (( pnext[$l] = SECONDS + NETD_TICK )); }
		# a leased wired link that is not demoted has its lease's default (back after a netd restart mid-demotion)
		if [ -z "${fdef[$l]}" ] && [ -z "${dgw[$l]}" ] && managed "$l" && leased "$l"; then
			g=$(dhcpinfo -i "$l" Router 2>/dev/null | awk '{print $1; exit}')
			[ -n "$g" ] && { log "$l: leased, not demoted, no default: default route via $g"; rt add default "$g" -ifp "$l"; fdef[$l]=$g; }
		fi
		[ -n "${fdef[$l]}" ] && [ -z "${dgw[$l]}" ] && { wired="$wired $l"; alt=alt; }
	done
	for w in "${!state[@]}"; do
		wireless "$w" || continue
		if [ -n "$wired" ] || [ "${state[$w]}" != up ]; then
			[ -n "${fdef[$w]}" ] || continue
			log "$w: default route removed (wired:${wired:- none}, $w ${state[$w]})"
			rt delete default "${fdef[$w]}" -ifp "$w"
		elif [ -z "${fdef[$w]}" ] && leased "$w"; then
			g=$(wifi_gw "$w") && [ -n "$g" ] || continue
			log "$w: no wired default: default route via $g on $w"
			rt add default "$g" -ifp "$w"; fdef[$w]=$g
		fi
	done
	[ "$NETD_RESOLV" = 1 ] && for l in $wired "${!fdef[@]}"; do resolv "$l"; break; done
	online	# after resolv.conf
}

trap 'kill $mon 2>/dev/null; exit 0' TERM INT	# SMF stop (:kill) or a test run
# Strong host model while netd runs (temporary: a reboot or netd's absence is the stock weak). Under weak, with two
# links on one subnet, replies for the wired address left by wifi with the wifi MAC: 110 of 110 on lixi (strong: 0).
# Linux gets the same from dhcpcd's per-interface route metrics.
ipadm set-prop -t -p hostmodel="${NETD_HOSTMODEL:-strong}" ipv4
log "start: wifi=${!wjoin[*]} dhcp-links=$NETD_DHCP_LINKS all-wired=$NETD_DHCP_ALL skip=$NETD_SKIP_LINKS"
apply
while :; do
	route -n monitor 2>/dev/null |&
	mon=$!
	while kill -0 $mon 2>/dev/null; do
		# a routing-socket message (link, address or route change) or the tick
		# drain for at most 1 s: with no route, every packet sent is an RTM_MISS, and an unbounded
		# drain starved apply() for as long as the sender ran (55 s, measured on lixi)
		if read -t "$NETD_TICK" -p x; then
			(( e = SECONDS + 1 )); while (( SECONDS < e )) && read -t 0.3 -p x; do :; done
		fi
		apply
	done
	log "route monitor exited; restarting it"; sleep 1
done
