#!/usr/bin/bash
# test-swarm.sh <solnix-torrent> -- the BitTorrent client on illumos against a LOCAL tracker (scripts/bt-test-peer.py):
#   A  seed + fetch of jq's served NAR, byte-identical to cache.solnix.io's
#   B0 control: a non-libtorrent peer serving the honest bytes -> the fetch completes, identical
#   B  NEG the same peer with one byte flipped -> the FETCHER's piece-hash check rejects it: rc 1, no output file,
#      the failed-hash bytes reported (only the fetcher stands between those bytes and the proxy)
#   C  NEG no seeder -> fetch gives up by the stall cut-off (10 s), not the 60 s window
#   D  probe: tracker listing only 127.0.0.1 peers -> down (rc 1); listing a public address -> ok (rc 0); no tracker -> down
# Needs python3, curl, and the network to cache.solnix.io. Runs in a temp dir; leaves nothing.
T=${1:?usage: test-swarm.sh <solnix-torrent>}; P=$(cd "$(dirname "$0")" && pwd)/bt-test-peer.py
W=$(mktemp -d /var/tmp/swarm.XXXXXX); cd "$W" || exit 1; bad=0
ok() { echo "ok: $1"; }; no() { echo "FAIL: $1"; bad=1; }
pids=""; bg() { "$@" & pids="$pids $!"; }
stop() { for p in $pids; do kill $p 2>/dev/null; done; pids=""; sleep 1; }
trap 'stop; cd /; find "$W" -depth -delete' EXIT
N=0j3jx0gqnxg2n78s0v7nsl2v8ahyrk1vkjcbhss80v663spi4bwa.nar.xz; mkdir nars
curl -sS -m 60 -f -o tor.torrent https://cache.solnix.io/torrent/$N.torrent && curl -sS -m 60 -f -o nars/$N https://cache.solnix.io/nar/$N || { echo "FAIL: no fixtures"; exit 1; }
IH=$("$T" infohash nars/$N); echo "infohash $IH ($(wc -c < nars/$N) bytes)"
export SOLNIX_TORRENT_TRACKER=http://127.0.0.1:36969/announce
bg python3 "$P" tracker 36969; sleep 1
echo "== A seed + fetch"
bg env SOLNIX_TORRENT_LISTEN=127.0.0.1:36881 "$T" seed nars $N; sleep 3
SOLNIX_TORRENT_LISTEN=127.0.0.1:36891 "$T" fetch tor.torrent a.nar 30; rc=$?
[ $rc = 0 ] && cmp -s a.nar nars/$N && ok "A seed+fetch identical to the cache's NAR ($(wc -c < a.nar) B)" || no "A rc=$rc"
stop; bg python3 "$P" tracker 36969; sleep 1
for c in B0 B; do
  echo "== $c $([ $c = B ] && echo 'NEG tampered pieces' || echo 'control: honest bytes, same liar peer')"
  off=""; [ $c = B ] && off=100000
  bg python3 "$P" liar 127.0.0.1 36892 $IH nars/$N $off
  SOLNIX_TORRENT_LISTEN=127.0.0.1:36892 "$T" fetch tor.torrent $c.nar 30 2> $c.err; rc=$?; stop; cat $c.err
  if [ $c = B0 ]; then [ $rc = 0 ] && cmp -s B0.nar nars/$N && ok "B0 the liar peer, honest: fetch completes, identical" || no "B0 rc=$rc"
  else [ $rc = 1 ] && [ ! -e B.nar ] && [ ! -e B.nar.d ] && grep -q '[1-9][0-9]* B failed the piece hash' B.err \
       && ok "B NEG tampered piece rejected by the fetcher's hash check (rc 1, no output)" || no "B rc=$rc $(ls)"; fi
  bg python3 "$P" tracker 36969; sleep 1
done
echo "== C NEG no seeder"; s=$(date +%s); SOLNIX_TORRENT_LISTEN=127.0.0.1:36893 "$T" fetch tor.torrent c.nar 60; rc=$?; d=$(( $(date +%s) - s ))
[ $rc = 1 ] && [ $d -le 15 ] && ok "C no seeder: rc 1 after $d s (stall cut-off, window 60)" || no "C rc=$rc in $d s"
stop
echo "== D probe"; bg python3 "$P" tracker 36969; sleep 1; bg env SOLNIX_TORRENT_LISTEN=127.0.0.1:36881 "$T" seed nars $N; sleep 3
r=$("$T" probe tor.torrent); rc=$?; [ $rc = 1 ] && ok "D probe, only 127.0.0.1 peers: $r" || no "D private rc=$rc $r"
stop; bg python3 "$P" tracker 36969 192.0.2.7; sleep 1; bg env SOLNIX_TORRENT_LISTEN=127.0.0.1:36881 "$T" seed nars $N; sleep 3
r=$("$T" probe tor.torrent); rc=$?; [ $rc = 0 ] && ok "D probe, a public peer: $r" || no "D public rc=$rc $r"
stop; r=$("$T" probe tor.torrent); rc=$?; [ $rc = 1 ] && ok "D probe, no tracker: $r" || no "D none rc=$rc $r"
exit $bad
