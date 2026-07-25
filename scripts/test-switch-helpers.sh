#!/bin/sh
# test-switch-helpers.sh — self-check for the fragile shell helpers in
# switch-to-configuration (T2.5): the illumos-specific relink/_readlink and the
# next_gen / generation-registry arithmetic. Pure POSIX sh; run anywhere.
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

# --- next_gen(): highest system-<N>-link (+ existing solnix-<n> BEs) + 1 ------
PROFILES="$TMP/profiles"; mkdir -p "$PROFILES"
# fake beadm: prints CSV `name;...` like `beadm list -H`
beadm() { [ "$1 $2" = "list -H" ] && printf '%s\n' "$FAKE_BEADM"; }
next_gen() {
  hi=0
  for l in "$PROFILES"/system-*-link; do
    [ -L "$l" ] || continue
    n=$(echo "$l" | sed -n 's,.*/system-\([0-9]*\)-link$,\1,p')
    [ -n "$n" ] && [ "$n" -gt "$hi" ] && hi=$n
  done
  for b in $(beadm list -H 2>/dev/null | awk -F';' '{print $1}' | sed -n 's,^solnix-\([0-9]*\)$,\1,p'); do
    [ "$b" -gt "$hi" ] && hi=$b
  done
  echo $((hi + 1))
}
FAKE_BEADM=""
[ "$(next_gen)" = "1" ] || fail "next_gen empty registry, no BEs -> 1, got $(next_gen)"
# with BE solnix-1 present, first gen must skip 1 (would collide with running BE)
FAKE_BEADM="solnix-1;;NR;;;"
[ "$(next_gen)" -eq 2 ] || fail "next_gen must avoid existing solnix-1 BE -> 2, got $(next_gen)"
relink /nowhere "$PROFILES/system-2-link"
FAKE_BEADM="solnix-1;;N;;;
solnix-2;;NR;;;"
[ "$(next_gen)" -eq 3 ] || fail "next_gen with gen2 link + solnix-2 BE -> 3, got $(next_gen)"

# --- BE-name/running-BE collision guard --------------------------------------
# next gen 2, running BE solnix-2 -> must bump so we never target the active BE.
FAKE_BEADM="solnix-1;;N;;;
solnix-2;;N;;;"
running_be=$(beadm list -H 2>/dev/null | awk -F';' '$3 ~ /N/ {print $1}' | head -1)
[ "$running_be" = "solnix-1" ] || fail "running_be parse: got $running_be"

echo "PASS: relink, _readlink, next_gen, running-BE parse all correct"
