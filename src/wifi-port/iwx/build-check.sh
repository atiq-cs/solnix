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

# The driver that is actually compiled is the GENERATED one. openbsd-orig/ is
# read-only, so the mbuf/802.11 rewrite lives in patches/if_iwx.illumos.patch and
# gen-illumos-src.sh materialises it.
DRV="$here/build/if_iwx_illumos.c"
DRVOBJ="$here/build/if_iwx_illumos.o"

if [ ! -d "$UTS/common/sys" ]; then
	echo "FAIL: illumos headers not found at $UTS"
	echo "      set UTS=/path/to/illumos-gate/usr/src/uts"
	exit 2
fi

compile_errs() {  # $1 = extra cflags; prints the raw compiler stderr
	# shellcheck disable=SC2086
	"$CC" -m64 -fsyntax-only "$DRV" \
	    -D_KERNEL -ffreestanding -nostdinc \
	    -include sys/iwx_prelude.h -include "$here/iwx_mbuf_adapter.h" \
	    -I"$here/compat" -I"$here/openbsd-orig" -I"$here" \
	    -I"$UTS/common" -I"$UTS/intel" -I"$UTS/i86pc" \
	    -Wno-format $1 2>&1
}

echo "=== regenerating the derived driver source ==="
if ! "$here/gen-illumos-src.sh" >/tmp/iwx_gen.log 2>&1; then
	echo "  FAILED to generate $DRV:"
	sed 's/^/    /' /tmp/iwx_gen.log
	exit 2
fi
sed 's/^/  /' /tmp/iwx_gen.log


echo "=== iwx_mbuf.c as a real illumos kernel object ==="
if "$CC" -m64 -c -o /tmp/iwx_mbuf_gate.o "$here/iwx_mbuf.c" \
    -D_KERNEL -D_SYSCALL32 -ffreestanding -nostdinc -I"$here" \
    -I"$UTS/common" -I"$UTS/intel" -I"$UTS/i86pc" -Wno-format \
    -Werror=implicit-function-declaration 2>/tmp/iwx_mbuf_gate.err; then
	syms=$(nm /tmp/iwx_mbuf_gate.o | grep -c ' T ')
	echo "  COMPILES: $syms text symbols"
	# Every undefined symbol must be a genuine illumos kernel entry point.
	# memmove is declared in uts/common/sys/systm.h:509 and lives in the
	# kernel's own libc, alongside bcopy/bzero.
	bad=$(nm /tmp/iwx_mbuf_gate.o | awk '$1=="U"{print $2}' |
	    grep -vE '^(allocb|freemsg|freeb|adjmsg|pullupmsg|msgpullup|copymsg|dupmsg|linkb|memmove)$' || true)
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

# THE ACTUAL TARGET: does the driver produce an object file? -fsyntax-only can
# pass on code that fails in codegen, so this is a separate and stronger claim
# and is checked with real -c.
echo "=== if_iwx.c -> object file (the real target, not -fsyntax-only) ==="
rm -f "$DRVOBJ"
if "$CC" -m64 -c -o "$DRVOBJ" "$DRV" \
    -D_KERNEL -ffreestanding -nostdinc \
    -include sys/iwx_prelude.h -include "$here/iwx_mbuf_adapter.h" \
    -I"$here/compat" -I"$here/openbsd-orig" -I"$here" \
    -I"$UTS/common" -I"$UTS/intel" -I"$UTS/i86pc" \
    -Wno-format 2>/tmp/iwx_drv.err; then
	# An exit status of 0 with no object is possible if the output path is
	# wrong, so check the artifact, not the status. `file` is used rather than
	# stat(1), which does not exist on illumos.
	if [ ! -s "$DRVOBJ" ]; then
		echo "  COMPILER SUCCEEDED BUT PRODUCED NO OBJECT -- check the -o path"
		rc=1
	else
		echo "  COMPILES: $(file -b "$DRVOBJ" | cut -c1-46)"
		echo "            $(nm "$DRVOBJ" | grep -c ' T ') text symbols," \
		    "$(nm "$DRVOBJ" | awk '$1=="U"' | wc -l | tr -d ' ') undefined"
	fi
else
	echo "  DOES NOT COMPILE:"
	grep -m3 'error:' /tmp/iwx_drv.err | sed 's/^/    /'
	rc=1
fi

# The error surface is now ZERO, so the old "is every failing line an enumerated
# mbuf rewrite site" check has nothing to chew on and would pass vacuously. It is
# replaced by two checks that can still fail:
#
#   1. the count must be zero (a regression raises it);
#   2. the OpenBSD mbuf field names must be GONE from the generated source, which
#      is what "the rewrite actually happened" means. Without this, a patch that
#      silently stopped applying would still show 0 errors -- because a
#      never-generated build/ directory would just be stale.
if [ "$n" -ne 0 ]; then
	echo "  REGRESSION: the driver had 0 errors and now has $n:"
	printf '%s\n' "$errs" | head -5 | sed 's/^/    /'
	rc=1
fi

echo "=== the mbuf rewrite must actually be present in the generated source ==="
# Each of these is an OpenBSD mbuf field access that MUST have been rewritten.
#
# Comment lines are excluded, and NOT by an "ILLUMOS appears somewhere" filter --
# that was the first version and it was wrong in both directions: the rewrite
# comments quote the old code ("m->m_len = len\" becomes...") and would be
# reported as unrewritten, while a real unrewritten access on a line that also
# said ILLUMOS would be hidden. Stripping comments first is the check that
# actually asks the question. gcc -fpreprocessed keeps the code and drops the
# comments without expanding anything else.
stripped=$(mktemp /tmp/iwx-nocomment.XXXXXX.c)
"$CC" -fpreprocessed -dD -E -P "$DRV" > "$stripped" 2>/dev/null
left=$(grep -nE '(m|m0)->(m_len|m_data|m_pkthdr|m_flags|m_ext)' "$stripped" || true)
if [ -n "$left" ]; then
	echo "  UNREWRITTEN mbuf field accesses remain:"
	printf '%s\n' "$left" | head -5 | sed 's/^/    /'
	rc=1
else
	echo "  no m_len / m_data / m_pkthdr / m_flags / m_ext accesses remain"
	echo "  (checked against a comment-stripped copy, so the rewrite notes that"
	echo "   quote the old code do not read as false positives)"
fi
rm -f "$stripped"

# And the replacements must be PRESENT -- the converse check, so that deleting a
# call site rather than translating it is not scored as success.
missing=""
for fn in iwx_m_alloc iwx_m_set_window iwx_m_shift_right iwx_m_len \
    iwx_m_pktlen iwx_m_at iwx_m_copy iwx_m_defrag iwx_m_take_cookie; do
	grep -q "$fn" "$DRV" || missing="$missing $fn"
done
if [ -n "$missing" ]; then
	echo "  MISSING translation calls in the generated source:$missing"
	echo "  -> a site was deleted rather than translated"
	rc=1
else
	echo "  all 9 translation entry points are called by the generated driver"
fi

# The old "every error must be mbuf-CLASS" check assumed a non-empty error set as
# the steady state. At 0 errors it passes trivially, so it is dropped rather than
# left in place looking like a live check.

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
	ablerrs=$("$CC" -m64 -fsyntax-only "$DRV" \
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

	# 2. Injecting a fresh error must be seen. Proves the count check can fail.
	#    Done via an extra -include so no source file is touched.
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

	# 4. The unrewritten-field check must be able to fire. Reintroduce one
	#    OpenBSD field access into a COPY of the generated source and confirm
	#    the grep finds it. Without this, the check passes on any file that
	#    simply does not mention mbufs -- including an empty one.
	nc4=$(mktemp /tmp/iwx-nc4.XXXXXX.c)
	cp "$DRV" "$nc4"
	printf 'int iwx_negctl_field(struct mbuf *m) { return (m->m_len); }\n' >> "$nc4"
	nc4s=$(mktemp /tmp/iwx-nc4s.XXXXXX.c)
	"$CC" -fpreprocessed -dD -E -P "$nc4" > "$nc4s" 2>/dev/null
	if grep -qE '(m|m0)->(m_len|m_data|m_pkthdr|m_flags|m_ext)' "$nc4s"; then
		echo "  unrewritten-field control: reintroducing m->m_len IS detected"
	else
		echo "  unrewritten-field control: THE FIELD GREP CANNOT SEE m->m_len"
		nc_rc=1
	fi
	rm -f "$nc4s"
	# And it must still COMPILE-FAIL, proving the field really is unmapped
	# rather than merely absent from the source.
	if "$CC" -m64 -fsyntax-only "$nc4" -D_KERNEL -ffreestanding -nostdinc \
	    -include sys/iwx_prelude.h -include "$here/iwx_mbuf_adapter.h" \
	    -I"$here/compat" -I"$here/openbsd-orig" -I"$here" \
	    -I"$UTS/common" -I"$UTS/intel" -I"$UTS/i86pc" -Wno-format \
	    >/dev/null 2>&1; then
		echo "  field-is-unmapped control: m->m_len COMPILED -- a field macro has"
		echo "                             crept in and the safety property is GONE"
		nc_rc=1
	else
		echo "  field-is-unmapped control: m->m_len is still a hard compile error"
	fi
	rm -f "$nc4"

	# 5. The missing-translation-call check must be able to fire, i.e. it must
	#    be looking at the generated file and not at something always present.
	if grep -q iwx_m_shift_right /dev/null; then
		echo "  missing-call control: grep matched an EMPTY file -- check is broken"
		nc_rc=1
	else
		echo "  missing-call control: the same grep reports absence on an empty file"
	fi

	# 6. The object gate must be able to fail. Compile a deliberately broken
	#    translation unit through the identical command and require no object.
	nc6=$(mktemp /tmp/iwx-nc6.XXXXXX.c)
	printf 'int iwx_negctl_broken(void) { return (this_symbol_does_not_exist()); }\n' > "$nc6"
	if "$CC" -m64 -c -o "$nc6.o" "$nc6" -D_KERNEL -ffreestanding -nostdinc \
	    -Werror=implicit-function-declaration \
	    -I"$UTS/common" -I"$UTS/intel" -I"$UTS/i86pc" 2>/dev/null; then
		echo "  object-gate control: A BROKEN FILE PRODUCED AN OBJECT -- the -c"
		echo "                       gate cannot distinguish success from failure"
		nc_rc=1
	else
		echo "  object-gate control: a broken translation unit yields no object"
	fi
	rm -f "$nc6" "$nc6.o"

	[ "$nc_rc" -eq 0 ] && echo "  negative controls: all live" || rc=1
fi

echo "=== verdict ==="
if [ "$rc" -eq 0 ]; then
	echo "OK: $n residual errors; if_iwx.c compiles to an object file."
	echo "    LADDER: compiles YES | links NO | loads NO | attaches NO | sees device NO"
else
	echo "PROBLEM: see above."
fi
exit $rc
