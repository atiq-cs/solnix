#!/usr/bin/env bash
# oi-fixpoint.sh — re-verify wave-4 modules that FAILED import/load only because
# a dependency built later in the same batch wasn't on the search path at check
# time. The module IS a valid published store path; its deps are ALSO published.
# Here we pull the whole set of published module paths, then re-run the
# import/load check with EVERY published module dir of the same interpreter on
# PYTHONPATH / PERL5LIB (the real runtime resolution the cache provides). Ones
# that now pass are genuine recoveries -> flip cached=yes.
#
# Runs ON a builder. Args:
#   oi-fixpoint.sh py39   <all-py39-paths-file>   <fail-modules-file>
#   oi-fixpoint.sh py313  <all-py313-paths-file>  <fail-modules-file>
#   oi-fixpoint.sh perl542 <all-perl-paths-file>  <fail-modules-file>
#
# all-paths-file: one /nix/store/... published path per line (same interpreter).
# fail-modules-file: lines "importname<TAB>/nix/store/...builtpath" for the
#   modules that FAILED (built path is the FAILed module's own store path).
# Output: RESULT<TAB>module<TAB>OK|FAIL<TAB>storepath|reason
set -u
export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:$PATH
export NIX_CONF_DIR=/nix-tools/etc/nix
TAG="$1"; ALLPATHS="$2"; FAILS="$3"

PY39=/nix/store/63f9kp8ixyw0mq18fhmk4zj2j0lv6fcw-solnix-python-39-3.9.20/bin/python3.9
PY313=/nix/store/kvl140jbk20aqiq9qqrr79vvwv7hnsaf-solnix-python-313-3.13.1/bin/python3.13
PERL=/nix/store/njywmx7wnc34z8ff086mw9rz44kn1p02-solnix-perl-5.42.0/bin/perl

# 1. Pull every published module path of this interpreter (closure) from cache.
echo "=== pulling $(wc -l < "$ALLPATHS") published $TAG paths ===" >&2
sh /var/tmp/oi-pull.sh $(cat "$ALLPATHS") >/tmp/fixpoint-pull.$TAG.log 2>&1 || true

case "$TAG" in
  py39|py313)
    [ "$TAG" = py39 ] && PY="$PY39" MM=python3.9 || PY="$PY313" MM=python3.13
    # Build a PYTHONPATH of every published site-packages dir for this interpreter.
    PP=""
    while read -r sp; do
      [ -n "$sp" ] || continue
      d="$sp/lib/$MM/site-packages"
      [ -d "$d" ] && PP="$d${PP:+:}$PP"
    done < "$ALLPATHS"
    while IFS=$'\t' read -r mod builtpath; do
      [ -n "$mod" ] || continue
      # own site-packages first
      own="$builtpath/lib/$MM/site-packages"
      if PYTHONPATH="$own:$PP" "$PY" -c "import $mod" >/dev/null 2>&1; then
        echo "RESULT	$mod	OK	$builtpath"
      else
        err=$(PYTHONPATH="$own:$PP" "$PY" -c "import $mod" 2>&1 | tail -1)
        echo "RESULT	$mod	FAIL	$err"
      fi
    done < "$FAILS"
    ;;
  perl542)
    # Build a PERL5LIB of every published perl lib dir.
    PL=""
    while read -r sp; do
      [ -n "$sp" ] || continue
      for d in "$sp"/lib/perl5 "$sp"/lib/perl5/*-solaris*; do
        [ -d "$d" ] && PL="$d${PL:+:}$PL"
      done
    done < "$ALLPATHS"
    while IFS=$'\t' read -r mod builtpath; do
      [ -n "$mod" ] || continue
      own=$(find "$builtpath/lib/perl5" -maxdepth 2 -type d 2>/dev/null | tr '\n' ':')
      if PERL5LIB="$own$PL" "$PERL" -e "require $mod; 1" >/dev/null 2>&1; then
        echo "RESULT	$mod	OK	$builtpath"
      else
        err=$(PERL5LIB="$own$PL" "$PERL" -e "require $mod; 1" 2>&1 | head -1)
        echo "RESULT	$mod	FAIL	$err"
      fi
    done < "$FAILS"
    ;;
esac
echo "=== oi-fixpoint $TAG done ==="
