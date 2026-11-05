#!/usr/bin/ksh93
# test-advisories.sh -- solnix-advisories (the CVE feed matcher) and the census's advisories flag, with a fixture feed.
# nix-store, getent and curl are stubs, so the store paths "in use" are the fixture's and no network is used. The census
# part needs mac(1) (illumos); the matcher part also runs on Linux with ksh93 + jq (a digest(1) shim is made there).
# The fixture feed is signed by a fixture ed25519 key (openssl 3, OPENSSL_BIN); section 3b checks infra's live feed against
# the pinned key with the real curl (CURL_BIN), and SKIPs (not a pass) when it cannot reach it.
#   ksh93 scripts/test-advisories.sh [<community dir>]     with jq on PATH
D=${1:-$(dirname "$0")/../modules/config/community}; A=$D/solnix-advisories.sh C=$D/solnix-census.sh
W=$(mktemp -d /tmp/advisories.XXXXXX); trap 'find "$W" -depth -delete' EXIT
bad=0; ok() { print "ok: $1"; }; no() { print "FAIL: $1"; bad=1; }
mkdir -p "$W/bin" "$W/home/.nix-profile" "$W/st" "$W/live"
RC=${CURL_BIN:-$(whence -p curl)} OS=${OPENSSL_BIN:-$(whence -p openssl || print /nix/store/gppisr3kxnrnnw73vw1pi49b9m2x8w7z-openssl-3.4.0/bin/openssl)}
PATH=${OS%/openssl}:$PATH
openssl genpkey -algorithm ed25519 -out "$W/fk.pem" 2> /dev/null && openssl genpkey -algorithm ed25519 -out "$W/fk2.pem" 2> /dev/null &&
    FK=fixture-1:$(openssl pkey -in "$W/fk.pem" -pubout -outform DER | tail -c 32 | openssl base64 -A) && [[ ${#FK} == 54 ]] ||
    { no "fixture: no ed25519 key from $OS ($FK)"; exit 1; }
h() { printf "%032d" 0 | tr 0 "$1"; }	# h <char>: a fixture store hash
SYS=$(h a) USR=$(h b) NOT=$(h c)
print -r -- "/nix/store/$SYS-sqlite-3.46.1" > "$W/sys.closure"; print -r -- "/nix/store/$USR-curl-8.10.1-bin" > "$W/user.closure"
print '#!/bin/sh\ncase $2 in /run/current-system) cat "$W/sys.closure" ;; */.nix-profile) cat "$W/user.closure" ;; esac' > "$W/bin/nix-store"
print '#!/bin/sh\necho "u:x:100:1::$W/home:/bin/sh"; echo "r:x:0:0::/:/bin/sh"' > "$W/bin/getent"
# the fake curl: a POST (--data-binary) gets $W/reply; a GET -o gets $W/served, -D its headers, signed now by the fixture key
# as infra's signer does. $W/sigmode: hdr (default: X-Solnix-Feed-Sig), dot (no header; <url>.sig has it), none, other (a
# header signed by another key), flip (a good header, then one byte of the body flipped). Every URL is logged (+ " gzip").
cat > "$W/bin/curl" <<'FC'
#!/bin/sh
o=; u=; p=; h=; z=; while [ $# -gt 0 ]; do case $1 in -o) o=$2; shift ;; -D) h=$2; shift ;; -A|-m|-w|-H|--max-filesize) shift ;; --data-binary) p=1; shift ;; --compressed) z=1 ;; -*) ;; *) u=$1 ;; esac; shift; done
echo "$u${z:+ gzip}" >> "$W/urls"; m=$(cat "$W/sigmode" 2> /dev/null)
s() { printf 'fixture-1:'; openssl pkeyutl -sign -inkey "$W/$1" -rawin -in "$W/served" | openssl base64 -A; }
if [ -n "$p" ]; then cat > "$W/sent"; cp "$W/reply" "$o"; printf 200
else case $u in
  *.sig) [ "$m" = dot ] || exit 22; s fk.pem; echo ;;
  *) cp "$W/served" "$o"; [ "$m" = flip ] && printf X | dd of="$o" bs=1 seek=2 conv=notrunc 2> /dev/null
     [ -z "$h" ] || { printf 'HTTP/1.1 200 OK\r\n'; case ${m:-hdr} in hdr|flip) printf 'X-Solnix-Feed-Sig: %s\r\n' "$(s fk.pem)" ;; other) printf 'x-solnix-feed-sig: %s\r\n' "$(s fk2.pem)" ;; esac; } > "$h" ;;
esac; fi
FC
whence -q digest || print '#!/bin/sh\nsha256sum "$3" | cut -d" " -f1' > "$W/bin/digest"	# Linux only
chmod +x "$W"/bin/*; : > "$W/urls"
export W ADV_STATE=$W/st ADV_PATH=$W/bin:$PATH PATH=$W/bin:$PATH ADV_FEED_KEY=$FK
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
# 1b. the signature (pinned key, infra 2026-11-04 s2-s3). A new feed whose sha256 matches the reply: only the signature decides.
grep -q '/advisories gzip$' "$W/urls" && ok "the feed GET asks for gzip (--compressed; checked after inflating)" || no "no --compressed: $(<"$W/urls")"
feed 1 null > "$W/served"; S2=$(digest -a sha256 "$W/served"); reply https://telemetry.solnix.io/api/v1/advisories "$S2"
for m in other none; do print $m > "$W/sigmode"; out=$(adv --census-reply "$W/r.json")
  [[ $(digest -a sha256 "$W/st/advisories.json") == "$S1" && $out == *'is not signed by fixture-1'*'kept the old copy'* && ! -e $W/st/advisories.json.new ]] &&
    ok "NEG census, sha256 right, signature $m: refused, old copy kept, logged" || no "signature $m accepted: $out"; done
print hdr > "$W/sigmode"; adv --census-reply "$W/r.json" > /dev/null; [[ $(digest -a sha256 "$W/st/advisories.json") == "$S2" ]] &&
  ok "control: the same feed and reply with a good header signature: kept" || no "control: a good signature refused"
print flip > "$W/sigmode"; out=$(adv --fetch --json 2>&1); r=$?
(( r != 0 )) && [[ $out == *'is not signed by fixture-1'* ]] && ok "NEG --fetch, one body byte flipped after signing: refused" || no "flipped byte accepted (rc $r): $out"
print dot > "$W/sigmode"; n=$(wc -l < "$W/urls"); [[ $(adv --fetch --json | jq -r .version) == 1 ]] && tail -n +$((n + 1)) "$W/urls" | grep -q '/advisories\.sig$' &&
  ok "no header: <url>.sig is fetched and verified" || no "the .sig fallback: $(tail -n +$((n + 1)) "$W/urls")"
print hdr > "$W/sigmode"; feed 1 "\"/nix/store/$(h d)-sqlite-3.49.1\"" > "$W/served"; reply https://telemetry.solnix.io/api/v1/advisories "$S1"; adv --census-reply "$W/r.json" > /dev/null
[[ $(digest -a sha256 "$W/st/advisories.json") == "$S1" ]] || no "fixture: cannot restore the first feed"
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
# 3b. live: infra's feed, the real curl and the PINNED key (ADV_FEED_KEY unset) pass; the same with one byte flipped fails
printf '#!/bin/sh\n"%s" "$@"; r=$?; o=; while [ $# -gt 0 ]; do [ "$1" = -o ] && o=$2; shift; done\n[ -z "$FLIP" ] || [ -z "$o" ] || printf X | dd of="$o" bs=1 seek=2 conv=notrunc 2> /dev/null\nexit $r\n' "$RC" > "$W/live/curl"; chmod +x "$W/live/curl"
lv() { env ADV_FEED_KEY= ADV_PATH="$W/live:$ADV_PATH" "$@" ksh93 "$A" --fetch --json 2> "$W/live.err"; }
if "$RC" -sSf -m 30 -o /dev/null https://telemetry.solnix.io/api/v1/advisories.sig 2> /dev/null; then
  j=$(lv) && [[ $(print -r -- "$j" | jq -r '.version') == 1 ]] && ok "live: infra's feed verifies against the pinned solnix-advisories-1 key" || no "live feed refused: $(<"$W/live.err")"
  j=$(lv FLIP=1); r=$?; (( r != 0 )) && grep -q 'is not signed by solnix-advisories-1' "$W/live.err" && ok "NEG live: the same feed with one byte flipped: refused" || no "live flipped (rc $r): $(<"$W/live.err")"
else print "SKIP live feed: telemetry.solnix.io unreachable (not counted as a pass)"; fi
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
