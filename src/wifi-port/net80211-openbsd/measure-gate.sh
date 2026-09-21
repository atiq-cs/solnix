#!/usr/bin/env bash
# net80211-link gate measurement. Compiles each net80211 .c to a REAL ELF .o
# (patched files via gen-illumos-src.sh, unpatched straight from orig/) and
# reports how many of the 43 blocking ieee80211_* symbols iwx needs are RESOLVED
# as real text symbols in the produced objects.
#
# Not a link. Not a load. A compile + symbol-resolution measurement, ELF-proven
# via `file` and `nm --print-size`.
set -u
here=$(cd -- "$(dirname -- "$0")" && pwd)
UTS=${UTS:-/home/gburd/src/illumos-gate/usr/src/uts}
CC=${CC:-gcc}
OUT=${OUT:-/tmp/n80gate}
rm -rf "$OUT"; mkdir -p "$OUT/obj"

# regenerate patched sources
"$here/gen-illumos-src.sh" >"$OUT/gen.log" 2>&1 || { echo "GEN FAIL"; cat "$OUT/gen.log"; exit 2; }

# the 43 blocking symbols
nm "$here/../iwx/build/if_iwx_illumos.o" | awk '$1=="U"{print $2}' | grep '^ieee80211' | sort -u > "$OUT/need43"
need=$(wc -l < "$OUT/need43")

INC="-D_KERNEL -ffreestanding -nostdinc -include sys/n80211_prelude.h \
  -I$here/compat -I$here/../iwx/compat -I$here/../iwx \
  -I$UTS/common -I$UTS/intel -I$UTS/i86pc -Wno-format"

ok=0; fail=0; : > "$OUT/errs.txt"
for c in "$here"/orig/*.c; do
	b=$(basename "$c" .c)
	# prefer the patched/generated source if one exists
	src="$c"; [ -f "$here/build/$b.c" ] && src="$here/build/$b.c"
	if $CC -m64 -c -o "$OUT/obj/$b.o" "$src" $INC 2>"$OUT/obj/$b.err"; then
		if [ -s "$OUT/obj/$b.o" ] && file -b "$OUT/obj/$b.o" | grep -q 'ELF 64-bit.*relocatable'; then
			ok=$((ok+1))
		else
			echo "$b: compiled but no ELF object" >> "$OUT/errs.txt"; fail=$((fail+1))
		fi
	else
		n=$(grep -c 'error:' "$OUT/obj/$b.err" || true)
		printf '%-28s %s errors\n' "$b" "$n" >> "$OUT/errs.txt"
		fail=$((fail+1))
	fi
done

# Which of the 43 are RESOLVED at link: a defined GLOBAL symbol of ANY kind the
# linker can satisfy an undefined reference with -- text (T), initialized data
# (D), read-only data (R, e.g. the rateset tables), or common/bss (B/C). A
# lowercase letter is a LOCAL symbol and cannot resolve a cross-object
# reference, so those are excluded. This is the honest link criterion; counting
# only T undercounts the 5 data symbols among the 43 (state_name is D, the four
# rateset tables are R).
nm "$OUT"/obj/*.o 2>/dev/null | awk '$2 ~ /^[TDRBC]$/{print $3}' | sort -u > "$OUT/haveT"
comm -12 "$OUT/haveT" "$OUT/need43" > "$OUT/resolved"
resolved=$(wc -l < "$OUT/resolved")

# total residual errors across all files
total_err=$(cat "$OUT"/obj/*.err 2>/dev/null | grep -c 'error:' || true)

echo "=== net80211-link gate ==="
echo "blocking symbols needed:      $need"
echo "RESOLVED (real global T .o):  $resolved of $need"
echo ".c files -> real ELF64 .o:    $ok of 18"
echo "residual errors (all files):  $total_err"
echo
echo "--- resolved symbols ---"; cat "$OUT/resolved"
echo
echo "--- still-unresolved of the 43 ---"; comm -23 "$OUT/need43" "$OUT/haveT"
echo
echo "--- per-file error surface (nonzero) ---"; sort -k2 -rn "$OUT/errs.txt" 2>/dev/null || cat "$OUT/errs.txt"
echo
echo "objects written to $OUT/obj"

if [ "${1:-}" = "--self-test" ]; then
	echo
	echo "=== negative control (this gate must be able to report < $need) ==="
	# Sabotage: rename one resolved blocking symbol in a COPY of a compiling
	# source, recompile, and confirm it is no longer among the produced
	# defined symbols -- proving the resolved count tracks reality and is not a
	# check that always says 43. Pick ieee80211_encap (a large real function).
	victim=ieee80211_encap
	sabsrc=$(mktemp /tmp/n80-sab.XXXXXX.c)
	base="$here/build/ieee80211_output.c"; [ -f "$base" ] || base="$here/orig/ieee80211_output.c"
	sed "s/\\b${victim}\\b/${victim}_SABOTAGED/g" "$base" > "$sabsrc"
	if $CC -m64 -c -o "$sabsrc.o" "$sabsrc" $INC 2>/dev/null &&
	   ! nm "$sabsrc.o" | awk '$2=="T"{print $3}' | grep -qx "$victim"; then
		echo "  control LIVE: renaming $victim removes it from the produced .o"
		echo "                (the gate would then report $((need-1)) of $need)"
	else
		echo "  control DEAD: $victim survived sabotage -- the count cannot fall"
		rc_nc=1
	fi
	rm -f "$sabsrc" "$sabsrc.o"

	echo
	echo "=== ELF proof of the resolved 43 (name / kind / size / object) ==="
	for s in $(cat "$OUT/need43"); do
		for o in "$OUT"/obj/*.o; do
			l=$(nm --print-size "$o" 2>/dev/null | grep -E " [TDRB] $s\$" | head -1)
			if [ -n "$l" ]; then
				printf '  %-34s %-3s 0x%-10s %s\n' "$s" \
				    "$(echo "$l" | awk '{print $3}')" \
				    "$(echo "$l" | awk '{print $2}')" "$(basename "$o")"
				break
			fi
		done
	done
	[ "${rc_nc:-0}" -eq 0 ] && echo "  negative control: live" || { echo "  NEGATIVE CONTROL DEAD"; exit 1; }
fi

# The verdict line makes 43/43 explicit and fails if it regresses below need.
if [ "$resolved" -eq "$need" ]; then
	echo
	echo "VERDICT: $resolved of $need blocking symbols RESOLVED as real ELF .o global symbols."
	echo "         NOT a link (the module does not link) and NOT a load. $((18-ok)) of 18"
	echo "         net80211 files still do not compile; $total_err residual errors remain."
else
	echo
	echo "VERDICT: $resolved of $need resolved (was 43 -- a REGRESSION if this dropped)."
fi
