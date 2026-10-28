#!/usr/bin/ksh93
# solnix-cache-proxy -- one HTTP/1.0 request on stdin/stdout (inetd, wait=false), the local substituter in front of
# cache.solnix.io (infra 2026-10-28, shape (a)). Nix checks every signature and hash itself, so this is trusted for
# availability only.
#   GET|HEAD /nix-cache-info       our own, Priority 30, so nix tries us before cache.solnix.io (50)
#   GET|HEAD /<hash>.narinfo       relayed from upstream; its Torrent: line is remembered by NAR name (read, never derived)
#   GET|HEAD /nar/<file>           PROXY_TORRENT_FETCH <torrent-url> <out> <seconds> when the narinfo carried Torrent:
#                                  and the command exists (it must give up by <seconds>; solnix has no timeout(1));
#                                  otherwise, or on any failure, 302 to upstream (the HTTP fallback)
PATH=${PROXY_PATH:-/usr/bin}
: ${PROXY_UPSTREAM:=https://cache.solnix.io} ${PROXY_STATE:=/var/lib/solnix/cache-proxy} ${PROXY_TORRENT_TIMEOUT:=60}
reply() {	# reply <status> <content-type> [file]
	typeset n=0; [[ -n $3 ]] && n=$(wc -c < "$3")
	printf 'HTTP/1.0 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n' "$1" "$2" $n
	[[ -n $3 && $m == GET ]] && cat "$3"
}
moved() { printf 'HTTP/1.0 302 Found\r\nLocation: %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' "$PROXY_UPSTREAM/$1"; }
read -t 15 -r m p v || exit 0
while read -t 15 -r h && [[ ${h%$'\r'} != "" ]]; do :; done	# headers: none needed
T=$(mktemp "$PROXY_STATE/tmp/r.XXXXXX") || exit 1; trap 'rm -f "$T" "$T.nar"' EXIT
[[ $m == GET || $m == HEAD ]] || { reply '405 Method Not Allowed' text/plain; exit; }
case $p in
/nix-cache-info)
	printf 'StoreDir: /nix/store\nWantMassQuery: 1\nPriority: 30\n' > "$T"; reply '200 OK' text/x-nix-cache-info "$T" ;;
/+([0-9a-df-np-sv-z]).narinfo)
	[[ ${#p} == 41 ]] || { reply '404 Not Found' text/plain; exit; }
	c=$(curl -sS -m 20 -o "$T" -w '%{http_code}' "$PROXY_UPSTREAM$p" 2>/dev/null)
	case $c in
	200)	u=$(sed -n 's/^URL: nar\/\([0-9a-z]*\.nar[.a-z0-9]*\)$/\1/p' "$T"); t=$(sed -n 's/^Torrent: \(torrent\/[0-9a-z]*\.nar[.a-z0-9]*\.torrent\)$/\1/p' "$T")
		[[ -n $u ]] && print -r -- "$t" > "$PROXY_STATE/seen/$u"	# the seeder's list of what this host fetched
		reply '200 OK' text/x-nix-narinfo "$T" ;;
	404)	reply '404 Not Found' text/plain ;;
	*)	reply '502 Bad Gateway' text/plain ;;
	esac ;;
/nar/+([0-9a-z]).nar?(.xz|.zst|.bz2))
	f=${p#/nar/}; t=$(cat "$PROXY_STATE/seen/$f" 2>/dev/null)
	if [[ -n $t && -x $PROXY_TORRENT_FETCH ]] &&
	    "$PROXY_TORRENT_FETCH" "$PROXY_UPSTREAM/$t" "$T.nar" "$PROXY_TORRENT_TIMEOUT" >/dev/null 2>&1 && [[ -s $T.nar ]]; then
		reply '200 OK' application/x-nix-nar "$T.nar"
	else
		moved "nar/$f"
	fi ;;
*)	reply '404 Not Found' text/plain ;;
esac
