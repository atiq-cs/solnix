#!/usr/bin/ksh93
# solnix-census -- the anonymous daily platform census (modules/config/community/census.nix).
# One SMF contract loop that sends at most one record per UTC day, inside this host's own 15-minute window of the
# day: the window (one of 96) is picked at random once and kept in <state>/census-slot, and each day's send lands at
# a fresh random moment inside it. A fleet spreads over the whole day instead of arriving together, and a host keeps
# to the same quarter-hour. Best effort: curl -m 5; a non-200 is retried twice in the window, then tomorrow. Nothing
# is queued on disk.
# The record: docs/design-telemetry-client.md + infra 2026-10-28 (seeding/building/builder flags,
# optional operator-set location), sent as JSON: the live ingest rejects the EDN form with 400
# (measured 2026-10-28; its census parser decodes JSON only). Never a hostname, key, email, IP
# or stable id; the nonce is HMAC-SHA256(per-day secret, "solnix-telemetry"+day), never the secret.
#   solnix-census --record <day> <nonce>   print the record only (the unit test uses this)
PATH=${CENSUS_PATH:-/usr/bin:/usr/sbin}
: ${CENSUS_STATE:=/var/lib/solnix/census} ${CENSUS_WINDOW:=900}

js() { printf '"%s"' "$1"; }	# values are closed vocabularies or eval-checked (no " \ control)

record() {	# record <day> <nonce>: one JSON object (the deployed ingest parses the census as JSON only)
	typeset r="{\"version\":1,\"kind\":\"platform_census\",\"system\":$(js "$CENSUS_SYSTEM")"
	r+=",\"host-kind\":$(js "$CENSUS_HOST_KIND"),\"illumos-flavor\":\"solnix\""
	typeset f v; for f in seeding building builder; do
		eval "v=\${CENSUS_${f}:-}"
		[[ $v == true || $v == false ]] && r+=",\"$f\":$v"
	done
	[[ $CENSUS_advisories == true ]] && r+=',"advisories":true'	# only ever true; off = no key (infra 2026-11-02)
	if [[ -n $CENSUS_LOC_COUNTRY ]]; then
		r+=",\"location\":{\"country\":$(js "$CENSUS_LOC_COUNTRY")"
		[[ -n $CENSUS_LOC_REGION ]] && r+=",\"region\":$(js "$CENSUS_LOC_REGION")"
		[[ -n $CENSUS_LOC_LOCALITY ]] && r+=",\"locality\":$(js "$CENSUS_LOC_LOCALITY")"
		r+="}"
	fi
	print -r -- "$r,\"nonce\":$(js "$2"),\"day\":$(js "$1")}"
}

nonce() {	# nonce <day>: HMAC-SHA256(secret, "solnix-telemetry"+day), first 16 base64 chars. The secret is
	# 32 random bytes (as hex) that rotate with the UTC day (design-telemetry-client.md section 4).
	typeset k=$CENSUS_STATE/census-secret
	if [[ ! -s $k || $(cat "$k.day" 2>/dev/null) != "$1" ]]; then
		(umask 077; od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "$k.$$" && mv "$k.$$" "$k" && print -r -- "$1" > "$k.day") || return 1
	fi
	hmac_b64 "$k" "solnix-telemetry$1" | cut -c1-16
}
hmac_b64() { printf '%s' "$2" | mac -a sha256_hmac -k "$1" | hex_b64; }	# <keyfile> <message>
hex_b64() {	# hex on stdin -> base64 (no binary through the shell: an HMAC byte can be NUL)
	nawk '{ h = "0123456789abcdef"; a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	  n = length($0) / 2; for (i = 0; i < n; i++) b[i] = (index(h, substr($0, 2*i+1, 1)) - 1) * 16 + index(h, substr($0, 2*i+2, 1)) - 1
	  for (i = 0; i < n; i += 3) { v = b[i] * 65536 + (i+1 < n ? b[i+1] * 256 : 0) + (i+2 < n ? b[i+2] : 0)
	    s = s substr(a, int(v/262144)%64+1, 1) substr(a, int(v/4096)%64+1, 1)
	    s = s (i+1 < n ? substr(a, int(v/64)%64+1, 1) : "=") (i+2 < n ? substr(a, v%64+1, 1) : "=") } print s }'; }

send_once() {	# 0 = sent (or nothing to do today), 1 = try later
	typeset day=$(TZ=UTC printf '%(%Y-%m-%d)T' now) stamp=$CENSUS_STATE/census-sent
	[[ -z $CENSUS_ENDPOINT ]] && { print "census: no endpoint set, not sending"; return 0; }
	[[ -e /etc/solnix/telemetry-off || $DO_NOT_TRACK == 1 ]] && { print "census: telemetry-off, not sending"; return 0; }
	[[ $(cat "$stamp" 2>/dev/null) == "$day" ]] && return 0
	typeset n; n=$(nonce "$day") && [[ ${#n} == 16 ]] || { print -u2 "census: nonce failed"; return 1; }
	typeset code=$(record "$day" "$n" | ${CENSUS_CURL:-curl} -sS -m 5 -o "$CENSUS_STATE/census-reply" -w '%{http_code}' \
	    -H 'Content-Type: application/json' --data-binary @- "$CENSUS_ENDPOINT" 2>&1)
	[[ $code == 200 ]] || { print "census: $code, later"; return 1; }
	print -r -- "$day" > "$stamp"; print "census: sent for $day"
	# the reply names the CVE feed; solnix-advisories fetches it if it changed and prints the day's summary line
	if [[ $CENSUS_advisories == true && -n $CENSUS_ADVISORIES ]]; then ADV_STATE=$CENSUS_STATE "$CENSUS_ADVISORIES" --census-reply "$CENSUS_STATE/census-reply"; fi
	return 0
}

case $1 in
--record) record "$2" "$3"; exit ;;
--hmac-b64) hmac_b64 "$2" "$3"; exit ;;
--once) send_once; exit ;;
esac
slot() {	# this host's daily slot start, seconds after 00:00 UTC, on a 15-min boundary; picked once and kept
	typeset f=$CENSUS_STATE/census-slot s
	s=$(cat "$f" 2>/dev/null)
	[[ $s == +([0-9]) ]] && (( s < 86400 )) || { s=$(( (RANDOM * 32768 + RANDOM) % 96 * 900 )); print -r -- "$s" > "$f"; }
	print -r -- "$s"
}
next_wait() {	# next_wait <now secs since epoch> <slot secs>: seconds until the next slot start + a random 0..WINDOW-301 s,
	# so the first try and both retries (+120, +240) land inside the 15-min window
	typeset now=$1 sl=$2 d=$(( $1 % 86400 )) w
	(( w = sl - d )); (( w <= 0 )) && (( w += 86400 ))
	print -r -- $(( w + (RANDOM * 32768 + RANDOM) % (CENSUS_WINDOW - 300) ))
}
case $1 in --slot) slot; exit ;; --next-wait) next_wait "$2" "$3"; exit ;; esac
mkdir -p "$CENSUS_STATE" || exit 1
s=$(slot)
# a send that failed (non-200) retries inside the same window: 3 tries 2 min apart, then tomorrow's slot
while :; do
	sleep "$(next_wait "$(printf '%(%s)T' now)" "$s")"
	for t in 1 2 3; do send_once && break; (( t < 3 )) && sleep 120; done
done
