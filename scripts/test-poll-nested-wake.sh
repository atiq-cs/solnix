#!/usr/bin/env bash
# test-poll-nested-wake.sh -- regression check for scripts/patches/0012-poll-nested-wake.patch: an event inside an epoll
# that is itself in an epoll must wake a thread sleeping in the outer epoll_wait (cosmic-comp's calloop epoll holds the
# wayland server's epoll, which holds the client sockets; the greeter clock froze until the mouse moved). Runs ON illumos.
#
# usage: test-poll-nested-wake.sh [runs] [iters]
# Builds scripts/test-poll-nested-wake.c (or uses $NESTWAKE_BIN) and reads the RUNNING kernel's symbol table:
#   genunix defines pcache_wake (0012 in): every nested and flat run must lose 0 wakes   (default 8 runs x 20000)
#   no pcache_wake (stock kernel):         nested must lose > 0 and flat 0, i.e. the test can see the bug (8 x 300)
# Exit 0 iff the expectation for the running kernel holds. MAXD=<us> widens the write delay (default 0 us).
# Measured 2026-11-10 on one EC2 c5.2xlarge: stock 112/2400 nested, 0 flat; 0012 with only its first change (the parent
# wakeup) 4/320000 nested, which this test FAILs; full 0012 0/160000 nested and flat. Stock lixi 146/2400, dixi 462/2400.
set -u
here=$(cd "$(dirname "$0")" && pwd)
[ "$(uname -s)" = SunOS ] || { echo "SKIP: needs illumos (/dev/poll epoll)"; exit 0; }
if nm -p /dev/ksyms 2>/dev/null | awk '$NF=="pcache_wake"{f=1} END{exit !f}'; then fixed=1; else fixed=0; fi
nm -p /dev/ksyms 2>/dev/null | awk '$NF=="pcache_wake_parents"{f=1} END{exit !f}' \
  || { echo "FAIL: cannot read the running kernel's symbols (nm -p /dev/ksyms)"; exit 1; }
R=${1:-8}; N=${2:-$([ $fixed = 1 ] && echo 20000 || echo 300)}; D=${MAXD:-1}
T=$(mktemp -d /tmp/test-pnw.XXXXXX); trap 'find "$T" -depth -delete' EXIT
B=${NESTWAKE_BIN:-}
if [ -z "$B" ]; then
  cc=${CC:-$(command -v gcc || command -v cc)} || { echo "FAIL: no C compiler (set CC or NESTWAKE_BIN)"; exit 1; }
  B=$T/nestwake
  "$cc" -O2 -std=gnu11 -o "$B" "$here/test-poll-nested-wake.c" -lpthread -lsocket || { echo "FAIL: cannot build the test"; exit 1; }
fi
echo "kernel $(uname -v), pcache_wake $([ $fixed = 1 ] && echo defined || echo absent), $R runs x $N iters, write delay 0..$((D - 1)) us"
nl=0; fl=0; nr=0
i=0
while [ $i -lt "$R" ]; do  # no seq(1) on a solnix host
  i=$((i + 1))
  for m in nested flat; do
    o=$("$B" $m "$N" "$D"); rc=$?
    [ $rc -le 1 ] || { echo "FAIL: $m run $i: setup error rc=$rc"; exit 1; }
    l=$(echo "$o" | sed -n 's/.* lost=\([0-9]*\) .*/\1/p'); [ -n "$l" ] || { echo "FAIL: no result line: $o"; exit 1; }
    echo "  $o"
    if [ $m = nested ]; then nl=$((nl + l)); [ "$l" -gt 0 ] && nr=$((nr + 1)); else fl=$((fl + l)); fi
  done
done
[ $i -gt 0 ] || { echo "FAIL: no runs"; exit 1; }
echo "lost: nested $nl/$((R * N)) ($nr of $R runs > 0), flat $fl/$((R * N))"
[ $fl = 0 ] || { echo "FAIL: one epoll level lost a wake (not the nested bug)"; exit 1; }
if [ $fixed = 1 ]; then
  [ $nl = 0 ] && echo PASS || { echo "FAIL: nested epoll lost $nl wakes with 0012 in the kernel"; exit 1; }
else
  [ $nl -gt 0 ] && echo "PASS (negative control: the stock kernel loses nested wakes)" \
    || { echo "BAD: the stock kernel lost no nested wakes: this test cannot fail here"; exit 1; }
fi
