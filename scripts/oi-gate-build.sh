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
#  - libc DMAKE contamination: libc's Makefile uses `.PARALLEL: $(SUBDIRS)` and
#    nightly re-enters libc/i386 ~5x with .KEEP_STATE. Under dmake's parallel
#    engine, the target-specific conditional CPPFLAGS for the `_c89`/`64` object
#    variants (e.g. -D_C89_INTMAX32 meant for vsprintf_c89.o, -D_FILE_OFFSET_BITS=64
#    meant for truncate64.o) LEAK onto the base objects (vsprintf.o, walkstack.o)
#    that share the same source file. Result: `_sprintf_c89 multiply-defined` at
#    link, or `pointer-to-int-cast` in walkstack.c. DMAKE_MAX_JOBS=1 is NOT enough
#    (that only limits jobs within the parallel engine). The reliable fix is
#    DMAKE_MODE=serial, which disables the parallel engine outright. Seed build
#    only; a subsequent incremental build can raise concurrency once proto is seeded.
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
# CRITICAL: interrupted prior nightly runs leave stale objects/proto that cause
# bogus link failures (libc "multiply-defined *64 symbols", or -zfatal-warnings
# turning "dynamic library found on default search path (/lib)" into an error).
# NIGHTLY_OPTIONS -C is NOT enough after an interrupted run. The reliable reset
# is a full git clean (preserving our env file):
cp solnix.sh /root/solnix.sh.bak 2>/dev/null || true
git clean -dfx >/dev/null 2>&1 || true
cp /root/solnix.sh.bak solnix.sh 2>/dev/null || true
# solnix: recreate the serial dmake wrapper (git clean removes untracked files).
# nightly hardcodes DMAKE_MODE=parallel (nightly line ~887), which triggers a
# target-specific-CPPFLAGS leak in the parallel libc build: -D_C89_INTMAX32
# (meant for vsprintf_c89.o) bleeds onto the base pics/vsprintf.o, producing
# `_sprintf_c89 multiply-defined` at libc.so.1 link and aborting the build.
# Pointing $MAKE at a wrapper that runs `dmake -m serial` overrides the env
# DMAKE_MODE for every (recursive) make and builds libc correctly. solnix.sh
# sets `export MAKE=/code/illumos-gate/wrapmake`.
cat > /code/illumos-gate/wrapmake <<'WRAP'
#!/bin/sh
exec /opt/onbld/bin/i386/dmake -m serial "$@"
WRAP
chmod +x /code/illumos-gate/wrapmake
rm -f nightly.lock log/latest 2>/dev/null || true
nohup /opt/onbld/bin/nightly solnix.sh > /var/log/solnix-nightly-wrap.log 2>&1 &
echo "nightly pid $!"
echo "watch: tail -F $GATE/log/latest/nightly.log"
