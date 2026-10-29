#!/usr/bin/ksh93
# test-cache-proxy.sh -- solnix-cache-proxy's request handling on illumos, one request at a time on stdin (as inetd
# runs it), against the live cache.solnix.io. No listener is opened. Cases: cache-info priority, narinfo relay and
# its Torrent: line recorded, a NAR with no fetcher -> 302 to upstream (HTTP fallback), a fetcher that fails ->
# 302, a fetcher that works -> its bytes, bad paths/methods -> 404/405. The swarm gate: no fresh swarm/ok (the probe
# found no reachable swarm) -> the fetcher is NOT run, straight 302; a failed fetch deletes swarm/ok.
S=${1:-$(dirname "$0")/../modules/config/community/solnix-cache-proxy.sh}
W=$(mktemp -d /tmp/cp.XXXXXX); trap 'find "$W" -depth -delete' EXIT; mkdir -p "$W/tmp" "$W/seen" "$W/swarm"
export PROXY_STATE=$W PROXY_PATH=${PROXY_PATH:-$PATH}
bad=0; ok() { print "ok: $1"; }; no() { print "FAIL: $1"; bad=1; }
# req <method> <path> [fetcher]: the fetcher goes through env(1) (ksh93 does not export a prefix assignment made
# before a POSIX function to its children, which made an earlier version of this test vacuous)
req() { printf '%s %s HTTP/1.0\r\nHost: x\r\n\r\n' "$1" "$2" | env PROXY_TORRENT_FETCH="${3:-}" ksh93 "$S"; }
H=n9aq9aa2bmg6jf7544r69p2zmipfqkaw N=0j3jx0gqnxg2n78s0v7nsl2v8ahyrk1vkjcbhss80v663spi4bwa.nar.xz
r=$(req GET /nix-cache-info); [[ $r == "HTTP/1.0 200 OK"* && $r == *"Priority: 30"* ]] && ok "nix-cache-info Priority 30" || no "cache-info: $r"
r=$(req GET /$H.narinfo); [[ $r == "HTTP/1.0 200 OK"* && $r == *"StorePath: /nix/store/$H-jq-1.7.1"* && $r == *"Sig: cache.solnix.io-1:"* ]] && ok "narinfo relayed" || no "narinfo: ${r:0:200}"
[[ $(sed -n 1p "$W/seen/$N") == torrent/$N.torrent && $(sed -n 2p "$W/seen/$N") == /nix/store/$H-jq-1.7.1 ]] && ok "Torrent: line + StorePath recorded for $N" || no "seen: $(ls "$W/seen")"
r=$(req HEAD /$H.narinfo); [[ $r == "HTTP/1.0 200 OK"* && $r != *StorePath* ]] && ok "HEAD has no body" || no "HEAD: $r"
r=$(req GET /00000000000000000000000000000000.narinfo); [[ $r == "HTTP/1.0 404"* ]] && ok "absent narinfo 404" || no "404: $r"
r=$(req GET /nar/$N); [[ $r == "HTTP/1.0 302"* && $r == *"Location: https://cache.solnix.io/nar/$N"* ]] && ok "no fetcher: 302 to upstream" || no "fallback: $r"
print '#!/bin/sh\n: > "$PROXY_STATE/f-bad.ran"; exit 1' > "$W/f-bad"; print '#!/bin/sh\necho "$1 $3" > "$PROXY_STATE/fetch-args"; printf SWARMBYTES > "$2"' > "$W/f-ok"; chmod +x "$W/f-"*
r=$(req GET /nar/$N $W/f-ok); [[ $r == "HTTP/1.0 302"* && ! -e $W/fetch-args ]] && ok "NEG no swarm/ok: fetcher not run, 302" || no "no-swarm: $r"
touch -t 202001010000 "$W/swarm/ok"; r=$(req GET /nar/$N $W/f-ok); [[ $r == "HTTP/1.0 302"* && ! -e $W/fetch-args ]] && ok "NEG stale swarm/ok: fetcher not run, 302" || no "stale: $r"
: > "$W/swarm/ok"
r=$(req GET /nar/$N $W/f-bad); [[ $r == "HTTP/1.0 302"* && -e $W/f-bad.ran && ! -e $W/swarm/ok ]] && ok "fetcher fails (it ran): 302, swarm/ok dropped" || no "bad fetcher: $r"
rm -f "$W/f-bad.ran"; r=$(req GET /nar/$N $W/f-bad); [[ $r == "HTTP/1.0 302"* && ! -e $W/f-bad.ran ]] && ok "after a failure the next NAR skips the swarm" || no "after-fail: $r"
: > "$W/swarm/ok"
r=$(req GET /nar/$N $W/f-ok); [[ $r == "HTTP/1.0 200 OK"* && $r == *SWARMBYTES ]] && ok "fetcher ok: its bytes served" || no "ok fetcher: $r"
[[ $(cat "$W/fetch-args") == "https://cache.solnix.io/torrent/$N.torrent 60" ]] && ok "fetcher got the narinfo's Torrent: URL (read, not derived)" || no "args: $(cat "$W/fetch-args")"
r=$(req GET /nar/1111111111111111111111111111111111111111111111111111.nar.xz $W/f-ok); [[ $r == "HTTP/1.0 302"* ]] && ok "NEG no narinfo seen: no torrent, 302" || no "unseen: $r"
r=$(req GET /../../etc/passwd); [[ $r == "HTTP/1.0 404"* ]] && ok "traversal 404" || no "traversal: $r"
r=$(req POST /nix-cache-info); [[ $r == "HTTP/1.0 405"* ]] && ok "POST 405" || no "POST: $r"
[[ -z $(ls "$W/tmp") ]] && ok "no temp files left" || no "tmp left: $(ls "$W/tmp")"
exit $bad
