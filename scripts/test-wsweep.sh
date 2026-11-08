#!/usr/bin/bash
# test-wsweep.sh (root, on a solnix host with python3 on PATH): modules/config/community/solnix-wsweep.ksh against fake fixed build dirs under a
# scratch root. Removed: old + build-user-owned + <kind>-<hex> + its owner runs no process. Kept: new, root-owned, bad name, and every W of an
# owner that runs ANY process, even with its cwd outside W (a live meson --check's W was swept on woof, 2026-11-08). As uid 30990, a build-user
# uid no build runs as (a busy host's nixbld1 may be building). Keyed (<age> <buildKey>): that key's dirs only, any age, same rule; a non-hex
# key removes nothing. Negative control: run it against the pre-fix script (git show 58dd37f:<path> > /tmp/old.ksh; test-wsweep.sh /tmp/old.ksh).
# A process runs AS the build uid through python3 setuid (nixbld users' shell is /usr/bin/false, so `su nixbld1 -c` runs nothing). Last line: RESULT:
S=${1:-$(dirname "$0")/../modules/config/community/solnix-wsweep.ksh}; R=$(mktemp -d /var/tmp/wsw.XXXXXX); chmod 755 "$R"; bad=0
st() { [ -d "$R/$1" ] && echo kept || echo removed; }
want() { [ "$(st "$1")" = "$2" ] && echo "ok: $1 $2" || { echo "FAIL: $1 is $(st "$1"), want $2"; bad=1; }; }
cd "$R"; mkdir srcpkg-aaaa1111 cargo-bbbb2222 go-cccc3333 srcpkg-notHEX srcpkg-dddd4444
chown 30990 srcpkg-aaaa1111 cargo-bbbb2222 srcpkg-notHEX srcpkg-dddd4444; chown root go-cccc3333
touch -t 202610010000 srcpkg-aaaa1111 go-cccc3333 srcpkg-notHEX srcpkg-dddd4444
# the owner runs a process whose cwd is OUTSIDE every W (the woof case): all its W are kept
python3 -c 'import os,time; os.setgid(30000); os.setuid(30990); os.chdir("/"); time.sleep(30)' & P=$!; sleep 2
SOLNIX_WSWEEP_ROOT=$R ksh93 "$S" 3600
want srcpkg-aaaa1111 kept; want srcpkg-dddd4444 kept; want cargo-bbbb2222 kept; want go-cccc3333 kept; want srcpkg-notHEX kept
kill $P; wait $P 2>/dev/null; SOLNIX_WSWEEP_ROOT=$R ksh93 "$S" 3600
want srcpkg-aaaa1111 removed; want srcpkg-dddd4444 removed; want cargo-bbbb2222 kept; want go-cccc3333 kept; want srcpkg-notHEX kept
# keyed (solnix-builder before pre-submit's --check of one drv, fleet8): only that key, whatever its age; kept while its owner
# runs ANY process (mk-src-pkg writes W before it cds there); a key that is not hex is refused (never a glob).
mkdir srcpkg-eeee5555 cargo-eeee5555 srcpkg-ffff6666 srcpkg-abab7777; chown 30990 srcpkg-eeee5555 cargo-eeee5555 srcpkg-ffff6666 srcpkg-abab7777
touch -t 202610010000 srcpkg-ffff6666
o=$(SOLNIX_WSWEEP_ROOT=$R ksh93 "$S" 0 eeee5555); echo "$o" | sed 's/^/   /'
want srcpkg-eeee5555 removed; want cargo-eeee5555 removed; want srcpkg-ffff6666 kept
SOLNIX_WSWEEP_ROOT=$R ksh93 "$S" 0 '*'; SOLNIX_WSWEEP_ROOT=$R ksh93 "$S" 0 'ffff*'; want srcpkg-ffff6666 kept
python3 -c 'import os,time; os.setgid(30000); os.setuid(30990); os.chdir("/"); time.sleep(30)' & P=$!; sleep 2
o=$(SOLNIX_WSWEEP_ROOT=$R ksh93 "$S" 0 abab7777); echo "$o" | sed 's/^/   /'
want srcpkg-abab7777 kept; echo "$o" | grep -q 'keeping .*srcpkg-abab7777 (uid 30990 runs a process' && echo "ok: keyed keep says why" || { echo "FAIL: keyed keep: $o"; bad=1; }
kill $P; wait $P 2>/dev/null; SOLNIX_WSWEEP_ROOT=$R ksh93 "$S" 0 abab7777; want srcpkg-abab7777 removed
cd /; find "$R" -depth -delete; [ $bad = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"; exit $bad
