#!/usr/bin/env bash
# Materialise the illumos-side driver source from the read-only vendored copy.
#
#   openbsd-orig/if_iwx.c  +  patches/if_iwx.illumos.patch  ->  build/if_iwx_illumos.c
#
# WHY A PATCH RATHER THAN AN EDITED COPY. openbsd-orig/ is read-only by policy so
# the upstream diff stays legible, and a committed edited copy would make it
# impossible to see what the port changed without a manual diff against a
# specific OpenBSD revision. The patch IS the port's 802.11/mbuf delta, and it is
# reviewable on its own.
#
# The generated file is not authoritative: regenerate it, never edit it. To change
# a call site, edit build/if_iwx_illumos.c, then run `./gen-illumos-src.sh --update`
# to refresh the patch from it.
#
# NOTE: whole-file regeneration on every run. Fine at 13k lines; if this grows to
# several sources, drive it from a Makefile with real dependencies.
set -u

here=$(cd -- "$(dirname -- "$0")" && pwd)
src="$here/openbsd-orig/if_iwx.c"
patch_file="$here/patches/if_iwx.illumos.patch"
out="$here/build/if_iwx_illumos.c"

# The vendored softc header is read-only too, so the phase-3 lock fields
# (sc_lock/sc_cmd_cv) added to struct iwx_softc live in a SECOND patch,
# materialised into build/dev/pci/if_iwxvar.h. The gate puts -Ibuild first so
# this patched copy wins over the compat/ symlink into openbsd-orig/.
var_src="$here/openbsd-orig/if_iwxvar.h"
var_patch="$here/patches/if_iwxvar.illumos.patch"
var_out="$here/build/dev/pci/if_iwxvar.h"

if [ ! -f "$src" ]; then
	echo "FAIL: missing vendored source $src"
	exit 2
fi

# A .patch with no diff hunks applies silently and produces an UNPATCHED file
# that looks fine. Refuse to proceed on one.
#
# NOTE the shape of this assignment. `grep -c` prints 0 AND exits 1 when there
# are no matches, so the obvious `$(grep -c ... || echo 0)` yields the TWO-line
# string "0\n0" and the following [ -eq ] dies with "integer expected" -- which
# `set -u` does not catch and which made this check unreachable. Measured: the
# no-hunk control then "passed" via a later error instead of this one.
hunks=$(grep -c '^@@' "$patch_file" 2>/dev/null)
hunks=${hunks:-0}
if [ "$hunks" -eq 0 ]; then
	echo "FAIL: $patch_file has no diff hunks (@@) -- it would apply as a no-op"
	echo "      and ship an unpatched driver. Prose belongs in a .notes.md file."
	exit 2
fi

if [ "${1:-}" = "--update" ]; then
	# Refresh the patch FROM the generated file, for when a call site is being
	# reworked. Timestamps are stripped so the patch is stable across runs and
	# a rebuild does not show up as a spurious diff.
	if [ ! -f "$out" ]; then
		echo "FAIL: --update needs an existing $out to diff against"
		exit 2
	fi
	tmp=$(mktemp /tmp/iwx-patch.XXXXXX)
	diff -u "$src" "$out" |
	    sed -e '1s|^--- .*|--- openbsd-orig/if_iwx.c|' \
	        -e '2s|^+++ .*|+++ build/if_iwx_illumos.c|' > "$tmp"
	if [ "$(grep -c '^@@' "$tmp" 2>/dev/null)" = "0" ]; then
		echo "FAIL: regenerated patch has no hunks -- $out matches the vendored"
		echo "      source, so there is nothing to record. Refusing to write a"
		echo "      no-op patch."
		rm -f "$tmp"
		exit 2
	fi
	mv "$tmp" "$patch_file"
	echo "updated $patch_file ($(grep -c '^@@' "$patch_file") hunks)"

	# Refresh the header patch too if the generated header has been edited.
	if [ -f "$var_out" ]; then
		vtmp=$(mktemp /tmp/iwx-vpatch.XXXXXX)
		diff -u "$var_src" "$var_out" |
		    sed -e '1s|^--- .*|--- openbsd-orig/if_iwxvar.h|' \
		        -e '2s|^+++ .*|+++ build/dev/pci/if_iwxvar.h|' > "$vtmp"
		if [ "$(grep -c '^@@' "$vtmp" 2>/dev/null)" = "0" ]; then
			echo "FAIL: regenerated header patch has no hunks"
			rm -f "$vtmp"; exit 2
		fi
		mv "$vtmp" "$var_patch"
		echo "updated $var_patch ($(grep -c '^@@' "$var_patch") hunks)"
	fi
	exit 0
fi

mkdir -p "$here/build"
cp -- "$src" "$out"
if ! patch --silent -p0 -N -r - -d "$here" -i "$patch_file" \
    "build/if_iwx_illumos.c" 2>/tmp/iwx-gen.err; then
	echo "FAIL: patch did not apply cleanly"
	cat /tmp/iwx-gen.err
	exit 1
fi

# Applying cleanly is not the same as having applied anything: patch(1) exits 0
# for an already-applied patch when -N is given. Assert the output actually
# differs from the input, which is the only direct evidence the delta landed.
if cmp -s "$src" "$out"; then
	echo "FAIL: $out is byte-identical to the vendored source -- the patch"
	echo "      applied as a no-op. This is the failure mode that ships an"
	echo "      unpatched driver looking healthy."
	exit 1
fi

echo "generated $out ($(wc -l < "$out") lines, $hunks hunks applied)"

# Materialise the patched softc header (same no-op-patch guards as above).
if [ -f "$var_patch" ]; then
	vhunks=$(grep -c '^@@' "$var_patch" 2>/dev/null)
	vhunks=${vhunks:-0}
	if [ "$vhunks" -eq 0 ]; then
		echo "FAIL: $var_patch has no diff hunks (@@) -- it would apply as a no-op"
		exit 2
	fi
	mkdir -p "$here/build/dev/pci"
	cp -- "$var_src" "$var_out"
	chmod u+w "$var_out"
	if ! patch --silent -p0 -N -r - -d "$here" -i "$var_patch" \
	    "build/dev/pci/if_iwxvar.h" 2>/tmp/iwx-genvar.err; then
		echo "FAIL: if_iwxvar.h patch did not apply cleanly"
		cat /tmp/iwx-genvar.err
		exit 1
	fi
	if cmp -s "$var_src" "$var_out"; then
		echo "FAIL: $var_out is byte-identical to the vendored header -- the"
		echo "      patch applied as a no-op."
		exit 1
	fi
	# if_iwxreg.h is unchanged but the include <dev/pci/if_iwxreg.h> must
	# resolve under -Ibuild too, so drop a copy alongside the patched var.
	cp -- "$here/openbsd-orig/if_iwxreg.h" "$here/build/dev/pci/if_iwxreg.h"
	echo "generated $var_out ($vhunks hunks applied)"
fi
