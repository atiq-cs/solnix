#!/usr/bin/env bash
# oi-gate-build.sh — configure the illumos env file and launch the nightly build
# on the prepared OpenIndiana host. Run ON the host (as root), gate already cloned
# at /code/illumos-gate.
#
# Learnings baked in (first run):
#  - Copy usr/src/tools/env/illumos.sh -> solnix.sh. The template already sets
#    gcc-10 primary. We EMPTY the shadow compilers (gcc-14 not installed) and
#    UNSET ON_CLOSED_BINS (modern gate is fully open; nightly errors if it's set
#    but the dir is absent).
#  - illumos-gate needs a JDK for build tools: `pkg install developer/java/openjdk8`
#    provides /usr/java/bin/javac (the exact path nightly probes). Early
#    "No Java compiler found" / "Aborting due to missing compiler" lines from
#    per-tool version probes are NON-FATAL if openjdk8 is installed — nightly
#    proceeds into the real build.
#  - The sendmail "cannot exec" line is cosmetic (mail notification only).
set -euo pipefail
GATE=/code/illumos-gate
cd "$GATE"

if [ ! -f solnix.sh ]; then
  cp usr/src/tools/env/illumos.sh solnix.sh
  # no gcc-14 shadow
  sed -i '/^export SHADOW_CCS=gcc14/d; /^export SHADOW_CCCS=gcc14/d' solnix.sh
  printf 'export SHADOW_CCS=\nexport SHADOW_CCCS=\n' >> solnix.sh
  # fully-open build: no closed bins
  sed -i '/^export ON_CLOSED_BINS=/d' solnix.sh
  echo 'unset ON_CLOSED_BINS' >> solnix.sh
fi

# ensure JDK (build tools need javac)
[ -x /usr/java/bin/javac ] || pkg install -v developer/java/openjdk8

echo "=== launching nightly (multi-hour; nohup) ==="
pkill -9 -f "nightly solnix" 2>/dev/null || true
# CRITICAL: interrupted prior nightly runs leave stale objects that cause bogus
# "multiply-defined symbol" / "undefined stkptr/_curthread" link failures in
# libc. NIGHTLY_OPTIONS includes -C (clobber), but if a run was killed mid-build
# the tree can still be dirty. Ensure a clean tree first: `git status` should
# show only solnix.sh + test setup scripts; if libc fails, `bldenv solnix.sh`
# then `cd usr/src/lib/libc && dmake clobber` and re-run.
nohup /opt/onbld/bin/nightly solnix.sh > /var/log/solnix-nightly-wrap.log 2>&1 &
echo "nightly pid $!"
echo "watch: tail -F $GATE/log/latest/nightly.log"
