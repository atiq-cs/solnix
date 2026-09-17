#!/usr/bin/env bash
# regen-starter-tsv.sh — MECHANICALLY regenerate the x86_64-solaris dixi starter
# rows of docs/registry/real-derivations.tsv from a live illumos build.
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
# walks each root's real closure with `nix-store -qR`, and emits tsv rows
# straight from `nix-store --query` output. Re-run it after any tree change and
# the x86_64-solaris starter rows track reality — no hand-typed store paths.
#
# ⚠️ ARCH SCOPE — THIS SCRIPT REGENERATES ONE SYSTEM (SYSTEM, default
# x86_64-solaris). The registry also holds aarch64-solaris, sparcv9-solaris and
# legacy "2.3.16" rows that this build does NOT reproduce. To avoid DELETING
# those on every run, pass MERGE_TSV=<existing real-derivations.tsv>: the script
# then emits (a) every existing row whose system column != SYSTEM, verbatim, then
# (b) the freshly-built SYSTEM rows LAST. Within SYSTEM the fresh rows win
# (starter.nix is last-wins on duplicate pname); other-arch rows are preserved
# untouched. WITHOUT MERGE_TSV it emits only the freshly-built SYSTEM rows — use
# that only when you truly want a SYSTEM-only tsv.
#
# RUN ON the illumos build node (Nix 2.24.15 at /nix-tools224), as root:
#   TRANCHE_NIX=/root/tranche-224.nix MERGE_TSV=/path/to/old/real-derivations.tsv \
#     ./regen-starter-tsv.sh > real-derivations.tsv
set -euo pipefail

TRANCHE_NIX="${TRANCHE_NIX:?set TRANCHE_NIX=/root/tranche-224.nix}"
SYSTEM="${SYSTEM:-x86_64-solaris}"
MERGE_TSV="${MERGE_TSV:-}"
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

FRESH="$(mktemp)"; trap 'rm -f "$FRESH"' EXIT

# emit one fresh tsv row into $FRESH (deriver_resolves + hermetic computed here).
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
    "$pn" "$ver" "$hash" "$sp" "$dres" "$herm" "$SYSTEM" >> "$FRESH"
}

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

# ---- assemble the output ------------------------------------------------------
# header — EXACTLY the columns starter.nix reads:
#   0 pname  1 version  2 out_hash  3 out_path  4 deriver_resolves
#   5 hermetic_closure  6 published  7 system  8 tranche
printf 'pname\tversion\tout_hash\tout_path\tderiver_resolves\thermetic_closure\tpublished\tsystem\ttranche\n'

# MERGE: preserve every EXISTING row whose system column (field 8) != SYSTEM, so
# aarch64-solaris / sparcv9-solaris / legacy "2.3.16" rows survive. Emitted BEFORE
# the fresh SYSTEM rows so, within SYSTEM, the fresh rows win last-wins. The old
# SYSTEM rows are intentionally dropped (they are the orphaned lineage this regen
# replaces). The header line ("pname\t...") is skipped.
if [ -n "$MERGE_TSV" ]; then
  [ -r "$MERGE_TSV" ] || { echo "FATAL: MERGE_TSV not readable: $MERGE_TSV" >&2; exit 2; }
  awk -F'\t' -v sys="$SYSTEM" 'NR==1{next} $1=="pname"{next} $8!=sys' "$MERGE_TSV"
fi

# fresh SYSTEM rows LAST
cat "$FRESH"
