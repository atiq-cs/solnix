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

# The self-contained crypto shim (AES/RC4/MD5/SHA1/SHA256/HMAC/CMAC/key-wrap/
# Michael). It is a plain source (not orig/, not patched) that DEFINES the
# crypto primitives the ciphers reference. Compile it into the object set so the
# link attempt below can resolve them. It is NOT counted in the 18-of-18 .c tally.
crypto_ok=0
if [ -f "$here/n80211_crypto.c" ]; then
	if $CC -m64 -c -o "$OUT/obj/n80211_crypto.o" "$here/n80211_crypto.c" $INC \
	    2>"$OUT/obj/n80211_crypto.err"; then
		crypto_ok=1
	else
		echo "n80211_crypto FAILED to compile" >> "$OUT/errs.txt"
	fi
fi

# The route-(b) ADAPTERS that resolve the module's remaining internal
# cross-references so it links as a kmod with only kernel-supplied-at-load
# symbols undefined. Each is a plain source (not orig/, not patched), compiled
# into a SEPARATE object set ($OUT/adapt) so the net80211-only link above stays
# a clean measurement. They are NOT counted in the 18-of-18 .c tally.
#   n80211_rbtree.c  -- the 7 _rb_* RBT backing (tree.h has no out-of-line half)
#   n80211_mbuf.c    -- the mbuf ALLOCATION half (n80211_m_*/m_tag_find)
#   n80211_kcompat.c -- OpenBSD kernel prims (timeout_*/task_*/malloc/suser/...)
#   n80211_stack.c   -- GLDv3-downward stack (ether_*/if_*/ifmedia_*/rtm_*/ifq_*)
#   ../iwx/iwx_mbuf.c-- the driver's mbuf layer (iwx_m_*), already tested
mkdir -p "$OUT/adapt"
adapt_ok=1
for a in n80211_rbtree n80211_mbuf n80211_kcompat n80211_stack; do
	if [ -f "$here/$a.c" ]; then
		if ! $CC -m64 -c -o "$OUT/adapt/$a.o" "$here/$a.c" $INC \
		    2>"$OUT/adapt/$a.err"; then
			echo "$a FAILED to compile" >> "$OUT/errs.txt"
			adapt_ok=0
		fi
	fi
done
# the driver's own iwx_mbuf.c compiles in ITS TU (iwx -I only, no net80211 prelude)
if [ -f "$here/../iwx/iwx_mbuf.c" ]; then
	$CC -m64 -c -o "$OUT/adapt/iwx_mbuf.o" "$here/../iwx/iwx_mbuf.c" \
	    -D_KERNEL -D_SYSCALL32 -ffreestanding -nostdinc -I"$here/../iwx" \
	    -I$UTS/common -I$UTS/intel -I$UTS/i86pc -Wno-format \
	    2>"$OUT/adapt/iwx_mbuf.err" || { echo "iwx_mbuf FAILED" >> "$OUT/errs.txt"; adapt_ok=0; }
fi

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

# LINK ATTEMPT (ld -r partial link). Combines every net80211 object plus the
# crypto shim into one relocatable object and reports what stays undefined.
# This is NOT a kmod link and NOT a load: a -r object legitimately leaves the
# kernel's own primitives (bcopy/mutex/freemsg/...) undefined, to be resolved
# by the running kernel at load. What it PROVES is that net80211's OWN internal
# cross-references -- the 43 blocking symbols AND the crypto primitives the
# ciphers call -- are satisfied within the module. The remainder is
# categorized so a reader can see the module does not yet fully link.
echo
echo "=== ld -r LINK ATTEMPT (net80211 + crypto shim) ==="
if ld -r -o "$OUT/net80211_combined.o" "$OUT"/obj/*.o 2>"$OUT/ldr.err"; then
	echo "  ld -r: OK -> $(file -b "$OUT/net80211_combined.o" | cut -c1-40)"
	nm "$OUT/net80211_combined.o" | awk '$1=="U"{print $2}' | sort -u > "$OUT/combined_undef"
	cu=$(wc -l < "$OUT/combined_undef")
	crypto_u=$(grep -icE '^(AES_|rc4_|HMAC_|MD5|SHA[12]|michael_|aes_key)' "$OUT/combined_undef" || true)
	ie_u=$(grep -c '^ieee80211' "$OUT/combined_undef" || true)
	echo "  crypto primitives still undefined:      $crypto_u  (0 => crypto gate CLOSED)"
	echo "  blocking ieee80211_* still undefined:   $ie_u  (0 => symbol gate CLOSED)"
	echo "  total undefined (kernel prims + adapters): $cu"
	echo "  --- remaining undefined, categorized ---"
	echo "  kernel prims (kernel supplies at load): $(grep -cE '^(b?copy|bcmp|bzero|cmn_err|copyin|copyout|freemsg|gethrtime|getmicrouptime|htons|ntohs|mem(cpy|move|cmp|set)|mutex_|panic|printf|str(cmp|lcpy)|random_get_pseudo_bytes|threadp)$' "$OUT/combined_undef" || true)"
	echo "  mbuf layer (iwx_m_*/n80211_m_*, DECL/tested): $(grep -cE '^(iwx_m_|n80211_m_|m_tag_find)' "$OUT/combined_undef" || true)"
	echo "  GLDv3/stack adapters (ether/ifmedia/if_/timeout/task/_rb_/rtm/etc, DECL): $(grep -cE '^(ether|ifmedia|ifq_|if_|timeout_|task_|systq|_rb_|etherbroadcastaddr|rtm_|suser|ratecheck|iwx_bsd_|_GLOBAL_OFFSET_TABLE_)' "$OUT/combined_undef" || true)"
else
	echo "  ld -r FAILED:"; sed 's/^/    /' "$OUT/ldr.err" | head
fi

# FULL-MODULE LINK: the net80211 objects + crypto shim + ALL route-(b) adapters
# + the driver's iwx_mbuf.o. This is the kmod-link measurement: it PROVES the
# module's own internal cross-references (the 43 blocking symbols, the crypto
# primitives, the mbuf allocation layer, the RBT backing, and the GLDv3-downward
# stack) are all satisfied within the module, leaving ONLY the genuine
# kernel-supplied-at-load symbols undefined. A -r object legitimately leaves
# those (bcopy/mutex/freemsg/kmem/ddi_taskq/timeout/...) for the running kernel.
echo
echo "=== FULL-MODULE ld -r LINK (net80211 + crypto + rbtree + mbuf + kcompat + stack + iwx_mbuf) ==="
mod_undef=999
if [ "$adapt_ok" -eq 1 ] && \
   ld -r -o "$OUT/iwx_module.o" "$OUT"/obj/*.o "$OUT"/adapt/*.o 2>"$OUT/modldr.err"; then
	echo "  ld -r: OK -> $(file -b "$OUT/iwx_module.o" | cut -c1-40)"
	nm "$OUT/iwx_module.o" | awk '$1=="U"{print $2}' | sort -u > "$OUT/mod_undef"
	mod_undef=$(wc -l < "$OUT/mod_undef")
	# Partition the remainder. The kernel-at-load bucket is the WIDE set the
	# running kernel resolves (STREAMS, mutex, kmem, ddi_taskq, timeout, byte
	# order, atomics, string/mem, drv_*, random, the curthread global, the
	# GOT). ether_sprintf is illumos's OWN symbol (sys/ethernet.h), reached via
	# the compat macro-redirect, so it is kernel-supplied too.
	KERN_RE='^(adjmsg|allocb|atomic_[a-z_]+|b?copy|bcmp|bzero|cmn_err|copyin|copyout|copymsg|dupmsg|freeb|freemsg|linkb|msgpullup|pullupmsg|ddi_[a-z_]+|drv_priv|drv_usectohz|gethrtime|getmicrouptime|_GLOBAL_OFFSET_TABLE_|htons|ntohs|kmem_[a-z]+|mem(cpy|move|cmp|set)|mutex_[a-z]+|panic|printf|random_get_pseudo_bytes|str(cmp|lcpy|len)|threadp|timeout|untimeout|ether_sprintf)$'
	kern=$(grep -cE "$KERN_RE" "$OUT/mod_undef" || true)
	other=$(grep -vE "$KERN_RE" "$OUT/mod_undef" || true)
	echo "  module undefined: $mod_undef"
	echo "  of which kernel-supplied-at-load: $kern"
	if [ -n "$other" ]; then
		echo "  *** NON-kernel symbols STILL undefined (a .c is missing): ***"
		printf '%s\n' "$other" | sed 's/^/      /'
	else
		echo "  NON-kernel symbols still undefined: 0"
		echo "  => the module LINKS as a kmod: every undefined symbol is one the"
		echo "     running kernel supplies at load. NOT a load, NOT an attach --"
		echo "     phase-3 locking and the HARDWARE gate (firmware alive) remain."
	fi
else
	echo "  FULL-MODULE ld -r FAILED (or an adapter did not compile):"
	sed 's/^/    /' "$OUT/modldr.err" 2>/dev/null | head
	cat "$OUT/errs.txt" 2>/dev/null | grep FAILED | sed 's/^/    /'
fi

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

	echo
	echo "=== crypto shim self-test (published vectors + negative control) ==="
	if $CC -DN80211_CRYPTO_TEST -I"$here/compat" -o "$OUT/cryptotest" \
	    "$here/n80211_crypto.c" 2>"$OUT/cryptotest.build"; then
		if "$OUT/cryptotest" >"$OUT/cryptotest.out" 2>&1; then
			echo "  vectors: $(grep -c '^ok ' "$OUT/cryptotest.out") pass, ALL published test vectors"
		else
			echo "  CRYPTO VECTORS FAILED:"; grep '^FAIL' "$OUT/cryptotest.out" | sed 's/^/    /'
			exit 1
		fi
		# negative control: corrupt AES sbox[0], the shared root of AES/CMAC/
		# keywrap; the vectors MUST then fail. Proves the self-test can fail.
		sed 's/0x63,0x7c,0x77,0x7b,0xf2,0x6b/0x64,0x7c,0x77,0x7b,0xf2,0x6b/' \
		    "$here/n80211_crypto.c" > "$OUT/crypto_sab.c"
		if $CC -DN80211_CRYPTO_TEST -I"$here/compat" -o "$OUT/cryptosab" \
		    "$OUT/crypto_sab.c" 2>/dev/null && ! "$OUT/cryptosab" >/dev/null 2>&1; then
			echo "  control LIVE: sabotaging AES sbox[0] flips the vectors to FAIL"
		else
			echo "  CONTROL DEAD: sabotaged crypto still passed -- vectors cannot fail"
			exit 1
		fi
	else
		echo "  crypto self-test FAILED to build:"; sed 's/^/    /' "$OUT/cryptotest.build" | head
		exit 1
	fi

	echo
	echo "=== adapter self-tests (RB tree + mbuf-alloc, negative-controlled) ==="
	# n80211_rbtree.c: exhaustive + randomized RB invariants, negative control.
	if $CC -DN80211_RBTREE_TEST -I"$here/../iwx/compat" -o "$OUT/rbtest" \
	    "$here/n80211_rbtree_test.c" "$here/n80211_rbtree.c" 2>"$OUT/rbtest.build"; then
		if "$OUT/rbtest" >"$OUT/rbtest.out" 2>&1; then
			echo "  RB tree: $(grep -c '^ok ' "$OUT/rbtest.out") checks pass (2000 seq + 200k churn + nfind)"
		else
			echo "  RB TREE TESTS FAILED:"; sed 's/^/    /' "$OUT/rbtest.out" | tail -3; exit 1
		fi
		# negative control: the sabotage build must exit non-zero
		if $CC -DN80211_RBTREE_TEST -DN80211_RBTREE_SABOTAGE -I"$here/../iwx/compat" \
		    -o "$OUT/rbsab" "$here/n80211_rbtree_test.c" "$here/n80211_rbtree.c" 2>/dev/null &&
		   ! "$OUT/rbsab" >/dev/null 2>&1; then
			echo "  control LIVE: sabotaged RB build detects the broken invariant (FAIL)"
		else
			echo "  CONTROL DEAD: sabotaged RB tree passed -- validator cannot fail"; exit 1
		fi
	else
		echo "  RB tree self-test FAILED to build:"; sed 's/^/    /' "$OUT/rbtest.build" | head; exit 1
	fi
	# n80211_mbuf.c: gethdr/prepend/copydata/split/dup_pkt byte-verified + leak check.
	if $CC -DN80211_MBUF_TEST -I"$here/../iwx" -o "$OUT/mbtest" \
	    "$here/n80211_mbuf_test.c" "$here/n80211_mbuf.c" "$here/../iwx/iwx_mbuf.c" \
	    2>"$OUT/mbtest.build"; then
		if "$OUT/mbtest" >"$OUT/mbtest.out" 2>&1; then
			echo "  mbuf-alloc: $(grep -c '^ok ' "$OUT/mbtest.out") checks pass (leak-checked)"
		else
			echo "  MBUF TESTS FAILED:"; sed 's/^/    /' "$OUT/mbtest.out" | tail -3; exit 1
		fi
		if $CC -DN80211_MBUF_TEST -DN80211_MBUF_SABOTAGE -I"$here/../iwx" -o "$OUT/mbsab" \
		    "$here/n80211_mbuf_test.c" "$here/n80211_mbuf.c" "$here/../iwx/iwx_mbuf.c" 2>/dev/null &&
		   ! "$OUT/mbsab" >/dev/null 2>&1; then
			echo "  control LIVE: sabotaged mbuf build flips the over-read guard to FAIL"
		else
			echo "  CONTROL DEAD: sabotaged mbuf test passed -- guard cannot fail"; exit 1
		fi
	else
		echo "  mbuf self-test FAILED to build:"; sed 's/^/    /' "$OUT/mbtest.build" | head; exit 1
	fi

	echo
	echo "=== full-module-link negative control (a missing adapter .c must surface) ==="
	# Rename ifmedia_add in a COPY of n80211_stack.c and relink the module; the
	# symbol MUST then appear as a NON-kernel undefined, proving the module-link
	# check can report an unresolved adapter and is not blind.
	if [ -f "$OUT/adapt/n80211_stack.o" ]; then
		sabst=$(mktemp /tmp/n80-modsab.XXXXXX.c)
		sed 's/\bifmedia_add\b/ifmedia_add_SABOTAGED/g' "$here/n80211_stack.c" > "$sabst"
		if $CC -m64 -c -o "$sabst.o" "$sabst" $INC 2>/dev/null; then
			mkdir -p "$OUT/sabadapt"; cp "$OUT"/adapt/*.o "$OUT/sabadapt/"
			cp "$sabst.o" "$OUT/sabadapt/n80211_stack.o"
			if ld -r -o "$OUT/sabmod.o" "$OUT"/obj/*.o "$OUT"/sabadapt/*.o 2>/dev/null &&
			   nm "$OUT/sabmod.o" | awk '$1=="U"{print $2}' | grep -qx ifmedia_add; then
				echo "  control LIVE: dropping ifmedia_add makes it a non-kernel undefined"
			else
				echo "  CONTROL DEAD: the module-link check did not surface the drop"; exit 1
			fi
		fi
		rm -f "$sabst" "$sabst.o"
	fi
fi

# The verdict line makes 43/43 explicit and fails if it regresses below need.
if [ "$resolved" -eq "$need" ]; then
	echo
	if [ "$ok" -eq 18 ] && [ "$total_err" -eq 0 ]; then
		if [ "$mod_undef" != 999 ] && [ -z "$(grep -vE "$KERN_RE" "$OUT/mod_undef" 2>/dev/null)" ]; then
			echo "VERDICT: 43/43 blocking symbols resolved; ALL 18/18 net80211 .c compile"
			echo "         with 0 residual errors; the crypto shim resolves every cipher"
			echo "         primitive; and the FULL MODULE LINKS as a kmod: the ld -r of"
			echo "         net80211 + crypto + rbtree + mbuf + kcompat + stack + iwx_mbuf"
			echo "         leaves $mod_undef undefined, EVERY ONE a symbol the running kernel"
			echo "         supplies at load. 0 non-kernel symbols remain. This is a kmod"
			echo "         LINK, NOT a load and NOT an attach: phase-3 locking (SPLNET-AUDIT"
			echo "         + FINDINGS Finding 3) and the HARDWARE gate (firmware alive on the"
			echo "         X1) both remain."
		else
			echo "VERDICT: 43/43 resolved; 18/18 compile; net80211+crypto ld -r OK, but the"
			echo "         FULL MODULE LINK leaves non-kernel symbols undefined (see above)."
		fi
	else
		echo "VERDICT: $resolved of $need blocking symbols RESOLVED as real ELF .o global symbols."
		echo "         NOT a link (the module does not link) and NOT a load. $((18-ok)) of 18"
		echo "         net80211 files still do not compile; $total_err residual errors remain."
	fi
else
	echo
	echo "VERDICT: $resolved of $need resolved (was 43 -- a REGRESSION if this dropped)."
fi
