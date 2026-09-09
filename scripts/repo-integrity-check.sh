#!/usr/bin/env bash
# repo-integrity-check.sh - catch tracked files that are not what they claim to be.
#
# Exists because scripts/metadata-shim.sh sat in git HEAD for two weeks as 222
# lines of cargo build-log output (a redirect landed on the wrong path during
# unrelated work). Nothing noticed, because the machine that built images still
# had the real script in its working tree. A clean checkout would have installed a
# cargo log as /usr/lib/metadata and produced an AMI that never gets a DHCP lease.
#
# The checks are deliberately cheap and specific to accidents we have actually
# had, not a general linter:
#   1. a tracked shell script that contains build-log output (cargo/ninja/meson)
#   2. a tracked file that is empty
#   3. a shell script whose syntax does not parse
#
# Exit non-zero on any finding so CI or a pre-commit hook can gate on it.
set -u

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2
fail=0

note() { printf '  %s\n' "$*"; }

# Only audit OUR files. artifacts/ holds extracted UPSTREAM source trees (git,
# glib, ...) whose helper scripts are legitimately not bash and are none of our
# business; auditing them produces pure noise.
ours() {
	# artifacts/sparc-xbuild/** and the *-ref/ mesa trees are EXTRACTED UPSTREAM
	# sources (git, glib, mesa, the BSD crib refs). Their helper scripts are
	# legitimately not bash and are not ours to police -- auditing them is pure
	# noise. Audit our own scripts/, modules/, pkgs/, lib/, src/ (minus refs).
	grep -vE '^artifacts/sparc-xbuild/|^artifacts/.*-xbuild/|^src/riscv/bsd-ref/|^src/drm-port/(netbsd-ref|powervr/powervr-mesa|amdgpu/|anv/|nvk/|ggml-vulkan/)|^\.infra/'
}

echo "== repo integrity =="

# 1. build-log content masquerading as a script.
#    'Locking N packages' / 'Adding <crate> v' / 'Updating git repository' are
#    cargo; 'ninja: build stopped' / '[NNN/NNN]' are ninja; 'The Meson build
#    system' is meson. Three or more hits means the file IS a log, not a script
#    that merely mentions one.
echo "-- build-log content in tracked scripts --"
while IFS= read -r f; do
	[ -f "$f" ] || continue
	# Skip self: this file necessarily contains the marker strings it searches
	# for, so it would always match its own pattern.
	[ "$f" = "scripts/repo-integrity-check.sh" ] && continue
	n=$(grep -acE 'Updating git repository|Locking [0-9]+ packages|Adding [a-z0-9_-]+ v[0-9]|^ *Compiling [a-z]|^ *Downloaded [a-z]|ninja: build stopped|The Meson build system' "$f" 2>/dev/null)
	if [ "${n:-0}" -ge 3 ]; then
		note "FAIL $f looks like build-log output ($n markers), not a script"
		fail=1
	fi
done < <(git ls-files '*.sh' 'scripts/*' 2>/dev/null | ours)

# 2. empty tracked files that should never be empty: source, patches, scripts,
#    nix. (Empty *.txt/*.log under artifacts/ are captured build output where
#    "no findings" legitimately means an empty file, so they are not policed.)
echo "-- empty source/patch/script files --"
while IFS= read -r f; do
	[ -f "$f" ] || continue
	if [ ! -s "$f" ]; then
		note "FAIL $f is empty"
		fail=1
	fi
done < <(git ls-files '*.c' '*.h' '*.S' '*.patch' '*.sh' '*.nix' '*.dts' '*.py' 2>/dev/null | ours)

# 3. shell scripts that do not parse. Only files with a sh/bash shebang: some
#    tracked fragments are meant to be sourced and legitimately have none.
echo "-- shell syntax --"
while IFS= read -r f; do
	[ -f "$f" ] || continue
	case "$(head -1 "$f" 2>/dev/null)" in
	'#!'*sh*) ;;
	*) continue ;;
	esac
	if ! bash -n "$f" 2>/dev/null; then
		note "FAIL $f does not parse"
		fail=1
	fi
done < <(git ls-files '*.sh' 'scripts/*' 2>/dev/null | ours)

if [ "$fail" -eq 0 ]; then
# --- a .nix header naming a DIFFERENT file is a TRAP ---------------------------
# A stale 267-line copy of tranche-entry-224.nix sat beside the real 1221-line
# entry point, named "...-node-FIXED.nix" and with a header still calling itself
# "tranche-entry-224.nix". Both signals pointed the wrong way, nothing imported it,
# and an agent built against it, hit the H26 failure the live file already fixes,
# and concluded the fix was missing from the tree. Warn (do not fail) so variants
# stay allowed but must be labelled.
mismatch=0
while IFS= read -r nf; do
	claim=$(head -6 "$nf" 2>/dev/null | grep -oE '#[[:space:]]*[A-Za-z0-9._-]+\.nix' | head -1 |
	    grep -oE '[A-Za-z0-9._-]+\.nix')
	[ -n "$claim" ] || continue
	[ "$claim" = "$(basename "$nf")" ] && continue
	grep -q 'SUPERSEDED\|UNREFERENCED VARIANT' "$nf" 2>/dev/null && continue
	# Only a hazard if NOTHING imports it. A live file whose header names its
	# generic base (openblas.nix -> openblas-solaris.nix, mesa-softpipe.nix ->
	# mesa.nix) is a legitimate cross-reference, and warning on those produced 7
	# findings of which 5 were noise -- a guard that cries wolf gets ignored,
	# which is worse than no guard.
	stem=$(basename "$nf" .nix)
	refs=$(grep -rIl --exclude-dir=.git -F "$stem" ./pkgs ../solnix-pkgs/pkgs 2>/dev/null |
	    grep -vc "/$stem.nix\$" || true)
	[ "${refs:-0}" -gt 0 ] && continue
	echo "repo-integrity: WARN -- $nf header names '$claim' (label it, or fix the header)"
	mismatch=$((mismatch+1))
done <<EOF
$(find ./pkgs ../solnix-pkgs/pkgs -name '*.nix' -not -path '*/.git/*' 2>/dev/null)
EOF
[ "$mismatch" -gt 0 ] && echo "repo-integrity: $mismatch .nix file(s) whose header names another file"

# --- a .patch file with no diff hunks is a TRAP -------------------------------
# Scoped to OUR patch dirs, deliberately excluding artifacts/ -- that tree holds
# extracted upstream sources (e.g. gawk's own vms/vax/*.patch) whose contents are
# not ours to judge; flagging them would be noise that trains people to ignore
# this check.
#
# Five files under rust-patches/ were prose notes wearing a .patch extension. A
# derivation that globs *.patch either fails on them or -- far worse -- SILENTLY
# NO-OPS and ships an unpatched binary that looks correct. Prose belongs in
# .notes.md; .patch must mean appliable.
hunkless=0
while IFS= read -r pf; do
	if ! grep -qE '^@@ ' "$pf" 2>/dev/null; then
		echo "repo-integrity: FAIL -- $pf is a .patch with ZERO diff hunks (rename to .notes.md)"
		hunkless=$((hunkless+1))
	fi
done <<EOF
$(find . -name '*.patch' -not -path './.git/*' -not -path './artifacts/*' 2>/dev/null)
EOF
if [ "$hunkless" -gt 0 ]; then
	echo "repo-integrity: $hunkless hunkless .patch file(s) -- a silent no-op waiting to happen"
	exit 1
fi


	echo "repo-integrity: CLEAN"
else
	echo "repo-integrity: FINDINGS ABOVE"
fi
exit "$fail"
