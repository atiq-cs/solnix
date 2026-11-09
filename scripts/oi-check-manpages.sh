#!/usr/bin/env bash
# oi-check-manpages.sh — detect whether a built solnix package ships man pages,
# by inspecting the REAL store path (pulled from the solnix.io cache), not by
# guessing. Runs ON a builder (has Nix 2.3.16 + cache access). Emits one line
# per package for the ledger backfill:
#
#     MAN<TAB><attr><TAB><count>          (count = man files under share/man+man)
#     MAN<TAB><attr><TAB>MISSING          (not cached / could not resolve)
#
# A package's man count comes from $out/.manifest-man when present (written by
# the fixed mk-userland-pkg.nix), else from a live count of $out/share/man,
# $out/man, $out/usr/share/man, $out/usr/man (regular files, minus whatis/windex).
#
#   oi-check-manpages.sh <attr> [<attr> ...]      # packages.nix attr names (gcc build)
#   oi-check-manpages.sh --paths <storepath> [...]  # inspect explicit cached out paths
#
# The --paths mode is for backfilling ALREADY-CACHED artifacts whose hash was
# produced by an older builder (so re-instantiation would give a different hash):
# feed it the real cached /nix/store/... out paths and it pulls+counts each.
#
# Repo expected at /var/tmp/solnix-repo. Toolchain/deps pulled from the cache via
# oi-pull.sh on demand. Detached-friendly: dispatch it through scripts/oi-job.sh
# and poll; NEVER block SSH on the whole set.
set -u
export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:$PATH
export NIX_CONF_DIR=/nix-tools/etc/nix
REPO=/var/tmp/solnix-repo
PKGS=$REPO/pkgs/illumos/packages.nix
CACHE=https://s3.solnix.io/solnix-cache
KEY="cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8="

# count man files in a realised store path (dir). Prefer the build-stamped
# .manifest-man; fall back to a live find.
count_man() {
  out="$1"
  if [ -f "$out/.manifest-man" ]; then
    tr -d ' \n' < "$out/.manifest-man"; return
  fi
  n=0
  for md in "$out/share/man" "$out/man" "$out/usr/share/man" "$out/usr/man"; do
    [ -d "$md" ] || continue
    c=$(find "$md" -type f 2>/dev/null | grep -Ev '/(whatis|windex|man\.cf)$' | wc -l | tr -d ' ')
    n=$((n + c))
  done
  printf '%s' "$n"
}

for attr in "$@"; do
  if [ "$attr" = "--paths" ]; then continue; fi
  case " $* " in *" --paths "*)
    # explicit-path mode: $attr is a /nix/store/... out path
    out="$attr"
    if [ ! -e "$out" ]; then sh /var/tmp/oi-pull.sh "$out" >/dev/null 2>&1 || true; fi
    if [ ! -e "$out" ]; then echo "MAN	$(basename "$out")	MISSING"; continue; fi
    echo "MAN	$(basename "$out")	$(count_man "$out")"; continue;;
  esac
  # resolve the gcc-built out path. instantiate is cheap; realise pulls from cache.
  drv=$(nix-instantiate "$PKGS" -A "$attr.gcc" 2>/dev/null)
  if [ -z "$drv" ]; then echo "MAN	$attr	MISSING"; continue; fi
  out=$(nix-store -q --outputs "$drv" 2>/dev/null | head -1)
  if [ -z "$out" ]; then echo "MAN	$attr	MISSING"; continue; fi
  # pull from cache (out only; man pages live in out). per-path retry inside oi-pull.
  if [ ! -e "$out" ]; then
    sh /var/tmp/oi-pull.sh "$out" >/dev/null 2>&1 || true
  fi
  if [ ! -e "$out" ]; then echo "MAN	$attr	MISSING"; continue; fi
  echo "MAN	$attr	$(count_man "$out")"
done
echo "=== oi-check-manpages done ==="
