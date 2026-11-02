#!/usr/bin/bash
# test-wsweep.sh (root, on a host with build users nixbld1): modules/config/community/solnix-wsweep.ksh against fake fixed build dirs under a
# scratch root. Removed: old + build-user-owned + <kind>-<hex> + no owner process in it. Kept: new, root-owned, bad name, owner process inside.
# A process runs AS nixbld1 through python3 setuid (nixbld users' shell is /usr/bin/false, so `su nixbld1 -c` runs nothing). Last line: RESULT:
S=${1:-$(dirname "$0")/../modules/config/community/solnix-wsweep.ksh}; R=$(mktemp -d /var/tmp/wsw.XXXXXX); chmod 755 "$R"; bad=0
st() { [ -d "$R/$1" ] && echo kept || echo removed; }
want() { [ "$(st "$1")" = "$2" ] && echo "ok: $1 $2" || { echo "FAIL: $1 is $(st "$1"), want $2"; bad=1; }; }
cd "$R"; mkdir srcpkg-aaaa1111 cargo-bbbb2222 go-cccc3333 srcpkg-notHEX srcpkg-dddd4444
chown nixbld1 srcpkg-aaaa1111 cargo-bbbb2222 srcpkg-notHEX srcpkg-dddd4444; chown root go-cccc3333
touch -t 202610010000 srcpkg-aaaa1111 go-cccc3333 srcpkg-notHEX srcpkg-dddd4444
python3 -c 'import os,sys,time; os.setgid(30000); os.setuid(30001); os.chdir(sys.argv[1]); time.sleep(30)' "$R/srcpkg-dddd4444" & P=$!; sleep 2
SOLNIX_WSWEEP_ROOT=$R ksh93 "$S" 3600
want srcpkg-aaaa1111 removed; want cargo-bbbb2222 kept; want go-cccc3333 kept; want srcpkg-notHEX kept; want srcpkg-dddd4444 kept
kill $P; wait $P 2>/dev/null; SOLNIX_WSWEEP_ROOT=$R ksh93 "$S" 3600; want srcpkg-dddd4444 removed
cd /; find "$R" -depth -delete; [ $bad = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"; exit $bad
