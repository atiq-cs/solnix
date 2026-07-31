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
# NOTE: libXfixes AND xkeyboard-config are seeded explicitly. libXfixes' /lib is
# in no object's RUNPATH; xkeyboard-config is DATA-ONLY (no ELF at all) so the
# RUNPATH BFS can never reach either. Without xkeyboard-config in the closure,
# XKB_CONFIG_ROOT points at a missing dir and Xvfb dies 'Failed to compile
# keymap'. Seeding the leaf packages pulls both into the closure.
for pat in xorg-server xfce4-session xfce4-panel xfce4-settings xfce4-appfinder \
           xfwm4 xfdesktop libxfce4ui libxfce4util slim gtk3 twm xterm xkbcomp \
           thunar exo garcon tumbler xfconf xrdb xsetroot xauth libXfixes \
           xkeyboard-config; do
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

# The closure is the SEEN set. Keep only real (existing) non-debug non-drv dirs,
# AND drop any store dir that ships a FOREIGN-ISA 64-bit shared object. This host
# has a stray aarch64 zlib in /nix/store; if it lands in the closure its /lib gets
# on LD_LIBRARY_PATH_64 and its aarch64 libz.so.1 claims the libz.so.1 SONAME ->
# 'libz.so relocation error'. A 32-bit x86 sibling does NOT shadow a 64-bit
# resolve (ld.so.1 skips the wrong ELF class), so we reject ONLY a 64-bit lib
# that is NOT x86-64/AMD64 (i.e. a foreign ISA like aarch64/sparc).
sort -u "$SEEN" | while read -r d; do
  case "$d" in *-debug) continue;; *.drv) continue;; esac
  [ -d "$d" ] || continue
  _bad=0
  for _so in "$d"/lib/*.so* "$d"/lib/amd64/*.so*; do
    [ -e "$_so" ] || continue
    _fi=$(file "$_so" 2>/dev/null)
    case "$_fi" in *'ELF 64-bit'*) ;; *) continue;; esac   # ignore 32-bit siblings
    echo "$_fi" | grep -qE 'x86-64|AMD64|Intel' || { _bad=1; break; }
  done
  [ "$_bad" = 1 ] && { echo "DROP foreign-ISA 64-bit lib: $d" >&2; continue; }
  echo "$d"
done > "$OUT"
echo "=== closure written: $(wc -l < "$OUT") paths -> $OUT ===" >&2
