#!/usr/bin/ksh93
# solnix-seed -- seed over BitTorrent what this host fetched or built, if cache.solnix.io serves it signed by 8UNr
# (modules/config/community/seed.nix). Inputs: the cache proxy's record of fetched NARs (<proxy-state>/seen/<nar>) and
# solnix-announce's queue of built paths (<state>/built/). Every TICK it rebuilds the list:
#   for each candidate store path: nix path-info --store https://cache.solnix.io must verify under 8UNr (else: skip,
#   local-only), the narinfo's URL: names the NAR, and the NAR bytes come from cache.solnix.io and must match FileHash.
# then (re)starts `solnix-torrent seed <state>/nars <nar>...` when the list changed.
#   solnix-seed gate <store-path>     exit 0 iff the path may be seeded (the unit test drives this)
PATH=${SEED_PATH:-/usr/bin:/usr/sbin}
: ${SEED_STATE:=/var/lib/solnix/seed} ${SEED_PROXY_STATE:=/var/lib/solnix/cache-proxy} ${SEED_TICK:=1800}
: ${SEED_CACHE:=https://cache.solnix.io} ${SEED_KEY:=cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8=}
log() { printf '%(%Y-%m-%dT%H:%M:%SZ)T seed: %s\n' now "$*"; }
narinfo() { curl -sS -m 20 -f "$SEED_CACHE/${1:11:32}.narinfo" 2>/dev/null; }	# <store-path>
gate() {	# gate <store-path>: served, signed by the trusted key, and its NAR file named. Prints the NAR file name.
	[[ $1 == /nix/store/+([0-9a-df-np-sv-z])-* && ${#1} -gt 44 ]] || return 1
	XDG_CACHE_HOME=$SEED_STATE/xdg nix store verify --no-contents --store "$SEED_CACHE" --trusted-public-keys "$SEED_KEY" "$1" >/dev/null 2>&1 || return 1
	typeset u; u=$(narinfo "$1" | sed -n 's,^URL: nar/\([0-9a-z]*\.nar\.xz\)$,\1,p'); [[ -n $u ]] || return 1
	print -r -- "$u"
}
fetch_nar() {	# fetch_nar <store-path> <nar-file>: the NAR from the cache, checked against the signed FileHash
	typeset d=$SEED_STATE/nars; [[ -s $d/$2 ]] && return 0
	typeset want=$(narinfo "$1" | sed -n 's/^FileHash: sha256://p')
	curl -sS -m 600 -f -L -o "$d/$2.part" "$SEED_CACHE/nar/$2" || { rm -f "$d/$2.part"; return 1; }
	[[ $(nix hash file --type sha256 --base32 "$d/$2.part") == "$want" ]] || { log "FileHash mismatch on $2, dropped"; rm -f "$d/$2.part"; return 1; }
	mv "$d/$2.part" "$d/$2"
}
candidates() {	# store paths: built here (solnix-announce's built/<basename>) and fetched through the proxy (seen/<nar> line 2)
	ls "$SEED_STATE/built" 2>/dev/null | sed 's,^,/nix/store/,'
	for n in "$SEED_PROXY_STATE"/seen/*; do [[ -f $n ]] && sed -n 2p "$n"; done
}
tick() {
	mkdir -p "$SEED_STATE/nars" "$SEED_STATE/built" "$SEED_STATE/xdg"
	typeset p f list=""
	for p in $(candidates | sort -u); do
		[[ -e $p ]] || continue	# seed only what this host still has
		f=$(gate "$p") || { log "not seeding $p: not served by $SEED_CACHE under 8UNr (local-only or unsigned)"; continue; }
		fetch_nar "$p" "$f" && list+=" $f"
	done
	print -r -- "$list" > "$SEED_STATE/list.new"
	if ! cmp -s "$SEED_STATE/list.new" "$SEED_STATE/list" || ! kill -0 "$(cat "$SEED_STATE/pid" 2>/dev/null)" 2>/dev/null; then
		kill "$(cat "$SEED_STATE/pid" 2>/dev/null)" 2>/dev/null; mv "$SEED_STATE/list.new" "$SEED_STATE/list"
		[[ -n ${list// } ]] || { log "nothing to seed"; return 0; }
		solnix-torrent seed "$SEED_STATE/nars" $list >> "$SEED_STATE/torrent.log" 2>&1 & print $! > "$SEED_STATE/pid"
		log "seeding $(print -r -- "$list" | wc -w | tr -d " ") NARs (pid $!)"
	fi
}
case $1 in
gate) gate "$2"; exit ;;
once) tick; exit ;;
esac
while :; do tick; sleep "$SEED_TICK"; done
