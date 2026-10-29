#!/usr/bin/ksh93
# solnix-swarm-probe -- is the BitTorrent swarm usable from here? (seed.nix). Every SWARM_TICK (600) s, and at start:
# `solnix-torrent probe <torrent>` announces once for a NAR the hub seeds and passes only if the tracker lists a seed
# and a PUBLIC peer (an RFC1918/loopback-only list -- tracker.solnix.io behind its ingress lists 10.42.0.158 for every
# peer, 2026-10-29 -- is a swarm nobody can reach). Pass: touch <proxy-state>/swarm/ok; fail: delete it. The cache
# proxy tries the swarm only while swarm/ok is fresh, so a broken tracker costs a NAR nothing.
#   solnix-swarm-probe once      one probe (the unit test drives this)
PATH=${SWARM_PATH:-/usr/bin}
: ${SWARM_STATE:=/var/lib/solnix/cache-proxy/swarm} ${SWARM_TICK:=600}
: ${SWARM_TORRENT:=https://cache.solnix.io/torrent/0j3jx0gqnxg2n78s0v7nsl2v8ahyrk1vkjcbhss80v663spi4bwa.nar.xz.torrent}
once() {
	typeset r; r=$(solnix-torrent probe "$SWARM_TORRENT" 2>&1)
	if [[ $? == 0 ]]; then : > "$SWARM_STATE/ok"; else rm -f "$SWARM_STATE/ok"; fi
	printf '%(%Y-%m-%dT%H:%M:%SZ)T swarm-probe: %s\n' now "$r"
}
[[ $1 == once ]] && { once; exit; }
while :; do once; sleep "$SWARM_TICK"; done
