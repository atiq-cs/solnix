#!/usr/bin/bash
# oi-nix-through-proxy.sh: nix substitutes jq (+ libc, gcc-lib) through solnix-cache-proxy under real inetd, into a
# throwaway chroot store, and nix's signature check is shown to be what gates it:
#   A. clean: substitute via the proxy only (cache.solnix.io NOT listed) -> ok, and the proxy log shows the narinfos
#   B. NEG tampered narinfo (proxy's upstream = a local tamper server that flips one Sig byte) -> nix refuses
#   C. NEG tampered NAR (the torrent fetcher hands back a NAR with one byte changed) -> nix refuses (hash mismatch)
#   D. NEG no trusted key -> nix refuses (no signature by a trusted key)
# Run as root on the OI build host after oi-proxy-up.sh. Each case uses a fresh store under /var/tmp/community1/st.
set -u
. /etc/profile.d/nix-illumos.sh
D=/var/tmp/community1; P=/nix/store/n9aq9aa2bmg6jf7544r69p2zmipfqkaw-jq-1.7.1
K=cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8=
run() { # run <label> <trusted-key> -> nix copy rc, stderr tail
  st=$D/st/$1; [ -d $st ] && find $st -depth -exec chmod u+w {} + -delete 2>/dev/null; mkdir -p $st
  XDG_CACHE_HOME=$D/xdg-$1 nix copy --from http://127.0.0.1:37515 --to "local?root=$st" \
    --option trusted-public-keys "$2" --option substituters "" $P > $D/$1.log 2>&1; rc=$?
  find $D/xdg-$1 -depth -delete 2>/dev/null
  echo "$1 rc=$rc $(tail -2 $D/$1.log | tr '\n' ' ' | cut -c1-260)"
  [ -e $st$P/bin/jq ] && echo "$1 HAS $P/bin/jq" || echo "$1 no jq in store"
}
env1() { svccfg -s site/solnix-cache-proxy:default setenv -m inetd_start "$1" "$2"; svcadm refresh site/solnix-cache-proxy; sleep 1; }
unenv() { for v in PROXY_UPSTREAM PROXY_TORRENT_FETCH; do svccfg -s site/solnix-cache-proxy:default unsetenv -m inetd_start $v 2>/dev/null; done; svcadm refresh site/solnix-cache-proxy; sleep 1; }
tamper() { for p in $(pgrep -f tamper-upstream.py); do kill $p; done; [ -n "$1" ] && { (nohup python3 $D/tamper-upstream.py 37599 $1 >$D/tamper.log 2>&1 &); sleep 2; }; }
unenv; tamper ""
echo "== A clean, via the proxy only"; run A "$K"; [ -s /tmp/c1-honest.ran ] && echo "A ERROR stale fetcher log"
echo "== B NEG tampered Sig in the narinfo"; tamper sig; env1 PROXY_UPSTREAM http://127.0.0.1:37599; run B "$K"; unenv; tamper ""
echo "== C NEG tampered NAR bytes (served as if from the swarm)"
tamper nar; printf '#!/bin/sh\ncurl -sS -m 30 -o "$2" http://127.0.0.1:37599/nar/0j3jx0gqnxg2n78s0v7nsl2v8ahyrk1vkjcbhss80v663spi4bwa.nar.xz\n' > $D/f-tamper; chmod 755 $D/f-tamper
curl -sS -m 30 -o $D/tampered.nar http://127.0.0.1:37599/nar/0j3jx0gqnxg2n78s0v7nsl2v8ahyrk1vkjcbhss80v663spi4bwa.nar.xz
xz -t $D/tampered.nar && echo "C fixture is valid xz"; echo "C fixture: tampered NAR $(wc -c < $D/tampered.nar) bytes, sha256 $(digest -a sha256 $D/tampered.nar) (real: 8a2f12af...)"
env1 PROXY_TORRENT_FETCH $D/f-tamper; run C "$K"; unenv; tamper ""
echo "== D NEG not a trusted key"; run D "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
rm -f /tmp/c1-honest.ran; echo "== C2 control: an honest fetcher (the real NAR from cache.solnix.io) via the same torrent path"
# the honest fixture fetches the NAR named by the torrent URL it is given (torrent/<f>.torrent -> nar/<f>), as a real swarm would
printf '#!/bin/sh\nf=${1##*/}; f=${f%%.torrent}; curl -sS -m 30 -o "$2" "https://cache.solnix.io/nar/$f" && echo "$f" >> /tmp/c1-honest.ran\n' > $D/f-honest; chmod 755 $D/f-honest
env1 PROXY_TORRENT_FETCH $D/f-honest; run C2 "$K"; [ -e /tmp/c1-honest.ran ] && echo "C2 the torrent path served: $(tr '\n' ' ' < /tmp/c1-honest.ran)" || echo "C2 torrent path NOT used"; unenv
echo "== A2 clean again"; run A2 "$K"
