#!/usr/bin/env bash
# gen-cosmic-closure.sh -- emit the COSMIC desktop closure in the format
# `GRAPHICAL=1` + `GFX_CLOSURE=<file>` in scripts/oi-make-livecd.sh expects:
# ONE existing /nix/store path per line, no .drv, no -debug.
#
# WHY NOT scripts/gen-gfx-closure.sh: that one is for the Xfce set and walks the
# ELF RUNPATH graph because the cross-built nix DB had an INCOMPLETE Refs table
# (75 edges for 460 paths). These COSMIC paths were built by nix ON this host, so
# the DB reference graph is real and `nix-store -qR` is both correct and complete.
# Verified before relying on it: -qR on the cosmic-term output returns >1 path,
# i.e. the Refs table is populated (a stub DB returns only the path itself).
#
# Usage: OUT=/tmp/gfx-closure.txt ./gen-cosmic-closure.sh <store-path>...
set -eu
: "${OUT:=/tmp/gfx-closure.txt}"
[ $# -gt 0 ] || { echo "usage: $0 <store-path>..." >&2; exit 1; }

TMP="${OUT}.tmp"
: > "$TMP"
for root in "$@"; do
  [ -e "$root" ] || { echo "FATAL: root does not exist: $root" >&2; exit 1; }
  n=$(nix-store -qR "$root" | grep -c .)
  # A populated Refs table gives a leaf package more than just itself. If this is
  # 1 for every root, the DB graph is empty and this script would silently emit a
  # useless one-line "closure" -- fail loudly instead.
  echo "  $root -> $n paths" >&2
  nix-store -qR "$root" >> "$TMP"
done

sort -u "$TMP" | while read -r p; do
  case "$p" in
    *.drv) continue ;;
    *-debug) continue ;;
  esac
  [ -e "$p" ] || { echo "WARN: dropping nonexistent $p" >&2; continue; }
  echo "$p"
done > "$OUT"
rm -f "$TMP"

total=$(grep -c . "$OUT")
[ "$total" -gt 1 ] || { echo "FATAL: closure has $total path(s) -- the nix DB reference graph is empty, this list is useless" >&2; exit 1; }
echo "=== closure: $total paths -> $OUT ===" >&2
