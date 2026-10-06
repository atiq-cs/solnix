#!/bin/sh
# test-switch-helpers.sh — self-check for the fragile shell helpers in
# switch-to-configuration (T2.5): the illumos-specific relink/_readlink and the
# generation-number parse from the nix profile. Pure POSIX sh; run anywhere.
#
#   sh scripts/test-switch-helpers.sh   # exits 0 on pass, prints FAIL + exits 1
#
# These mirror the helpers embedded in modules/system/activation/default.nix.
# If that logic changes, keep this in sync (they are the parts most likely to
# break silently on illumos vs GNU coreutils differences).
set -u
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- relink(): rm -f then ln -s (illumos ln -sfn follows symlink-to-dir) ------
relink() { rm -f "$2" 2>/dev/null; ln -s "$1" "$2"; }
mkdir -p "$TMP/a" "$TMP/b"
relink "$TMP/a" "$TMP/cur"
[ "$(ls -ld "$TMP/cur" | sed 's/.* -> //')" = "$TMP/a" ] || fail "relink initial"
relink "$TMP/b" "$TMP/cur"                       # repoint an existing link-to-dir
[ "$(ls -ld "$TMP/cur" | sed 's/.* -> //')" = "$TMP/b" ] || fail "relink repoint (illumos ln -sfn would silently no-op here)"

# --- _readlink(): derive target via ls -ld (proto has no readlink(1)) ---------
_readlink() { [ -h "$1" ] || return 1; ls -ld "$1" 2>/dev/null | sed -n 's/.* -> //p'; }
[ "$(_readlink "$TMP/cur")" = "$TMP/b" ] || fail "_readlink target"
_readlink "$TMP/a" && fail "_readlink on a non-symlink must fail" || true

# --- generation number from the nix profile (register_generation) ------------
# nix-env -p $PROFILES/system --set makes system-<N>-link; $gen is parsed back
# from `system`, and must name a link to the toplevel just set.
PROFILES="$TMP/profiles"; mkdir -p "$PROFILES"
gen_of() { _readlink "$PROFILES/system" | sed -n 's,^system-\([0-9]*\)-link$,\1,p'; }
relink /nix/store/aaa-top "$PROFILES/system-1-link"; relink system-1-link "$PROFILES/system"
[ "$(gen_of)" = 1 ] || fail "gen from system -> system-1-link, got '$(gen_of)'"
relink /nix/store/bbb-top "$PROFILES/system-12-link"; relink system-12-link "$PROFILES/system"
[ "$(gen_of)" = 12 ] || fail "gen from system -> system-12-link, got '$(gen_of)'"
[ "$(_readlink "$PROFILES/system-$(gen_of)-link")" = /nix/store/bbb-top ] || fail "generation link target"
relink /nix/store/bbb-top "$PROFILES/system"        # not a generation link: must parse empty
[ -z "$(gen_of)" ] || fail "system -> store path must not parse as a generation, got '$(gen_of)'"
beadm() { [ "$1 $2" = "list -H" ] && printf '%s\n' "$FAKE_BEADM"; }

# --- BE-name/running-BE collision guard --------------------------------------
# next gen 2, running BE solnix-2 -> must bump so we never target the active BE.
FAKE_BEADM="solnix-1;;N;;;
solnix-2;;N;;;"
running_be=$(beadm list -H 2>/dev/null | awk -F';' '$3 ~ /N/ {print $1}' | head -1)
[ "$running_be" = "solnix-1" ] || fail "running_be parse: got $running_be"

echo "PASS: relink, _readlink, generation parse, running-BE parse all correct"
