#!/usr/bin/ksh93
# test-seed.sh -- solnix-seed's gate and list on illumos (nix, curl, the live cache.solnix.io). No torrent is started:
# solnix-torrent is replaced by a recorder. Cases: a served 8UNr path is admitted and its NAR checked against FileHash;
# NEG a local-only path (built here, never published) is refused; NEG a served path under a WRONG trusted key is refused;
# NEG a path this host does not have is not seeded; solnix-announce queues $OUT_PATHS.
S=${1:-$(dirname "$0")/../modules/config/community/solnix-seed.sh}; A=${S%/*}/solnix-announce.sh
W=$(mktemp -d /var/tmp/seedt.XXXXXX); trap 'find "$W" -depth -exec chmod u+w {} + -delete 2>/dev/null' EXIT
bad=0; ok() { print "ok: $1"; }; no() { print "FAIL: $1"; bad=1; }
export SEED_STATE=$W/st SEED_PROXY_STATE=$W/px SEED_PATH=$W/bin:$PATH; mkdir -p "$W/bin" "$W/px/seen" "$W/st/xdg"
print '#!/bin/sh\nshift 2; echo "$@" > '"$W"'/seeded; sleep 600' > "$W/bin/solnix-torrent"; chmod +x "$W/bin/solnix-torrent"
JQ=/nix/store/1fjqlkii7xmvhqrbryx59n7gbv46c3j5-jq-1.7.1 N=0viha7fnif18a3cnwhb9ypn786w452ri6srrmgyplhig4ssjbink.nar.xz
f=$(ksh93 "$S" gate $JQ) && [[ $f == "$N" ]] && ok "served 8UNr path admitted, NAR $f" || no "gate served: '$f'"
L=$(print solnix-seed-test-$$ > "$W/f" && nix store add-file "$W/f" 2>/dev/null)
[[ -n $L ]] && ! ksh93 "$S" gate "$L" >/dev/null && ok "NEG local-only $L refused" || no "local-only: '$L'"
SEED_KEY=cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= ksh93 "$S" gate $JQ >/dev/null && no "NEG wrong key admitted" || ok "NEG served path, untrusted key: refused"
ksh93 "$S" gate /nix/store/../etc/passwd >/dev/null && no "NEG bad path admitted" || ok "NEG malformed path refused"
OUT_PATHS="$L /etc/passwd $JQ" SEED_STATE=$W/st sh "$A"; [[ $(ls "$W/st/built" | sort | tr '\n' ' ') == "$(basename $JQ) $(basename $L) " ]] && ok "announce queued the two store paths" || no "announce: $(ls "$W/st/built")"
printf 'torrent/x\n/nix/store/00000000000000000000000000000000-absent\n' > "$W/px/seen/x.nar.xz"
if [[ -e $JQ ]]; then
	out=$(ksh93 "$S" once 2>&1); sleep 1; s=$(cat "$W/seeded" 2>/dev/null)
	[[ $s == "$N" ]] && ok "once: seeds exactly the served path ($s)" || no "once seeded '$s': $out"
	print -r -- "$out" | grep -q "not seeding $L" && ok "once: logged the local-only refusal" || no "once log: $out"
	[[ $(nix hash file --type sha256 --base32 "$W/st/nars/$N") == $(curl -sS -m 10 https://cache.solnix.io/${JQ:11:32}.narinfo | sed -n 's/^FileHash: sha256://p') ]] && ok "the seeded NAR matches the signed FileHash" || no "nar hash"
	kill $(cat "$W/st/pid") 2>/dev/null
else print "skip: $JQ not on this host (the once case needs it)"; fi
nix store delete "$L" >/dev/null 2>&1
exit $bad
