#!/usr/bin/env bash
# pkgsrc-harvest.sh — sparse-fetch a NetBSD pkgsrc package's patches/ + Makefile
# via the GitHub raw/API (no full ~1GB clone), into artifacts/pkgsrc-patches/<name>/.
# Then flag which patches touch illumos/SunOS/Solaris portability so a wave can
# pick the relevant ones. See docs/design-pkgsrc-patches.md.
#
#   pkgsrc-harvest.sh <category/pkgdir> [<category/pkgdir> ...]
#   e.g. pkgsrc-harvest.sh devel/libffi security/libgcrypt shells/bash
set -u
OUT=artifacts/pkgsrc-patches
RAW=https://raw.githubusercontent.com/NetBSD/pkgsrc/trunk
API=https://api.github.com/repos/NetBSD/pkgsrc/contents
# markers that mean "this patch is for our platform"
MARK='SunOS|Solaris|illumos|__sun|sun4|_XOPEN|__EXTENSIONS__|alloca|u_int|sys/types|<strings.h>|<stdint.h>|byteorder|endian|/proc|procfs'

for pd in "$@"; do
  name=$(basename "$pd")
  d="$OUT/$name"
  mkdir -p "$d/patches"
  echo "=== harvest $pd -> $d ==="
  # Makefile (records the SunOS conditionals + version)
  curl -fsSL "$RAW/$pd/Makefile" -o "$d/Makefile" 2>/dev/null && echo "  Makefile ok" || echo "  Makefile MISSING"
  curl -fsSL "$RAW/$pd/distinfo" -o "$d/distinfo" 2>/dev/null || true
  # list patches
  curl -fsSL "$API/$pd/patches" -o "$d/.patchlist.json" 2>/dev/null || { echo "  no patches dir"; continue; }
  grep -oE '"name": *"patch-[^"]+"' "$d/.patchlist.json" | sed 's/.*"\(patch-[^"]*\)"/\1/' | while read -r pf; do
    curl -fsSL "$RAW/$pd/patches/$pf" -o "$d/patches/$pf" 2>/dev/null && echo "  got $pf" || echo "  FAIL $pf"
  done
  # flag illumos-relevant patches
  echo "  --- illumos/SunOS-relevant patches ---"
  for pf in "$d/patches/"patch-*; do
    [ -f "$pf" ] || continue
    if grep -Eq "$MARK" "$pf"; then
      hits=$(grep -Eoh "$MARK" "$pf" | sort -u | paste -sd, -)
      echo "  RELEVANT $(basename "$pf"): $hits"
    fi
  done
done
echo "=== harvest done ==="
