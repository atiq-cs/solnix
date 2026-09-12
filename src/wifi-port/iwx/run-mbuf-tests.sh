#!/usr/bin/env bash
# Build and run the iwx mbuf translation unit checks, THEN prove they can fail.
#
# A suite that passes proves nothing until it has been shown to fail when the
# mechanism it tests is broken. Each sabotage below breaks exactly one real
# translation hazard from iwx_mbuf.h.
#
# TWO TRAPS THIS SCRIPT REFUSES TO FALL INTO, both of which produce a green run
# that means nothing:
#   1. A sabotage whose search text is absent patches nothing, the honest code
#      is rebuilt, and it passes -- which would be read as "not caught" or, with
#      inverted logic, as "caught". Every sabotage asserts its target text was
#      found and the file actually changed.
#   2. A sabotage that fails to COMPILE makes the test binary absent, and a
#      naive "did it exit non-zero" reads the build error as a caught bug. It is
#      not: it proves the compiler works, not that the suite detects the fault.
#      A sabotage is only counted when the build SUCCEEDS and the suite FAILS.
#
# Usage: ./run-mbuf-tests.sh          (from src/wifi-port/iwx/)
set -u

here=$(cd -- "$(dirname -- "$0")" && pwd)
cd "$here" || exit 1
work=$(mktemp -d /tmp/iwx-mbuf-neg.XXXXXX) || exit 1
CC=${CC:-gcc}
rc=0
caught=0
total=0

cleanup() {
	find "$work" -type f -delete 2>/dev/null
	find "$work" -type d -delete 2>/dev/null
}
trap cleanup EXIT

echo "=== 1. honest build ==="
mkdir -p "$work/base"
cp iwx_mbuf.c "$work/base/"
if "$CC" -O1 -o "$work/base/t" "$work/base/iwx_mbuf.c" "$here/iwx_mbuf_test.c" \
    -I"$work/base" -I"$here" 2>"$work/base/err"; then
	if "$work/base/t"; then
		echo "  mbuf suite:  PASS"
	else
		echo "  mbuf suite:  TESTS FAILED  <-- real regression, stop here"
		rc=1
	fi
else
	echo "  mbuf suite:  DID NOT COMPILE"
	head -5 "$work/base/err"
	rc=1
fi

# The mbuf_list layer (b_next vs b_cont) is header-only, so it is built against
# the same honest iwx_mbuf.c.
if "$CC" -O1 -o "$work/base/tl" "$work/base/iwx_mbuf.c" "$here/iwx_mlist_test.c" \
    -I"$work/base" -I"$here" 2>"$work/base/errl"; then
	if "$work/base/tl"; then
		echo "  mlist suite: PASS"
	else
		echo "  mlist suite: TESTS FAILED  <-- real regression"
		rc=1
	fi
else
	echo "  mlist suite: DID NOT COMPILE"
	head -5 "$work/base/errl"
	rc=1
fi

# sabotage <name> <literal-search> <literal-replace>
# Python does the substitution so the text is treated LITERALLY -- no delimiter
# or regex-metacharacter surprises (an earlier sed version silently died on the
# '||' inside one search string and the failure looked like a caught bug).
sabotage() {
	local name needle repl d
	# Separate statements ON PURPOSE. `local a=$1 d="...$a"` expands $a from the
	# ENVIRONMENT, not from $1, because all words are expanded before `local`
	# binds anything. In this shell $name is exported as "nix-shell-env", so the
	# one-line form silently pointed every sabotage at ONE shared directory and
	# each run re-tested the previous binary. Exactly the class of failure this
	# script exists to catch, in the script itself.
	name=$1
	needle=$2
	repl=$3
	d="$work/s_$name"
	total=$((total + 1))
	mkdir -p "$d"
	if ! SRC=iwx_mbuf.c DST="$d/iwx_mbuf.c" NEEDLE="$needle" REPL="$repl" \
	    python3 -c '
import os, sys
s = open(os.environ["SRC"]).read()
n = os.environ["NEEDLE"]
if s.count(n) != 1:
    sys.stderr.write("needle found %d times, need exactly 1\n" % s.count(n))
    sys.exit(1)
open(os.environ["DST"], "w").write(s.replace(n, os.environ["REPL"]))
' 2>"$d/patcherr"; then
		echo "  $name: SABOTAGE DID NOT APPLY ($(cat "$d/patcherr")) <-- test is blind"
		rc=1
		return
	fi
	if cmp -s iwx_mbuf.c "$d/iwx_mbuf.c"; then
		echo "  $name: SABOTAGE WAS A NO-OP <-- test is blind"
		rc=1
		return
	fi
	if ! "$CC" -O1 -o "$d/t" "$d/iwx_mbuf.c" "$here/iwx_mbuf_test.c" \
	    -I"$d" -I"$here" 2>"$d/err"; then
		# NOT a valid negative control: proves the compiler works, not the suite.
		echo "  $name: INVALID -- sabotage did not compile, so the suite was never asked"
		echo "      $(grep -m1 -E 'error' "$d/err" | cut -c1-100)"
		rc=1
		return
	fi
	local out ret
	out=$("$d/t" 2>&1); ret=$?
	if [ "$ret" -eq 0 ]; then		echo "  $name: NOT CAUGHT <-- the suite cannot detect this bug"
		rc=1
	else
		echo "  $name: caught -- $(printf '%s' "$out" | tail -1)"
		caught=$((caught + 1))
	fi
}

echo "=== 2. negative controls (each must COMPILE and then FAIL) ==="

# (a) The exact bug the port brief warns about: map m_data to b_rptr alone and
#     leave b_wptr where it was, so the length is stale. A #define of mbuf to
#     mblk_t does precisely this, compiles, and corrupts packets under load.
sabotage window_rptr_only \
	'	m->b_wptr = p + len;' \
	'	/* sabotaged: rptr moved, wptr left stale */'

# (b) Drop the upper bounds check: a bogus firmware mpdu_len then windows past
#     the end of the DMA buffer and the 802.11 stack parses adjacent memory.
sabotage window_no_upper_bound \
	'	if (len > (size_t)(DB_LIM(m) - p))
		return (B_FALSE);' \
	'	if (0)
		return (B_FALSE);'

# (c) Drop the lower bounds check: a negative descriptor offset is accepted.
sabotage window_no_lower_bound \
	'	if (p < DB_BASE(m) || p > DB_LIM(m))
		return (B_FALSE);' \
	'	if (0)
		return (B_FALSE);'

# (d) Stop deriving the segment length from the pointer pair -- the "second
#     source of truth" failure that makes m_len and b_wptr disagree.
sabotage len_not_derived \
	'	return ((size_t)(m->b_wptr - m->b_rptr));' \
	'	return (0);'

# (e) Shallow copy instead of deep. dupmsg() shares the cluster, so trimming
#     the copy silently corrupts the original still on the RX ring.
sabotage copy_shallow \
	'	return (copymsg((mblk_t *)m));' \
	'	return (dupmsg((mblk_t *)m));'

# (f) Leak the chain instead of consuming it when pullup falls back and fails,
#     breaking m_pullup's documented contract at if_iwx.c:10306.
sabotage pullup_leaks \
	'	n = msgpullup(m, (ssize_t)len);
	freemsg(m);
	return (n);' \
	'	n = msgpullup(m, (ssize_t)len);
	return (n);'

# (g) RX alloc that does not open the write window, so the device DMAs into a
#     buffer the driver believes is zero-length.
sabotage alloc_window_closed \
	'	m->b_wptr = DB_LIM(m);' \
	'	/* sabotaged: write window left closed */'

# (h) Silently adopt OpenBSD m_adj semantics (empty the buffer on over-trim)
#     where adjmsg() refuses, hiding the divergence the header documents.
sabotage adj_ignores_failure \
	'	return (adjmsg(m, (ssize_t)len) != 0 ? B_TRUE : B_FALSE);' \
	'	(void) adjmsg(m, (ssize_t)len);
	return (B_TRUE);'

# --- mbuf_list negative controls. Header-only, so the sabotage patches the
# --- header into the per-case directory and that copy shadows the real one.
mlist_sabotage() {
	local name needle repl d
	name=$1
	needle=$2
	repl=$3
	d="$work/m_$name"
	total=$((total + 1))
	mkdir -p "$d"
	if ! SRC=iwx_mlist.h DST="$d/iwx_mlist.h" NEEDLE="$needle" REPL="$repl" \
	    python3 -c '
import os, sys
s = open(os.environ["SRC"]).read()
n = os.environ["NEEDLE"]
if s.count(n) != 1:
    sys.stderr.write("needle found %d times, need exactly 1\n" % s.count(n))
    sys.exit(1)
open(os.environ["DST"], "w").write(s.replace(n, os.environ["REPL"]))
' 2>"$d/patcherr"; then
		echo "  mlist/$name: SABOTAGE DID NOT APPLY ($(cat "$d/patcherr")) <-- blind"
		rc=1
		return
	fi
	cp iwx_mbuf.c "$d/"
	# The test source must be copied INTO $d as well. `#include "iwx_mlist.h"`
	# resolves against the INCLUDING FILE'S OWN DIRECTORY before any -I path, so
	# compiling $here/iwx_mlist_test.c would pick up $here/iwx_mlist.h and the
	# sabotage would silently not apply -- a blind test reporting NOT CAUGHT for
	# a bug it never actually built. Copying the .c makes $d the quote-include
	# directory so the patched header wins.
	cp iwx_mlist_test.c iwx_mbuf.h iwx_mbuf_test_stubs.h "$d/"
	if ! "$CC" -O1 -o "$d/t" "$d/iwx_mbuf.c" "$d/iwx_mlist_test.c" \
	    -I"$d" 2>"$d/err"; then
		echo "  mlist/$name: INVALID -- did not compile, suite never asked"
		echo "      $(grep -m1 -E 'error' "$d/err" | cut -c1-100)"
		rc=1
		return
	fi
	local out ret
	out=$("$d/t" 2>&1); ret=$?
	if [ "$ret" -eq 0 ]; then
		echo "  mlist/$name: NOT CAUGHT <-- the suite cannot detect this bug"
		rc=1
	else
		echo "  mlist/$name: caught -- $(printf '%s' "$out" | tail -1)"
		caught=$((caught + 1))
	fi
}

# (i) THE central mbuf_list bug: build the batch with b_cont instead of b_next,
#     which concatenates two separate frames into one oversized corrupt frame.
mlist_sabotage enqueue_uses_bcont \
	'		ml->ml_tail->b_next = m;' \
	'		ml->ml_tail->b_cont = m;'

# (j) Fail to detach on dequeue, so freeing one packet frees the whole batch.
mlist_sabotage dequeue_no_detach \
	'	m->b_next = NULL;	/* detach, or the caller frees the whole batch */' \
	'	/* sabotaged: left attached */'

# (k) Purge that walks only the head packet, leaking the rest of the batch.
mlist_sabotage purge_leaks_batch \
	'	for (m = ml->ml_head; m != NULL; m = n) {' \
	'	for (m = ml->ml_head; m != NULL && m == ml->ml_head; m = n) {'

echo "=== 3. verdict ==="
echo "  sabotages caught: $caught/$total"
if [ "$rc" -eq 0 ]; then
	echo "CLEAN: honest build passes and all $total sabotages compiled and were caught."
else
	echo "DIRTY: see above."
fi
exit $rc
