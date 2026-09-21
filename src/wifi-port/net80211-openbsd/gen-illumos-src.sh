#!/usr/bin/env bash
# Materialise illumos-side net80211 sources from the read-only vendored copy.
#
#   orig/<f>.c  +  patches/<f>.illumos.patch  ->  build/<f>.c
#
# Same discipline as iwx/gen-illumos-src.sh: orig/ is read-only so the upstream
# diff stays legible; the patch IS the port's mbuf/802.11 delta and is reviewed
# on its own. The generated file is never authoritative -- regenerate, never
# edit. To rework a site: edit build/<f>.c then `./gen-illumos-src.sh --update <f>`.
#
# Only the files with a patch are materialised. Files that compile against the
# compat layer with NO source change are compiled straight from orig/ and are
# not listed here.
set -u

here=$(cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$here/build" "$here/patches"

# The files this port rewrites (each has orig/<f>.c + patches/<f>.illumos.patch).
PATCHED="ieee80211_node ieee80211_crypto ieee80211_input ieee80211_output"

check_hunks() {  # $1 = patch file; refuse a no-hunk (prose) patch
	local hunks
	hunks=$(grep -c '^@@' "$1" 2>/dev/null)
	hunks=${hunks:-0}
	if [ "$hunks" -eq 0 ]; then
		echo "FAIL: $1 has no diff hunks (@@) -- would apply as a no-op and ship"
		echo "      unpatched source. Prose belongs in a .notes.md file."
		exit 2
	fi
	echo "$hunks"
}

if [ "${1:-}" = "--update" ]; then
	f="${2:?usage: --update <basename>}"
	src="$here/orig/$f.c"; out="$here/build/$f.c"; pf="$here/patches/$f.illumos.patch"
	[ -f "$out" ] || { echo "FAIL: --update needs $out"; exit 2; }
	tmp=$(mktemp /tmp/n80-patch.XXXXXX)
	diff -u "$src" "$out" |
	    sed -e "1s|^--- .*|--- orig/$f.c|" -e "2s|^+++ .*|+++ build/$f.c|" > "$tmp"
	if [ "$(grep -c '^@@' "$tmp" 2>/dev/null)" = "0" ]; then
		echo "FAIL: regenerated patch has no hunks -- $out matches orig, nothing to record"
		rm -f "$tmp"; exit 2
	fi
	mv "$tmp" "$pf"
	echo "updated $pf ($(grep -c '^@@' "$pf") hunks)"
	exit 0
fi

for f in $PATCHED; do
	src="$here/orig/$f.c"; out="$here/build/$f.c"; pf="$here/patches/$f.illumos.patch"
	[ -f "$src" ] || { echo "FAIL: missing vendored $src"; exit 2; }
	[ -f "$pf" ]  || { echo "FAIL: missing patch $pf"; exit 2; }
	hunks=$(check_hunks "$pf") || exit 2
	cp -- "$src" "$out"
	chmod u+w "$out"		# orig/ is read-only; the derived copy must be writable to patch
	if ! patch --silent -p0 -N -r - -d "$here" -i "$pf" "build/$f.c" 2>/tmp/n80-gen.err; then
		echo "FAIL: $pf did not apply cleanly"; cat /tmp/n80-gen.err; exit 1
	fi
	# Applying cleanly != applied anything (patch -N exits 0 on already-applied).
	if cmp -s "$src" "$out"; then
		echo "FAIL: build/$f.c is byte-identical to orig -- patch applied as a no-op"
		exit 1
	fi
	echo "generated build/$f.c ($(wc -l < "$out") lines, $hunks hunks)"
done
