#!/bin/sh
# simd-gate.sh -- fail unless the linked i915 module uses SIMD/x87 only inside
# fpu_kernel_enter/fpu_kernel_exit sections.
#
# WHY: illumos kernel code is built -mno-mmx -mno-sse (Makefile.master NO_SIMD).
# Kernel threads run with CR0.TS set, so an FPU/SIMD instruction outside a
# kernel_fpu_begin/end section is a #NM trap (panic), and in a user thread's
# kernel context it silently clobbers that thread's live FPU state
# (uts/intel/os/fpu.c). Every i915/drm object is compiled -mno-mmx -mno-sse;
# that removes all compiler-generated SIMD but not inline asm. OpenBSD's
# i915_memcpy.c and drm_cache.c carry inline-asm movntdqa copies bracketed by
# kernel_fpu_begin/end (= fpu_kernel_enter/exit, obsd-compat/obsd_glue.c).
# Those two objects are the only ones allowed SIMD, and only bracketed.
#
# Usage: simd-gate.sh MODULE "EXEMPT.o ..." OBJ...
#   MODULE  the linked module (ld -r output)
#   EXEMPT  basenames of the objects allowed bracketed SIMD
#   OBJ     every object linked into MODULE (exempt ones included)
#   env: OBJDUMP (gobjdump)
# Checks (each failure line starts "SIMD-GATE FAIL (<check>)"):
#   object   no SIMD/x87 instruction in any non-exempt object
#   count    the module holds exactly the exempt objects' SIMD instructions,
#            and more than zero (a classifier that matches nothing would pass
#            every other check vacuously)
#   function every SIMD instruction of the module lies in a function that one
#            of the exempt objects defines
#   bracket  in address order within its function, every SIMD instruction
#            follows a call/jmp to fpu_kernel_enter with no fpu_kernel_exit in
#            between, and every enter is closed by an exit before the
#            function ends (call targets read from the disassembly's resolved
#            target or, in an unlinked object, its R_X86_64_PLT32/PC32 reloc)
#   symbol   exactly one fpu_kernel_enter and one fpu_kernel_exit in the module
set -u
mod=$1 exempt=$2; shift 2
: "${OBJDUMP:=gobjdump}"
command -v "$OBJDUMP" > /dev/null || { echo "SIMD-GATE FAIL (tool): no $OBJDUMP"; exit 2; }
[ -f "$mod" ] || { echo "SIMD-GATE FAIL (tool): no module $mod"; exit 2; }
t=$(mktemp -d "${TMPDIR:-/tmp}/simdgate.XXXXXX") || exit 2
trap 'find "$t" -depth -delete 2>/dev/null' EXIT

# The classifier and the walker, shared by every check. Input: objdump -dr
# --no-show-raw-insn. MODE=count prints "<total>"; MODE=walk prints one line
# per SIMD instruction "fn<TAB>addr<TAB>inside<TAB>insn" and "OPEN<TAB>fn"
# for an enter left open at a function's end.
cat > "$t/walk.awk" << 'EOF'
function mnem(txt,   n, w, i) {
	n = split(txt, w, /[ \t]+/)
	for (i = 1; i <= n; i++) {
		if (w[i] == "") continue
		if (w[i] ~ /^(lock|rep|repz|repe|repnz|repne|cs|ds|es|fs|gs|ss|data16|data32|addr32|notrack|bnd|xacquire|xrelease)$/ || w[i] ~ /^rex/) continue
		return w[i]
	}
	return ""
}
# SIMD/x87: any MMX/SSE/AVX/AVX-512 register operand, any x87 (f*) or
# AVX-512 mask (k*) mnemonic, or an FPU/SIMD state instruction.
function simd(txt,   m) {
	if (txt ~ /%[xyz]mm[0-9]|%mm[0-7]|%st(\(|,|$)|%k[0-7]/) return 1
	m = mnem(txt)
	if (m ~ /^[fk]/ || m ~ /^(emms|v?ldmxcsr|v?stmxcsr|vzeroupper|vzeroall|xsave|xrstor)/) return 1
	return 0
}
function endfn() {
	if (fn != "" && inside) printf "OPEN\t%s\n", fn
	inside = 0; lastjump = 0
}
/^[0-9a-f]+ <.*>:$/ {
	endfn(); fn = $2; sub(/^</, "", fn); sub(/>:$/, "", fn); next
}
/^Disassembly of section / { endfn(); fn = ""; next }
/^[ \t]+[0-9a-f]+: R_X86_64_/ {
	if (lastjump && $0 ~ /R_X86_64_(PLT32|PC32)[ \t]+fpu_kernel_enter([-+]0x[0-9a-f]+)?$/) inside = 1
	if (lastjump && $0 ~ /R_X86_64_(PLT32|PC32)[ \t]+fpu_kernel_exit([-+]0x[0-9a-f]+)?$/) inside = 0
	lastjump = 0; next
}
/^[ \t]*[0-9a-f]+:\t/ {
	txt = $0; sub(/^[ \t]*[0-9a-f]+:\t/, "", txt)
	addr = $1; sub(/:$/, "", addr)
	m = mnem(txt)
	lastjump = (m ~ /^(call|jmp)/)
	if (lastjump && txt ~ /<fpu_kernel_enter>$/) inside = 1
	if (lastjump && txt ~ /<fpu_kernel_exit>$/) inside = 0
	if (simd(txt)) {
		total++
		if (MODE == "walk") printf "%s\t%s\t%d\t%s\n", fn, addr, inside, txt
	}
	next
}
END { endfn(); if (MODE == "count") print total + 0 }
EOF
walk() { "$OBJDUMP" -dr --no-show-raw-insn "$1" | awk -v MODE="$2" -f "$t/walk.awk"; }

rc=0
ex_total=0
: > "$t/exempt-fns"
for o in "$@"; do
	b=$(basename "$o")
	case " $exempt " in
	*" $b "*)
		n=$(walk "$o" count)
		ex_total=$((ex_total + n))
		"$OBJDUMP" -d "$o" | sed -n 's/^[0-9a-f]* <\(.*\)>:$/\1/p' >> "$t/exempt-fns"
		echo "exempt object $b: $n SIMD instructions"
		;;
	*)
		n=$(walk "$o" count)
		if [ "$n" -ne 0 ]; then
			echo "SIMD-GATE FAIL (object): $b has $n SIMD/x87 instructions"
			rc=1
		fi
		;;
	esac
done
sort -u "$t/exempt-fns" -o "$t/exempt-fns"

walk "$mod" walk > "$t/mod-simd"
grep '^OPEN	' "$t/mod-simd" > "$t/open" || true
grep -v '^OPEN	' "$t/mod-simd" > "$t/ins" || true
mt=$(grep -c . "$t/ins" || true)
echo "module: $mt SIMD instructions; exempt objects: $ex_total; exempt functions: $(grep -c . "$t/exempt-fns" || true)"
if [ "$mt" -eq 0 ] || [ "$mt" -ne "$ex_total" ]; then
	echo "SIMD-GATE FAIL (count): module has $mt SIMD instructions, exempt objects $ex_total (must be equal and > 0)"
	rc=1
fi
# FILENAME, not NR == FNR: with an empty first file NR == FNR holds for the
# second one too and the check would pass vacuously.
awk -F'\t' 'FILENAME == ARGV[1] { ok[$1] = 1; next } !($1 in ok) { print "SIMD-GATE FAIL (function): " $1 "+" $2 " " $4 " is not in an exempt object" }' \
    "$t/exempt-fns" "$t/ins" > "$t/f-fail"
awk -F'\t' '$3 != 1 { print "SIMD-GATE FAIL (bracket): " $1 " " $2 " " $4 " outside fpu_kernel_enter/exit" }' "$t/ins" > "$t/b-fail"
awk -F'\t' '{ print "SIMD-GATE FAIL (bracket): " $2 " calls fpu_kernel_enter and reaches its end without fpu_kernel_exit" }' "$t/open" >> "$t/b-fail"
for f in f-fail b-fail; do
	if [ -s "$t/$f" ]; then
		rc=1
		echo "$(grep -c . "$t/$f") $f lines, first 20:"
		head -20 "$t/$f"
	fi
done
for s in fpu_kernel_enter fpu_kernel_exit; do
	n=$("$OBJDUMP" -t "$mod" | awk -v s="$s" '$NF == s && $0 ~ /[ \t]F[ \t]/' | grep -c . || true)
	if [ "$n" -ne 1 ]; then
		echo "SIMD-GATE FAIL (symbol): $n function symbols named $s in the module (want 1)"
		rc=1
	fi
done
if [ $rc -eq 0 ]; then
	echo "SIMD-GATE PASS: $mt SIMD instructions, all in exempt functions, all inside fpu_kernel_enter/exit"
fi
exit $rc
