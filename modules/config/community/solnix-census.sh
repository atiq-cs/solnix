#!/usr/bin/ksh93
# solnix-census -- the anonymous daily platform census (modules/config/community/census.nix).
# One SMF contract loop: sleep a random 0..CENSUS_JITTER s, send at most one record per UTC
# day, repeat. Best effort: curl -m 5, a non-200 is "later" (next tick), nothing queued on disk.
# The record: docs/design-telemetry-client.md + infra 2026-10-28 (seeding/building/builder flags,
# optional operator-set location), sent as JSON: the live ingest rejects the EDN form with 400
# (measured 2026-10-28; its census parser decodes JSON only). Never a hostname, key, email, IP
# or stable id; the nonce is HMAC-SHA256(per-day secret, "solnix-telemetry"+day), never the secret.
#   solnix-census --record <day> <nonce>   print the record only (the unit test uses this)
PATH=${CENSUS_PATH:-/usr/bin:/usr/sbin}
: ${CENSUS_STATE:=/var/lib/solnix/census} ${CENSUS_JITTER:=21600} ${CENSUS_TICK:=3600}

js() { printf '"%s"' "$1"; }	# values are closed vocabularies or eval-checked (no " \ control)

record() {	# record <day> <nonce>: one JSON object (the deployed ingest parses the census as JSON only)
	typeset r="{\"version\":1,\"kind\":\"platform_census\",\"system\":$(js "$CENSUS_SYSTEM")"
	r+=",\"host-kind\":$(js "$CENSUS_HOST_KIND"),\"illumos-flavor\":\"solnix\""
	typeset f v; for f in seeding building builder; do
		eval "v=\${CENSUS_${f}:-}"
		[[ $v == true || $v == false ]] && r+=",\"$f\":$v"
	done
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
	typeset code=$(record "$day" "$n" | ${CENSUS_CURL:-curl} -sS -m 5 -o /dev/null -w '%{http_code}' \
	    -H 'Content-Type: application/json' --data-binary @- "$CENSUS_ENDPOINT" 2>&1)
	[[ $code == 200 ]] || { print "census: $code, later"; return 1; }
	print -r -- "$day" > "$stamp"; print "census: sent for $day"
}

case $1 in
--record) record "$2" "$3"; exit ;;
--hmac-b64) hmac_b64 "$2" "$3"; exit ;;
--once) send_once; exit ;;
esac
mkdir -p "$CENSUS_STATE" || exit 1
# jitter each attempt; the day stamp keeps it to one send per UTC day (systemd: RandomizedDelaySec)
while :; do sleep $(( (RANDOM * 32768 + RANDOM) % CENSUS_JITTER )); send_once; sleep "$CENSUS_TICK"; done
