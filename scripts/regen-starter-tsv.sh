#!/usr/bin/env bash
# regen-starter-tsv.sh — MECHANICALLY regenerate docs/registry/real-derivations.tsv
# from a live illumos build of the dixi starter roots.
#
# WHY THIS EXISTS. starter.nix (pkgs/illumos/starter.nix) reads
# docs/registry/real-derivations.tsv and exposes each row as
# pkgs.solnix.starter.<pname> (col 0), valued by fetchClosure of col 3. Those
# rows MUST be real derivations that exist in the cache: a row naming a store
# path that no build reproduces silently orphans the moment the fork tree
# changes (measured: the 4qzc git lineage's stdenv base — perl 33r963cv, bash
# bdp0gkhg — drifted, so git/curl/openssl/pcre2-dev all got new hashes and the
# old ones became unbuildable-and-unstored).
#
# THE FIX IS MECHANICAL, NOT MANUAL. This script is the source of truth; the tsv
# is a DERIVED ARTIFACT. It builds the dixi starter roots from the CURRENT tree,
# and emits:
#   * one row per ROOT attr keyed by the attr name (col 0 == "git"/"curl"/… so
#     base.nix's `with pkgs.solnix.starter; [ coreutils … git ]` resolves) whose
#     col 3 is that root's MAIN output path;
#   * one row per closure member (keyed by a nix-parsed pname) so the WHOLE
#     closure is published and fetchClosure-complete.
# Re-run it after any tree change and the tsv tracks reality — no hand-typed
# store paths, ever.
#
# RUN ON the illumos build node (Nix 2.24.15 at /nix-tools224), as root:
#   TRANCHE_NIX=/root/tranche-224.nix ./regen-starter-tsv.sh > real-derivations.tsv
set -euo pipefail

TRANCHE_NIX="${TRANCHE_NIX:?set TRANCHE_NIX=/root/tranche-224.nix}"
SYSTEM="${SYSTEM:-x86_64-solaris}"
# The dixi starter roots: base.nix's set + dixi.nix's git/curl. Every attr name
# the shipped configs reference through pkgs.solnix.starter.
ROOTS="${ROOTS:-coreutils file gnugrep gnused bzip2 xz zlib pcre2 which nvi gdb curl git}"

. /etc/profile.d/nix-illumos.sh 2>/dev/null || true
export PATH=/nix-tools224/bin:/usr/gnu/bin:/usr/bin:/usr/sbin:${PATH:-}
N="nix --extra-experimental-features nix-command --extra-experimental-features flakes"

# nix-parsed pname of a store path: strip the 32-char hash prefix, then strip a
# trailing -<version> where version begins with a digit (parseDrvName semantics).
# Falls back to the whole name. Used for NON-root closure members.
pname_of() {
  local base name
  base="$(basename "$1")"; name="${base#*-}"
  printf '%s' "$name" | sed -E 's/-[0-9][0-9A-Za-z.+_]*(-[a-z]+)?$/\1/; s/^-//'
}

# emit one tsv row: pname outpath  (deriver_resolves + hermetic computed here).
declare -A SEEN
emit_row() {
  local pn="$1" sp="$2" force="${3:-}"
  case "$sp" in /nix/store/*) ;; *) return 0 ;; esac
  local key="$pn	$sp"
  if [ -z "$force" ]; then
    [ -n "${SEEN[$key]:-}" ] && return 0
  fi
  SEEN[$key]=1
  local base hash name ver deriver dres herm leak
  base="$(basename "$sp")"; hash="${base%%-*}"; name="${base#*-}"
  ver="$(printf '%s' "$name" | grep -oE '[0-9][0-9A-Za-z.+_]*' | head -1 || true)"; ver="${ver:-0}"
  deriver="$(nix-store -q --deriver "$sp" 2>/dev/null || true)"
  case "$deriver" in *.drv) dres=y ;; *) dres=n ;; esac
  leak="$(nix-store -qR "$sp" 2>/dev/null | grep -v '^/nix/store/' || true)"
  [ -z "$leak" ] && herm=y || herm=n
  printf '%s\t%s\t%s\t%s\t%s\t%s\tpublished\t%s\tstarter\n' \
    "$pn" "$ver" "$hash" "$sp" "$dres" "$herm" "$SYSTEM"
}

# header — EXACTLY the columns starter.nix reads:
#   0 pname  1 version  2 out_hash  3 out_path  4 deriver_resolves
#   5 hermetic_closure  6 published  7 system  8 tranche
printf 'pname\tversion\tout_hash\tout_path\tderiver_resolves\thermetic_closure\tpublished\tsystem\ttranche\n'

declare -A ROOT_MAIN

# Pass 1: every closure member of every root (keyed by nix-parsed pname), so the
# WHOLE fetchClosure is published. Emitted FIRST so the exact ROOT rows (pass 2)
# come LAST and WIN under starter.nix's last-wins-on-duplicate-pname rule.
for A in $ROOTS; do
  main="$($N eval --impure --raw --expr "(import $TRANCHE_NIX).$A.outPath" 2>/dev/null || true)"
  [ -n "$main" ] || { echo "FATAL: root $A has no outPath" >&2; exit 1; }
  # ensure it (and its closure) is actually realised
  $N build --impure --no-link --expr "(import $TRANCHE_NIX).$A" >/dev/null 2>&1 \
    || { echo "FATAL: root $A did not build" >&2; exit 1; }
  ROOT_MAIN[$A]="$main"
  # all outputs of the root, then full closure of each
  outs="$($N eval --impure --raw --expr \
      "builtins.concatStringsSep \"\n\" (map (o: o.outPath) ((import $TRANCHE_NIX).$A.all or [ (import $TRANCHE_NIX).$A ]))" 2>/dev/null \
      || printf '%s' "$main")"
  for o in $outs $main; do
    for m in $(nix-store -qR "$o" 2>/dev/null); do
      emit_row "$(pname_of "$m")" "$m"
    done
  done
done

# Pass 2: ROOT rows keyed by the ATTR name -> main output path (what base.nix /
# dixi.nix reference). Emitted LAST so last-wins binds the attr name to the
# root's own default output, never to a closure member that parsed to the same
# pname (e.g. bzip2 the bin vs bzip2-1.0.8 the lib).
for A in $ROOTS; do
  emit_row "$A" "${ROOT_MAIN[$A]}" force
done
