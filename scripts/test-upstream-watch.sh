#!/usr/bin/env bash
# test-upstream-watch.sh -- scripts/upstream-watch.sh against a fixture: a local "gate" and a "fork" of it (file://
# repos, no network), dated with committer dates. Checks the path filter, the fork-minus-base filter, the age window,
# FETCH-FAILED, BAD-ROW and the exit codes, a second run over the same cache, and the usage error.
#   bash scripts/test-upstream-watch.sh
W=$(dirname "$0")/upstream-watch.sh T=$(mktemp -d /tmp/upstream-watch-test.XXXXXX); trap 'rm -rf "$T"' EXIT
bad=0; ok() { echo "ok: $1"; }; no() { echo "FAIL: $1"; bad=1; }
now=$(date +%s); export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
c() { # c <repo> <days ago> <path> <subject>: one commit touching <path>
	mkdir -p "$1/$(dirname "$3")" && echo "$4" >> "$1/$3" && git -C "$1" add -A &&
		GIT_AUTHOR_DATE="$((now - $2 * 86400)) +0000" GIT_COMMITTER_DATE="$((now - $2 * 86400)) +0000" \
			git -C "$1" commit -q -m "$4"
}
git init -q -b master "$T/gate"
c "$T/gate" 30 usr/src/uts/common/brand/lx/a.c OLD-BRAND
c "$T/gate" 2 usr/src/uts/common/brand/lx/a.c GATE-BRAND
c "$T/gate" 1 usr/src/man/x.1 GATE-OTHER
git clone -q "$T/gate" "$T/fork"
c "$T/fork" 1 usr/src/uts/common/brand/lx/b.c FORK-BRAND
c "$T/fork" 1 usr/src/cmd/y.c FORK-OTHER
cat > "$T/list" <<EOF
# fixture list
gate	file://$T/gate	master	-	usr/src/uts/common/brand
fork	file://$T/fork	master	gate	usr/src/uts/common/brand
gone	file://$T/missing	master	-	.
short	file://$T/gate	master
EOF
"$W" -d 8 -l "$T/list" -s "$T/st" -o "$T/d1" 2> /dev/null; rc=$?
[ $rc = 1 ] && ok "a failed fetch exits 1" || no "a failed fetch exited $rc, want 1"
grep -q '^## gate (master, .*): 1 of 2 new commits touch watched paths$' "$T/d1" && ok "gate: 1 of 2 counted" || no "gate count"
grep -q 'GATE-BRAND' "$T/d1" && ok "gate: path match listed" || no "gate: GATE-BRAND missing"
grep -q 'GATE-OTHER' "$T/d1" && no "gate: unwatched path listed" || ok "gate: unwatched path left out"
grep -q 'OLD-BRAND' "$T/d1" && no "gate: commit older than the window listed" || ok "gate: window honoured"
grep -q '^## fork (.*): 1 of 2 new commits .*(not in gate)$' "$T/d1" && ok "fork: only fork-only commits counted" || no "fork count"
grep -q 'FORK-BRAND' "$T/d1" && ok "fork: its own path match listed" || no "fork: FORK-BRAND missing"
[ "$(grep -c 'GATE-BRAND' "$T/d1")" = 1 ] && ok "fork: base commit not repeated" || no "fork: GATE-BRAND listed twice"
grep -q '^## gone: FETCH-FAILED' "$T/d1" && ok "missing repo reported" || no "no FETCH-FAILED line"
grep -q '^## short: BAD-ROW' "$T/d1" && ok "a row without paths is reported" || no "no BAD-ROW line"
grep -v -e gone -e short "$T/list" > "$T/list2"
"$W" -d 8 -l "$T/list2" -s "$T/st" -o "$T/d2" 2> /dev/null; rc=$?
[ $rc = 0 ] && ok "all fetched exits 0 (negative control)" || no "clean run exited $rc"
grep -q '^## fork (.*): 1 of 2' "$T/d2" && ok "second run over the cache gives the same answer" || no "second run differs"
"$W" -d x -l "$T/list2" -s "$T/st" -o "$T/d3" 2> /dev/null; rc=$?
[ $rc = 2 ] && ok "bad -d exits 2" || no "bad -d exited $rc"
[ $bad = 0 ] && echo PASS || echo FAIL
exit $bad
