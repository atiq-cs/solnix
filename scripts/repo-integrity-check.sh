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
	echo "repo-integrity: CLEAN"
else
	echo "repo-integrity: FINDINGS ABOVE"
fi
exit "$fail"
