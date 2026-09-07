#!/usr/bin/env bash
# cache-fetchability-gate.sh -- is every published derivation actually FETCHABLE?
#
# The project's founding claim is that solnix is exactly Nix: every package a real
# derivation. A derivation whose output cannot be retrieved fails that claim in
# practice no matter how well-formed its metadata is -- so this checks the thing
# that actually matters to a user on a fresh machine.
#
# It distinguishes two failure modes, and that distinction is the whole point:
#
#   narinfo_404      the cache says it does not have the path. Undesirable but
#                    HONEST -- Nix falls back to building from source.
#   phantom_nar_404  the narinfo is served 200 with complete metadata and the NAR
#                    it names is 404. The cache asserts it has the path and then
#                    cannot deliver it; Nix has already committed to a substitution
#                    and fails rather than falling back. THIS is what breaks clients.
#
# Collapsing the two into one number hides the mode that matters, which is how 47
# unfetchable paths went unnoticed (docs/cache-integrity-audit.md).
#
# Usage:  cache-fetchability-gate.sh [--tsv out.tsv] [--max-fail N]
# Exit:   0 = every published path fetchable (or within --max-fail); 1 = otherwise.
set -uo pipefail

CACHE="${CACHE:-https://cache.solnix.io}"
REG="${REG:-docs/registry/real-derivations.tsv}"
TSV=""
MAXFAIL=0

while [ $# -gt 0 ]; do
	case "$1" in
	--tsv) TSV="$2"; shift 2 ;;
	--max-fail) MAXFAIL="$2"; shift 2 ;;
	*) echo "unknown arg: $1" >&2; exit 2 ;;
	esac
done

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2
[ -f "$REG" ] || { echo "no registry at $REG" >&2; exit 2; }

ok=0; phantom=0; missing=0
out=$(mktemp)
printf 'pname\tout_hash\tout_path\tfailure_mode\n' > "$out"

while IFS=$'\t' read -r pname version out_hash out_path _rest; do
	[ "$pname" = "pname" ] && continue
	[ -z "${out_hash:-}" ] && continue

	ni_body=$(mktemp)
	ni=$(curl -s --max-time 12 -o "$ni_body" -w '%{http_code}' \
	    "$CACHE/$out_hash.narinfo" 2>/dev/null || echo 000)
	if [ "$ni" != "200" ]; then
		missing=$((missing + 1))
		printf '%s\t%s\t%s\tnarinfo_404\n' "$pname" "$out_hash" "$out_path" >> "$out"
		rm -f "$ni_body"; continue
	fi

	# The NAR's location is whatever the narinfo says, not a guess.
	url=$(grep -oE '^URL: .*' "$ni_body" 2>/dev/null | awk '{print $2}')
	rm -f "$ni_body"
	if [ -z "$url" ]; then
		phantom=$((phantom + 1))
		printf '%s\t%s\t%s\tnarinfo_no_url\n' "$pname" "$out_hash" "$out_path" >> "$out"
		continue
	fi
	nc=$(curl -s --max-time 15 -o /dev/null -w '%{http_code}' "$CACHE/$url" 2>/dev/null || echo 000)
	if [ "$nc" = "200" ]; then
		ok=$((ok + 1))
	else
		phantom=$((phantom + 1))
		printf '%s\t%s\t%s\tphantom_nar_404\n' "$pname" "$out_hash" "$out_path" >> "$out"
	fi
done < "$REG"

fail=$((phantom + missing))
echo "cache fetchability: $ok fetchable, $fail NOT ($phantom phantom, $missing missing narinfo)"
if [ "$phantom" -gt 0 ]; then
	echo "  ⚠️  $phantom PHANTOM entries: the cache claims these paths and cannot serve them."
	echo "      Deleting those narinfos is strictly better than serving a lie -- it turns a"
	echo "      mid-substitution failure into a clean build-from-source."
fi
[ -n "$TSV" ] && { cp "$out" "$TSV"; echo "  wrote $TSV"; }
rm -f "$out"

[ "$fail" -le "$MAXFAIL" ] && exit 0
exit 1
