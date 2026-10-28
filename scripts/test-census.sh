#!/usr/bin/ksh93
# test-census.sh -- solnix-census on illumos (needs ksh93 + mac(1)): record grammar, nonce, and that nothing is sent
# without an endpoint or with telemetry-off. curl is replaced by a recorder (CENSUS_CURL), so no network is used.
S=${1:-$(dirname "$0")/../modules/config/community/solnix-census.sh}
W=$(mktemp -d /tmp/census.XXXXXX); trap 'find "$W" -depth -delete' EXIT
bad=0; ok() { print "ok: $1"; }; no() { print "FAIL: $1"; bad=1; }
print '#!/bin/sh\ncat > "$W/sent"; echo "$@" >> "$W/args"; printf 200' > "$W/curl"; chmod +x "$W/curl"
export W CENSUS_STATE=$W CENSUS_CURL=$W/curl CENSUS_SYSTEM=x86_64-solaris CENSUS_HOST_KIND=server CENSUS_PATH=$PATH
G='^\{"version":1,"kind":"platform_census","system":"(x86_64|aarch64|riscv64|sparcv9)-solaris","host-kind":"(server|laptop|workstation)","illumos-flavor":"solnix"(,"seeding":(true|false))?(,"building":(true|false))?(,"builder":(true|false))?(,"location":\{"country":"[A-Z]{2}"(,"region":"[A-Z0-9]{1,3}")?(,"locality":"[^"\\]{1,64}")?\})?,"nonce":"[A-Za-z0-9+/]{16}","day":"[0-9]{4}-[0-9]{2}-[0-9]{2}"\}$'
r=$(CENSUS_seeding=true CENSUS_building=true CENSUS_builder=false ksh93 "$S" --record 2026-10-28 AAAAbbbbCCCCdd+/)
print -r -- "$r" | egrep -q "$G" && ok "grammar: $r" || no "grammar: $r"
[[ $r != *location* ]] && ok "no location unless set" || no "location leaked: $r"
r=$(CENSUS_LOC_COUNTRY=US CENSUS_LOC_REGION=MA CENSUS_LOC_LOCALITY=Ware ksh93 "$S" --record 2026-10-28 AAAAbbbbCCCCdd+/)
[[ $r == *'"location":{"country":"US","region":"MA","locality":"Ware"}'* ]] && print -r -- "$r" | egrep -q "$G" && ok "location when set: $r" || no "location: $r"
r=$(CENSUS_seeding=maybe ksh93 "$S" --record 2026-10-28 AAAAbbbbCCCCdd+/); [[ $r != *seeding* ]] && ok "non-boolean flag dropped" || no "flag: $r"
# HMAC-SHA256 + base64 against RFC 4231 test case 2 (key "Jefe")
printf Jefe > "$W/k"; h=$(ksh93 "$S" --hmac-b64 "$W/k" "what do ya want for nothing?")
[[ $h == W9zBRr9gdU5qBCQmCJV1x1oAPwidJzmDnexYuWTsOEM= ]] && ok "hmac-b64 RFC 4231 #2" || no "hmac-b64: $h"
# negative control: no endpoint -> nothing sent; telemetry-off -> nothing sent
CENSUS_ENDPOINT= ksh93 "$S" --once >/dev/null; [[ ! -e $W/sent ]] && ok "NEG no endpoint: nothing sent" || no "sent without endpoint"
mkdir -p "$W/etc"; DO_NOT_TRACK=1 CENSUS_ENDPOINT=https://x.invalid/ ksh93 "$S" --once >/dev/null
[[ ! -e $W/sent ]] && ok "NEG DO_NOT_TRACK: nothing sent" || no "sent with DO_NOT_TRACK"
# positive: endpoint set -> one record, the nonce derived (never the secret), once per day
CENSUS_ENDPOINT=https://x.invalid/c ksh93 "$S" --once >/dev/null; s=$(cat "$W/sent" 2>/dev/null)
print -r -- "$s" | egrep -q "$G" && ok "sent once: $s" || no "send: '$s'"
[[ $s != *$(cat "$W/census-secret")* ]] && ok "secret not in record" || no "secret leaked"
find "$W" -name sent -delete; CENSUS_ENDPOINT=https://x.invalid/c ksh93 "$S" --once >/dev/null; [[ ! -e $W/sent ]] && ok "second run same day: not resent" || no "resent same day"
[[ $(ls -l "$W/census-secret" | cut -c1-10) == -rw------- ]] && ok "secret 0600" || no "secret mode $(ls -l "$W/census-secret")"
exit $bad
