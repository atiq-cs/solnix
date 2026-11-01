#!/usr/bin/ksh93
# solnix-swarm-probe -- is the BitTorrent swarm usable from here? (seed.nix). Every SWARM_TICK (600) s, and at start:
# `solnix-torrent probe <torrent>` announces once for a NAR the hub seeds and passes only if the tracker lists a seed
# and a PUBLIC peer (an RFC1918/loopback-only list -- tracker.solnix.io behind its ingress lists 10.42.0.158 for every
# peer, 2026-10-29 -- is a swarm nobody can reach). Pass: touch <proxy-state>/swarm/ok; fail: delete it. The cache
# proxy tries the swarm only while swarm/ok is fresh, so a broken tracker costs a NAR nothing.
#   solnix-swarm-probe once      one probe (the unit test drives this)
PATH=${SWARM_PATH:-/usr/bin}
: ${SWARM_STATE:=/var/lib/solnix/cache-proxy/swarm} ${SWARM_TICK:=600}
# The probe torrent comes from a served narinfo's Torrent: line, never a hard-coded file name: the hub regenerates torrents
# (all 6,583 were replaced on 2026-10-29 and regenerate over hours; the old names 404). SWARM_NARINFOS: long-lived paths
# the hub serves (jq, cacert, libc, rust-1.98); the first whose Torrent: object answers 200 is probed.
: ${SWARM_CACHE:=https://cache.solnix.io}
: ${SWARM_NARINFOS:="1fjqlkii7xmvhqrbryx59n7gbv46c3j5 6564dbcis6q16fl4zpsrvgfrd5z8rdm2 86qg1hqv9nk9s5s2g1bwdkp9fg7nhfyj 0y8vzswdz5r22n2bqk7l173snzlhskfm"}
torrent_url() {
	[[ -n $SWARM_TORRENT ]] && { print -r -- "$SWARM_TORRENT"; return; }
	typeset h t
	for h in $SWARM_NARINFOS; do
		t=$(curl -sf -m 10 "$SWARM_CACHE/$h.narinfo" | sed -n 's/^Torrent: *//p')
		[[ -n $t ]] && curl -sfI -m 10 -o /dev/null "$SWARM_CACHE/$t" && { print -r -- "$SWARM_CACHE/$t"; return; }
	done
}
once() {
	typeset r u; u=$(torrent_url)
	if [[ -z $u ]]; then r="down: no served torrent for any of $SWARM_NARINFOS"; false
	else r=$(solnix-torrent probe "$u" 2>&1); fi
	if [[ $? == 0 ]]; then : > "$SWARM_STATE/ok"; else rm -f "$SWARM_STATE/ok"; fi
	printf '%(%Y-%m-%dT%H:%M:%SZ)T swarm-probe: %s\n' now "$r"
}
[[ $1 == once ]] && { once; exit; }
while :; do once; sleep "$SWARM_TICK"; done
