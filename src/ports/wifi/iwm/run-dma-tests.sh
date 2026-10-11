#!/usr/bin/env bash
# Build and run the iwm DMA single-cookie check, THEN prove it can fail.
#
# A passing test proves nothing until it has been shown to fail when the
# property it guards is broken. The property: an RX/cmd DMA buffer must bind to
# exactly one cookie, and a page-straddling (multi-cookie) buffer must be
# rejected with EFBIG (docs/iwm-rx-contiguous-dma.md).
#
# Two traps this refuses, both of which make a green run meaningless:
#   1. A sabotage whose search text is absent patches nothing and the honest
#      code passes. Each sabotage asserts its target was found and the file
#      actually changed.
#   2. A sabotage that fails to COMPILE makes the binary absent; a naive "exit
#      non-zero" reads the build error as a caught bug. A sabotage counts only
#      when the build SUCCEEDS and the test FAILS.
#
# Usage: ./run-dma-tests.sh          (from src/ports/wifi/iwm/)
set -u
here=$(cd -- "$(dirname -- "$0")" && pwd)
cd "$here" || exit 1
work=$(mktemp -d /tmp/iwm-dma-neg.XXXXXX) || exit 1
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
cp iwm_dma_test.c "$work/base/"
if "$CC" -O1 -o "$work/base/t" "$work/base/iwm_dma_test.c" 2>"$work/base/err"; then
	if "$work/base/t"; then
		echo "  dma suite:  PASS"
	else
		echo "  dma suite:  TESTS FAILED  <-- real regression, stop here"
		rc=1
	fi
else
	echo "  dma suite:  DID NOT COMPILE"
	head -5 "$work/base/err"
	rc=1
fi

# sabotage <name> <literal-search> <literal-replace>
# awk does the substitution so the text is treated LITERALLY -- no regex
# metacharacter surprises (dixi has no python/perl; sed dies on '>' and '||').
# lit_replace enforces exactly one occurrence and a real change.
lit_replace() {
	# $1 src  $2 dst  (NEEDLE/REPL in the environment)
	# Pass needle/repl through FILES, not -v: illumos nawk rejects newlines in
	# -v values. Read them whole with RS set to a byte that cannot appear.
	printf '%s' "$NEEDLE" > "$2.needle"
	printf '%s' "$REPL" > "$2.repl"
	awk '
		BEGIN {
			RS = "\4";		# a byte that does not appear in C source
			nf = ARGV[1]; rf = ARGV[2]; src = ARGV[3];
			getline needle < nf;	# whole file: one record
			getline repl < rf;
			getline body < src;
			n = length(needle); s = body; out = ""; cnt = 0;
			while (n > 0 && (i = index(s, needle)) > 0) {
				out = out substr(s, 1, i - 1) repl;
				s = substr(s, i + n);
				cnt++;
			}
			out = out s;
			if (cnt != 1) { print "COUNT " cnt > "/dev/stderr"; exit 3; }
			printf "%s", out;
		}
	' "$2.needle" "$2.repl" "$1" > "$2"
	local r=$?
	rm -f "$2.needle" "$2.repl"
	return $r
}
sabotage() {
	local name needle repl d
	name=$1
	needle=$2
	repl=$3
	d="$work/s_$name"
	total=$((total + 1))
	mkdir -p "$d"
	if ! NEEDLE="$needle" REPL="$repl" \
	    lit_replace iwm_dma_test.c "$d/iwm_dma_test.c" 2>"$d/patcherr"; then
		echo "  $name: SABOTAGE DID NOT APPLY ($(cat "$d/patcherr")) <-- test is blind"
		rc=1
		return
	fi
	if cmp -s iwm_dma_test.c "$d/iwm_dma_test.c"; then
		echo "  $name: SABOTAGE WAS A NO-OP <-- test is blind"
		rc=1
		return
	fi
	if ! "$CC" -O1 -o "$d/t" "$d/iwm_dma_test.c" 2>"$d/err"; then
		echo "  $name: INVALID -- sabotage did not compile, so the suite was never asked"
		echo "      $(grep -m1 -E 'error' "$d/err" | cut -c1-100)"
		rc=1
		return
	fi
	local out ret
	out=$("$d/t" 2>&1); ret=$?
	if [ "$ret" -eq 0 ]; then
		echo "  $name: NOT CAUGHT <-- the suite cannot detect this bug"
		rc=1
	else
		echo "  $name: caught -- $(printf '%s' "$out" | tail -1)"
		caught=$((caught + 1))
	fi
}

echo "=== 2. negative controls (each must COMPILE and then FAIL) ==="

# (a) Pretend every bind is one cookie -- the exact blindness that let the real
#     2-cookie allocb buffer through. The straddle cases must then NOT be
#     rejected and the suite must fail.
sabotage cookie_count_always_one \
	'	first = off / PGSZ;
	last = (off + len - 1) / PGSZ;
	return ((unsigned)(last - first) + 1u);' \
	'	(void) off; (void) len;
	return (1u);'

# (b) Raise the segment limit so multi-cookie binds are accepted -- the "just
#     bump sgllen" non-fix the doc warns against (the hardware descriptor still
#     reads only dm_segs[0]).
sabotage maxsegs_bumped \
	'#define	MAXSEGS		1		/* RX/cmd map: dma_attr_sgllen == 1 */' \
	'#define	MAXSEGS		16'

# (c) Treat EFBIG as success in the decision -- a bind that should fail reports
#     ok and the straddle cases are no longer caught.
sabotage bind_never_fails \
	'	if (nck > MAXSEGS)
		return (EFBIG);
	return (0);' \
	'	(void) nck;
	return (0);'

echo "=== 3. verdict ==="
echo "  sabotages caught: $caught/$total"
if [ "$rc" -eq 0 ]; then
	echo "CLEAN: honest build passes and all $total sabotages compiled and were caught."
else
	echo "DIRTY: see above."
fi
exit $rc
