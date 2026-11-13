#!/bin/sh
# scripts/test-start-cosmic-log.sh [snippet]: pkgs/illumos/graphics/start-cosmic-log.sh (spliced into start-cosmic) sends the
# session's output to $XDG_STATE_HOME/cosmic-session/session-<time>.log and keeps the newest 5. Any POSIX sh (illumos /sbin/sh
# too); no session needed. Negative control: the same steps without the snippet leave no log.
set -u
S=${1:-$(dirname "$0")/../pkgs/illumos/graphics/start-cosmic-log.sh}
T=$(mktemp -d) || exit 1; fails=0
trap 'rm -f "$T"/state/cosmic-session/* "$T"/empty.sh; rmdir "$T"/state/cosmic-session "$T"/state "$T" 2>/dev/null' EXIT
ok() { echo "ok   $*"; }; no() { echo "FAIL $*"; fails=$((fails + 1)); }
run() { XDG_STATE_HOME=$2 HOME=$T sh -c ". \"$1\"; echo marker-out; echo marker-err >&2; echo bt=\$RUST_BACKTRACE"; }
o=$(run "$S" "$T/state"); D=$T/state/cosmic-session
[ -z "$o" ] && ok "stdout is not the terminal" || no "stdout still on the terminal: $o"
l=$(ls "$D"/session-*.log 2>/dev/null | head -1)
[ -n "$l" ] && grep -q '^start-cosmic: ' "$l" && grep -q marker-out "$l" && grep -q marker-err "$l" &&
    ok "stdout+stderr in ${l#$T/}" || no "no log with both streams"
grep -q '^bt=1$' "$l" 2>/dev/null && ok "RUST_BACKTRACE=1" || no "RUST_BACKTRACE not set"
# rotation: 7 old logs + this login -> 5 left, the newest ones
i=1; while [ $i -le 7 ]; do : > "$D/session-2026010${i}T000000.log"; touch -t 20260101000$i "$D/session-2026010${i}T000000.log"; i=$((i + 1)); done
sleep 1; run "$S" "$T/state" > /dev/null
n=$(ls "$D"/session-*.log | wc -l | tr -d ' ')
[ "$n" = 5 ] && ok "5 logs kept" || no "$n logs kept, want 5"
[ -e "$D/session-20260107T000000.log" ] && [ ! -e "$D/session-20260101T000000.log" ] && ok "oldest removed first" ||
    no "rotation removed the wrong logs"
# state dir not writable: the session still starts, on the old stdout
o=$(XDG_STATE_HOME=/nonexistent/x HOME=/nonexistent sh -c ". \"$S\"; echo still-here" 2>/dev/null)
[ "$o" = still-here ] && ok "unwritable state dir: session starts, output unchanged" || no "unwritable state dir broke the start ($o)"
# negative control: without the snippet nothing is logged
: > "$T/empty.sh"; o=$(run "$T/empty.sh" "$T/state2" 2>&1)
[ ! -d "$T/state2" ] && echo "$o" | grep -q marker-out && ok "NEG: no snippet, no log (the check can fail)" || no "NEG control did not behave"
[ $fails = 0 ] && { echo "RESULT PASS"; exit 0; } || { echo "RESULT FAIL ($fails)"; exit 1; }
