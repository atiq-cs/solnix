#!/usr/bin/ksh93
# test-advisories.sh -- solnix-advisories (the CVE feed matcher) and the census's advisories flag, with a fixture feed.
# nix-store, getent and curl are stubs, so the store paths "in use" are the fixture's and no network is used. The census
# part needs mac(1) (illumos); the matcher part also runs on Linux with ksh93 + jq (a digest(1) shim is made there).
#   ksh93 scripts/test-advisories.sh [<community dir>]     with jq on PATH
D=${1:-$(dirname "$0")/../modules/config/community}; A=$D/solnix-advisories.sh C=$D/solnix-census.sh
W=$(mktemp -d /tmp/advisories.XXXXXX); trap 'find "$W" -depth -delete' EXIT
bad=0; ok() { print "ok: $1"; }; no() { print "FAIL: $1"; bad=1; }
mkdir -p "$W/bin" "$W/home/.nix-profile" "$W/st"
h() { printf "%032d" 0 | tr 0 "$1"; }	# h <char>: a fixture store hash
SYS=$(h a) USR=$(h b) NOT=$(h c)
print -r -- "/nix/store/$SYS-sqlite-3.46.1" > "$W/sys.closure"; print -r -- "/nix/store/$USR-curl-8.10.1-bin" > "$W/user.closure"
print '#!/bin/sh\ncase $2 in /run/current-system) cat "$W/sys.closure" ;; */.nix-profile) cat "$W/user.closure" ;; esac' > "$W/bin/nix-store"
print '#!/bin/sh\necho "u:x:100:1::$W/home:/bin/sh"; echo "r:x:0:0::/:/bin/sh"' > "$W/bin/getent"
print '#!/bin/sh\no=; u=; p=; while [ $# -gt 0 ]; do case $1 in -o) o=$2; shift ;; -A|-m|-w|-H|--max-filesize) shift ;; --data-binary) p=1; shift ;; -*) ;; *) u=$1 ;; esac; shift; done
echo "$u" >> "$W/urls"; if [ -n "$p" ]; then cat > "$W/sent"; cp "$W/reply" "$o"; printf 200; else cp "$W/served" "$o"; fi' > "$W/bin/curl"
whence -q digest || print '#!/bin/sh\nsha256sum "$3" | cut -d" " -f1' > "$W/bin/digest"	# Linux only
chmod +x "$W"/bin/*; : > "$W/urls"
export W ADV_STATE=$W/st ADV_PATH=$W/bin:$PATH PATH=$W/bin:$PATH
adv() { ksh93 "$A" "$@"; }
feed() {	# feed <version> <fixed path for SYS>: three entries (SYS in use, USR in use, NOT not), plus fields v1 doesn't know
	print -r -- "{\"version\":$1,\"generated_at\":\"2026-11-02T16:25:46Z\",\"scanner\":{\"name\":\"grype\",\"version\":\"0.112.0\"},\"new_top\":[1],\"count\":4,\"advisories\":[
	{\"hash\":\"$SYS\",\"store_path\":\"/nix/store/$SYS-sqlite-3.46.1\",\"pname\":\"sqlite\",\"new_field\":{\"x\":1},\"cves\":[{\"id\":\"CVE-2025-3277\",\"severity\":\"Critical\",\"fixed_in\":\"3.49.1\",\"url\":\"https://nvd.nist.gov/vuln/detail/CVE-2025-3277\",\"epss\":0.1},{\"id\":\"CVE-2025-29088\",\"severity\":\"Medium\",\"fixed_in\":null,\"url\":\"u\"}],\"fixed_version\":\"3.49.1\",\"fixed_store_path\":$2},
	{\"hash\":\"$USR\",\"store_path\":\"/nix/store/$USR-curl-8.10.1-bin\",\"cves\":[{\"id\":\"CVE-2025-0001\",\"severity\":\"High\",\"fixed_in\":\"8.11.0\",\"url\":\"u\"}],\"fixed_store_path\":null},
	{\"hash\":\"$NOT\",\"store_path\":\"/nix/store/$NOT-openssl-3.0.0\",\"cves\":[{\"id\":\"CVE-2025-9999\",\"severity\":\"Critical\",\"fixed_in\":\"3.0.1\",\"url\":\"u\"}]},
	{\"store_path\":\"no hash: skipped\"}, 7]}"
}
feed 1 "\"/nix/store/$(h d)-sqlite-3.49.1\"" > "$W/served"; S1=$(digest -a sha256 "$W/served")
# every check below compares against S1: without a real one the negatives would pass vacuously
[[ $S1 == +([0-9a-f]) && ${#S1} == 64 ]] && jq -e . "$W/served" > /dev/null || { no "fixture: no sha256 ('$S1') or the feed is not JSON"; exit 1; }
reply() { print -r -- "{\"status\":\"recorded\",\"advisories\":{\"url\":\"$1\",\"sha256\":\"$2\",\"generated_at\":\"x\",\"count\":4,\"later\":true}}" > "$W/r.json"; }
# 1. the cache: a matching sha256 is fetched and kept; the same again is not refetched; a mismatch is refused, old copy kept
reply https://telemetry.solnix.io/api/v1/advisories "$S1"; out=$(adv --census-reply "$W/r.json")
[[ $(digest -a sha256 "$W/st/advisories.json" 2>/dev/null) == "$S1" ]] && ok "feed fetched and kept (sha256 verified)" || no "not kept: $out"
[[ $(ls -l "$W/st/advisories.json" | cut -c1-10) == -rw-r--r-- ]] && ok "advisories.json 0644" || no "mode $(ls -l "$W/st/advisories.json")"
[[ $out == 'advisories: 2 store paths in use have 3 known CVEs (1 Critical); run solnix-advisories' ]] && ok "summary: $out" || no "summary: $out"
n=$(wc -l < "$W/urls"); adv --census-reply "$W/r.json" > /dev/null; [[ $(wc -l < "$W/urls") == "$n" ]] && ok "same sha256: not refetched" || no "refetched an unchanged feed"
feed 1 null > "$W/served"; reply https://telemetry.solnix.io/api/v1/advisories "$(print -r -- "$S1" | tr 0-9a-f 1-9a-f0)"
out=$(adv --census-reply "$W/r.json"); [[ $(digest -a sha256 "$W/st/advisories.json") == "$S1" && $out == *'kept the old copy'* && ! -e $W/st/advisories.json.new ]] &&
    ok "NEG sha256 mismatch: refused, old copy kept" || no "mismatch accepted: $out"
S2=$(digest -a sha256 "$W/served"); n=$(wc -l < "$W/urls")
reply https://evil.example/advisories "$S2"; adv --census-reply "$W/r.json" > /dev/null
[[ $(wc -l < "$W/urls") == "$n" && $(digest -a sha256 "$W/st/advisories.json") == "$S1" ]] && ok "NEG feed URL off solnix.io: not fetched" || no "fetched a non-solnix.io URL"
feed 2 null > "$W/served"; reply https://telemetry.solnix.io/api/v1/advisories "$(digest -a sha256 "$W/served")"; adv --census-reply "$W/r.json" > /dev/null
[[ $(digest -a sha256 "$W/st/advisories.json") == "$S1" ]] && ok "NEG feed version 2: refused, old copy kept" || no "took a version 2 feed"
# 2. the match: in use (system closure, a user's ~/.nix-profile) reported; not in use not; unknown fields ignored
j=$(adv --json); hs=$(print -r -- "$j" | jq -r '[.advisories[].hash] | join(" ")')
[[ $hs == "$SYS $USR" ]] && ok "matched exactly the in-use hashes (system + user profile)" || no "matched '$hs'"
[[ $(print -r -- "$j" | jq -r '.count') == 2 ]] && ok "--json count = matches (2)" || no "count: $(print -r -- "$j" | jq .count)"
[[ $hs != *"$NOT"* ]] && ok "NEG hash not in use: not reported" || no "reported a path not in use"
t=$(adv); [[ $t == *"/nix/store/$SYS-sqlite-3.46.1"*CVE-2025-3277*Critical*'fixed in 3.49.1'*"newer build served: /nix/store/$(h d)-sqlite-3.49.1"* ]] &&
    ok "text: path, CVE, severity, fixed_in, newer build served" || no "text: $t"
[[ $t == *'CVE-2025-29088'*'(no fix known)'* && $t != *openssl* && $t == *'does not mean no CVE'* ]] && ok "text: no fix known, the limits line, no unmatched path" || no "text: $t"
print -r -- "/nix/store/$NOT-openssl-3.0.0" >> "$W/sys.closure"; [[ $(adv --json | jq -r '.count') == 3 ]] && ok "control: once in use, it is reported" || no "control: not reported once in use"
# 3. --fetch: GET the feed directly, the cache untouched
feed 1 null > "$W/served"; [[ $(adv --fetch --json | jq -r '.advisories[0].fixed_store_path') == null && $(digest -a sha256 "$W/st/advisories.json") == "$S1" ]] &&
    ok "--fetch: direct GET, cache untouched" || no "--fetch"
# 4. the census record: the key only when the flag is on, and only as true (needs mac(1) from here on)
r=$(ksh93 "$C" --record 2026-11-02 AAAAbbbbCCCCdd+/); [[ $r != *advisories* ]] && ok "NEG flag off: no advisories key" || no "flag off: $r"
r=$(CENSUS_advisories=true ksh93 "$C" --record 2026-11-02 AAAAbbbbCCCCdd+/); [[ $r == *',"advisories":true,"nonce":'* ]] && ok "flag on: \"advisories\":true" || no "flag on: $r"
r=$(CENSUS_advisories=yes ksh93 "$C" --record 2026-11-02 AAAAbbbbCCCCdd+/); [[ $r != *advisories* ]] && ok "NEG flag 'yes': dropped" || no "flag yes: $r"
whence -q mac || { print "skip: census --once (no mac(1) here)"; exit $bad; }
print '#!/bin/sh\nexec ksh93 "$A" "$@"' > "$W/bin/solnix-advisories"; chmod +x "$W/bin/solnix-advisories"; export A
feed 1 null > "$W/served"; S3=$(digest -a sha256 "$W/served"); reply https://telemetry.solnix.io/api/v1/advisories "$S3"; cp "$W/r.json" "$W/reply"
cs() { env CENSUS_STATE=$W/st CENSUS_CURL=$W/bin/curl CENSUS_SYSTEM=x86_64-solaris CENSUS_HOST_KIND=server CENSUS_PATH=$ADV_PATH CENSUS_ENDPOINT=https://x.invalid/c "$@" ksh93 "$C" --once; }
out=$(cs CENSUS_advisories=true CENSUS_ADVISORIES=$W/bin/solnix-advisories)
[[ $(cat "$W/sent") == *'"advisories":true'* && $(digest -a sha256 "$W/st/advisories.json") == "$S3" && $out == *'advisories: 3 store paths in use'* ]] &&
    ok "census --once, flag on: sent the flag, took the new feed, logged: ${out##*$'\n'}" || no "census on: $out"
rm -f "$W/st/census-sent"; n=$(wc -l < "$W/urls"); out=$(cs)
[[ $(cat "$W/sent") != *advisories* && $(( $(wc -l < "$W/urls") )) == $((n + 1)) && $out != *advisories* ]] && ok "NEG census --once, flag off: no key, no feed fetch, no line" || no "census off: $out"
exit $bad
