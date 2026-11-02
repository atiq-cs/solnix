#!/usr/bin/ksh93
# solnix-advisories -- match solnix.io's CVE advisory feed (format v1, infra 2026-11-02) against the store paths this
# host uses: the closures of /run/current-system, /nix/var/nix/profiles/system, every per-user profile and every
# ~/.nix-profile. Matching is local; nothing about the result leaves the host. With solnix.telemetry.census.advisories
# the census sends only "advisories":true and gets back the feed's URL and sha256 (census.nix, solnix-census.sh).
#   solnix-advisories [--json]            the matches in the cached feed (<state>/advisories.json)
#   solnix-advisories --fetch [--json]    GET the feed now, without the census, and match it (the cache is not touched)
#   solnix-advisories --census-reply <f>  (the census) if the reply names a feed whose sha256 differs from the cached
#                                         copy, fetch it, verify the sha256, keep it; then print the day's summary line
#   solnix-advisories --summary           that summary line
# Limits: infra scans only packages with a CPE and knows nothing of backports. No advisory does not mean no CVE.
PATH=${ADV_PATH:-$PATH}
: ${ADV_STATE:=/var/lib/solnix/census} ${ADV_URL:=https://telemetry.solnix.io/api/v1/advisories}
F=$ADV_STATE/advisories.json
umask 022	# the cached feed is world-readable, so any user can run solnix-advisories

inuse() {	# the 32-char hashes of the store paths in use, one per line
	typeset r
	{ print -r -- /run/current-system; print -r -- /nix/var/nix/profiles/system
	  for r in /nix/var/nix/profiles/per-user/*/profile; do print -r -- "$r"; done
	  getent passwd | cut -d: -f6 | sort -u | sed 's|/*$|/.nix-profile|'; } |
	while IFS= read -r r; do [[ -e $r ]] && nix-store -qR "$r" 2>/dev/null; done |
	sed -n 's|^/nix/store/\([0-9a-z]\{32\}\)-.*|\1|p' | sort -u
}
match() {	# match <feed>: the feed's own shape, cut to the entries whose hash is in use; unknown fields pass through.
	# The hashes go in on stdin (a big closure would overflow an argument).
	inuse | jq -n -R --slurpfile f "$1" '
	  (reduce (inputs | select(length == 32)) as $h ({}; .[$h] = true)) as $u | $f[0] |
	  if .version != 1 then error("advisory feed version \(.version), this solnix-advisories reads 1: update solnix") else . end |
	  .advisories = [.advisories[]? | objects | select((.hash | type) == "string" and $u[.hash] == true)] |
	  .count = (.advisories | length)'
}
summary() { jq -r '([.advisories[].cves[]?] | unique_by(.id)) as $c |
	"advisories: \(.count) store paths in use have \($c | length) known CVEs (\([$c[] | select(.severity == "Critical")] | length) Critical); run solnix-advisories"'; }
show() { jq -r '"feed \(.generated_at // "?") (\(.scanner.name // "?") \(.scanner.version // "")): \(.count) store paths in use have advisories",
	(.advisories[] | (.store_path // .hash),
	  (.cves[]? | "  \(.id)\t\(.severity // "Unknown")\tfixed in \(.fixed_in // "(no fix known)")\t\(.url // "")"),
	  (if .fixed_store_path then "  newer build served: \(.fixed_store_path)" else empty end)),
	"No advisory does not mean no CVE: only packages with a CPE are scanned, and backported fixes are not known."'; }
fetch() { curl -sSf -m 30 -A 'solnix-advisories/1' --max-filesize 67108864 -o "$2" "$1"; }	# fetch <url> <out>
sha() { [[ -f $1 ]] && digest -a sha256 "$1"; }

census_reply() {	# census_reply <reply>: {"status":..,"advisories":{"url","sha256","generated_at","count"}}
	typeset url= t=$F.new; typeset -l sum=
	jq -r '.advisories | objects | "\(.url // "")\t\(.sha256 // "")"' "$1" 2>/dev/null | IFS=$'\t' read -r url sum
	# only an https URL on solnix.io: the reply must not be able to send this host's GET (its IP) anywhere else
	if [[ $url == https://+([a-z0-9.-]).solnix.io/* && $sum == +([0-9a-f]) && ${#sum} == 64 && $(sha "$F") != "$sum" ]]; then
		if fetch "$url" "$t" && [[ $(sha "$t") == "$sum" ]] && jq -e '.version == 1' "$t" > /dev/null; then
			mv -f "$t" "$F"
		else
			print "advisories: $url did not give a version-1 feed with sha256 $sum; kept the old copy"; rm -f "$t"
		fi
	fi
	[[ -s $F ]] && match "$F" | summary
}

json= feed=$F
while (( $# )); do
	case $1 in
	--json) json=1 ;;
	--fetch) feed=$(mktemp /tmp/solnix-advisories.XXXXXX) || exit 1; trap 'rm -f "$feed"' EXIT
		fetch "$ADV_URL" "$feed" || exit 1 ;;
	--census-reply) census_reply "$2"; exit ;;
	--summary) [[ -s $F ]] && match "$F" | summary; exit ;;
	*) print -u2 "usage: solnix-advisories [--fetch] [--json]"; exit 2 ;;
	esac
	shift
done
[[ -s $feed ]] || { print -u2 "solnix-advisories: no feed at $feed yet (the census keeps it when solnix.telemetry.census.advisories is on); try --fetch"; exit 1; }
if [[ -n $json ]]; then match "$feed"; else match "$feed" | show; fi
