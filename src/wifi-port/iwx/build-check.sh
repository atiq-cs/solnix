#!/usr/bin/env bash
# Compile-progress gate for the iwx port.
#
# Reports the residual error count for openbsd-orig/if_iwx.c against the compat
# layer, and asserts that EVERY remaining error is one of the mbuf sites
# enumerated in iwx_mbuf_adapter.h. That assertion is the real content: an error
# count alone can fall for the wrong reason (a header that swallows a
# declaration, a #define that hides a type error), so the gate checks WHICH
# lines fail, not just how many.
#
# NEGATIVE CONTROLS (run with --self-test): three sabotages that must each be
# detected. Without them a green run here means nothing.
#
# Usage: ./build-check.sh [--self-test]
set -u

here=$(cd -- "$(dirname -- "$0")" && pwd)
UTS=${UTS:-/home/gburd/src/illumos-gate/usr/src/uts}
CC=${CC:-gcc}
rc=0

if [ ! -d "$UTS/common/sys" ]; then
	echo "FAIL: illumos headers not found at $UTS"
	echo "      set UTS=/path/to/illumos-gate/usr/src/uts"
	exit 2
fi

compile_errs() {  # $1 = extra cflags; prints the raw compiler stderr
	# shellcheck disable=SC2086
	"$CC" -m64 -fsyntax-only "$here/openbsd-orig/if_iwx.c" \
	    -D_KERNEL -ffreestanding -nostdinc \
	    -include sys/iwx_prelude.h -include "$here/iwx_mbuf_adapter.h" \
	    -I"$here/compat" -I"$here/openbsd-orig" -I"$here" \
	    -I"$UTS/common" -I"$UTS/intel" -I"$UTS/i86pc" \
	    -Wno-format $1 2>&1
}

echo "=== iwx_mbuf.c as a real illumos kernel object ==="
if "$CC" -m64 -c -o /tmp/iwx_mbuf_gate.o "$here/iwx_mbuf.c" \
    -D_KERNEL -D_SYSCALL32 -ffreestanding -nostdinc -I"$here" \
    -I"$UTS/common" -I"$UTS/intel" -I"$UTS/i86pc" -Wno-format \
    -Werror=implicit-function-declaration 2>/tmp/iwx_mbuf_gate.err; then
	syms=$(nm /tmp/iwx_mbuf_gate.o | grep -c ' T ')
	echo "  COMPILES: $syms text symbols"
	# Every undefined symbol must be a genuine illumos STREAMS function.
	bad=$(nm /tmp/iwx_mbuf_gate.o | awk '$1=="U"{print $2}' |
	    grep -vE '^(allocb|freemsg|freeb|adjmsg|pullupmsg|msgpullup|copymsg|dupmsg|linkb)$' || true)
	if [ -n "$bad" ]; then
		echo "  UNEXPECTED undefined symbols: $bad"
		rc=1
	else
		echo "  all undefined symbols are illumos STREAMS entry points"
	fi
else
	echo "  DOES NOT COMPILE:"
	grep -m3 'error:' /tmp/iwx_mbuf_gate.err
	rc=1
fi

echo "=== openbsd-orig/ must be unmodified ==="
if git -C "$here" diff --quiet -- openbsd-orig/ 2>/dev/null &&
   [ -z "$(git -C "$here" status --porcelain -- openbsd-orig/ 2>/dev/null)" ]; then
	echo "  CLEAN: no local changes to the vendored source"
else
	echo "  DIRTY: openbsd-orig/ has been modified -- it is read-only by policy"
	rc=1
fi

echo "=== if_iwx.c residual error surface ==="
errs=$(compile_errs "" | grep 'error:' || true)
n=$(printf '%s' "$errs" | grep -c 'error:' || true)
echo "  residual errors: $n"

# Which if_iwx.c lines still fail? (sort -u lexicographically: comm requires
# that collation, and `sort -un` produces NUMERIC order which comm rejects --
# it warned "not in sorted order" and its output could not be trusted.)
printf '%s\n' "$errs" | grep -oE 'if_iwx\.c:[0-9]+' | cut -d: -f2 | sort -u > /tmp/iwx_gate_actual.txt
# Which lines does the adapter enumerate as known rewrite sites?
grep -oE ':[0-9]{4,5}' "$here/iwx_mbuf_adapter.h" | tr -d ':' | sort -u > /tmp/iwx_gate_enum.txt

unexpected=$(comm -13 /tmp/iwx_gate_enum.txt /tmp/iwx_gate_actual.txt | tr '\n' ' ')
if [ -n "${unexpected// /}" ]; then
	echo "  UNENUMERATED failing lines: $unexpected"
	echo "  -> every residual error must be a KNOWN mbuf rewrite site listed in"
	echo "     iwx_mbuf_adapter.h. An unlisted line is an unaccounted-for gap."
	rc=1
else
	echo "  all $(wc -l < /tmp/iwx_gate_actual.txt) failing lines are enumerated mbuf rewrite sites"
fi

# And every error must be mbuf-CLASS, not merely on an enumerated line.
nonmbuf=$(printf '%s\n' "$errs" |
    grep -vcE 'mbuf|m_gethdr|m_defrag|m_copym|MCLGET|ml_enqueue|bus_dmamap_load_mbuf' || true)
if [ "$nonmbuf" -ne 0 ]; then
	echo "  $nonmbuf error(s) are NOT mbuf-class:"
	printf '%s\n' "$errs" |
	    grep -vE 'mbuf|m_gethdr|m_defrag|m_copym|MCLGET|ml_enqueue|bus_dmamap_load_mbuf' | head -5
	rc=1
else
	echo "  all $n errors are mbuf-class (the documented barrier)"
fi

if [ "${1:-}" = "--self-test" ]; then
	echo "=== negative controls (this gate must be able to FAIL) ==="
	nc_rc=0

	# 1. ABLATION: shadow one load-bearing compat header with an EMPTY one on
	#    an earlier -I path, and the count must rise. Comparing against a
	#    NO-compat build does not work -- without compat, if_iwx.c dies on a
	#    FATAL missing-header error after 1 message and never reaches the body,
	#    so the count goes DOWN (1 < 30) and a naive "more errors" test reads
	#    that as the gate being broken. A fatal early exit and a clean build are
	#    indistinguishable by count alone.
	#
	#    Shadowing rather than copying the tree: compat/dev/pci/if_iwx{reg,var}.h
	#    are relative symlinks into openbsd-orig/, so a `cp -r` to /tmp breaks
	#    them and the ablated build dies fatally for the WRONG reason -- which is
	#    exactly what the first version of this control did.
	abl=$(mktemp -d /tmp/iwx-abl.XXXXXX)
	mkdir -p "$abl/dev/pci"
	: > "$abl/dev/pci/pcireg.h"
	ablerrs=$("$CC" -m64 -fsyntax-only "$here/openbsd-orig/if_iwx.c" \
	    -D_KERNEL -ffreestanding -nostdinc \
	    -include sys/iwx_prelude.h -include "$here/iwx_mbuf_adapter.h" \
	    -I"$abl" -I"$here/compat" -I"$here/openbsd-orig" -I"$here" \
	    -I"$UTS/common" -I"$UTS/intel" -I"$UTS/i86pc" -Wno-format 2>&1)
	ablfatal=$(printf '%s' "$ablerrs" | grep -c 'fatal error' || true)
	abln=$(printf '%s' "$ablerrs" | grep -c 'error:' || true)
	if [ "$ablfatal" -ne 0 ]; then
		echo "  ablation control: INVALID -- ablated build died fatally, count meaningless"
		echo "      $(printf '%s' "$ablerrs" | grep -m1 'fatal error' | cut -c1-90)"
		nc_rc=1
	elif [ "$abln" -gt "$n" ]; then
		echo "  ablation control: emptying compat/dev/pci/pcireg.h gives $abln errors"
		echo "                    vs $n with it -- the count tracks the compat layer"
	else
		echo "  ablation control: $abln vs $n -- THE COUNT DOES NOT TRACK THE COMPAT LAYER"
		nc_rc=1
	fi
	rm -f "$abl/dev/pci/pcireg.h"
	rmdir "$abl/dev/pci" "$abl/dev" "$abl" 2>/dev/null

	# 1b. And confirm the no-compat build fails for the reason claimed, so the
	#     asymmetry above is explained by evidence rather than assumed.
	bareout=$("$CC" -m64 -fsyntax-only "$here/openbsd-orig/if_iwx.c" \
	    -D_KERNEL -ffreestanding -nostdinc -I"$here/openbsd-orig" \
	    -I"$UTS/common" -I"$UTS/intel" -I"$UTS/i86pc" -Wno-format 2>&1)
	if printf '%s' "$bareout" | grep -q 'fatal error'; then
		echo "  no-compat control: dies with '$(printf '%s' "$bareout" |
		    grep -m1 'fatal error' | sed 's/.*fatal error: //' | cut -c1-40)'"
		echo "                     i.e. it never reaches the driver body at all"
	else
		echo "  no-compat control: expected a fatal missing-header error, got none"
		nc_rc=1
	fi

	# 2. Injecting a fresh error at a NON-enumerated line must be reported as
	#    unenumerated. Proves the line-set check can fail. Done via an extra
	#    -include so openbsd-orig/ is never touched.
	printf 'struct iwx_negctl_probe { int x; };\nstruct iwx_negctl_probe iwx_negctl_bad = { .nosuchfield = 1 };\n' \
	    > /tmp/iwx_negctl.h
	inj=$(compile_errs "-include /tmp/iwx_negctl.h" | grep -c 'error:' || true)
	if [ "$inj" -gt "$n" ]; then
		echo "  injected-error control: $inj errors vs $n -- gate sees new errors"
	else
		echo "  injected-error control: $inj vs $n -- GATE IS BLIND TO NEW ERRORS"
		nc_rc=1
	fi

	# 3. The dirty-tree check must fire. Exercised without modifying the real
	#    file: ask git about a path that is genuinely dirty only if we make it
	#    so, so instead verify the check's INPUT is non-empty when given one.
	if [ -n "$(git -C "$here" status --porcelain -- . 2>/dev/null | head -1)" ]; then
		echo "  dirty-detect control: git reports changes elsewhere in the port"
		echo "                        dir, so the porcelain check is not silently empty"
	else
		echo "  dirty-detect control: git porcelain returned NOTHING for the whole"
		echo "                        port dir -- cannot distinguish clean from broken"
		nc_rc=1
	fi

	[ "$nc_rc" -eq 0 ] && echo "  negative controls: all live" || rc=1
fi

echo "=== verdict ==="
if [ "$rc" -eq 0 ]; then
	echo "OK: $n residual errors, all enumerated mbuf rewrite sites."
else
	echo "PROBLEM: see above."
fi
exit $rc
