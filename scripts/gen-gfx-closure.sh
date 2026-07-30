#!/usr/bin/env bash
# Regenerate GFX_CLOSURE as the COMPLETE transitive closure of the Xfce desktop
# package set. On this illumos cross-build the nix DB Refs table is incomplete
# (75 edges for 460 paths) and ELF binaries embed NO sibling /nix/store refs in
# their .text (grep finds none) -- the ONLY reference graph that exists is the
# ELF RUNPATH/RPATH of each binary+lib, which the cross toolchain writes with
# the full set of store /lib dirs each object was linked against. That RUNPATH
# graph IS the nix reference graph here. So: seed with the desktop roots, and
# take the transitive fixpoint over "store dir X's RUNPATH names store dir Y".
# Every runtime .so a desktop binary opens by SONAME lives in a store dir that
# appears in some object's RUNPATH, so this closure is complete by construction
# (fixes the libxfce4panel/libgmodule/... whack-a-mole at the source).
set -eu
STORE=/nix/store
OUT=/tmp/gfx-closure.txt
SEEN=/tmp/gfx-closure.seen
QUEUE=/tmp/gfx-closure.queue
ELFD=/usr/bin/elfdump

# --- desktop root set (leaf packages) -------------------------------------
: > "$QUEUE"
for pat in xorg-server xfce4-session xfce4-panel xfce4-settings xfce4-appfinder \
           xfwm4 xfdesktop libxfce4ui libxfce4util slim gtk3 twm xterm xkbcomp \
           thunar exo garcon tumbler xfconf xrdb xsetroot xauth; do
  for d in "$STORE"/*-"$pat"-* "$STORE"/*-"$pat"; do
    [ -d "$d" ] || continue
    case "$d" in *-debug) continue;; *.drv) continue;; esac
    echo "$d"
  done
done | sort -u > "$QUEUE"
echo "=== $(grep -c . "$QUEUE") desktop roots ===" >&2

: > "$SEEN"
# BFS over the RUNPATH graph. For each store dir, dump every ELF object's
# RUNPATH+RPATH, extract the /nix/store/<dir> components, enqueue new ones.
while [ -s "$QUEUE" ]; do
  p=$(head -1 "$QUEUE"); tail -n +2 "$QUEUE" > "$QUEUE.t" && mv "$QUEUE.t" "$QUEUE"
  grep -qxF "$p" "$SEEN" && continue
  echo "$p" >> "$SEEN"
  [ -d "$p" ] || continue
  # every regular file that is an ELF: read its RUNPATH/RPATH dyn entries.
  # (elfdump -d on a non-ELF prints nothing / errors to stderr -> discarded.)
  find "$p" -type f 2>/dev/null | while read -r f; do
    "$ELFD" -d "$f" 2>/dev/null | grep -E 'RUNPATH|RPATH' || true
  done \
    | grep -oE "/nix/store/[0-9a-df-np-sv-z]{32}-[^/:]+" \
    | sort -u \
    | while read -r dep; do
        [ -d "$dep" ] || continue
        grep -qxF "$dep" "$SEEN" || grep -qxF "$dep" "$QUEUE" || echo "$dep" >> "$QUEUE"
      done
done

# The closure is the SEEN set. Keep only real (existing) non-debug non-drv dirs.
sort -u "$SEEN" | while read -r d; do
  case "$d" in *-debug) continue;; *.drv) continue;; esac
  [ -d "$d" ] && echo "$d"
done > "$OUT"
echo "=== closure written: $(wc -l < "$OUT") paths -> $OUT ===" >&2
