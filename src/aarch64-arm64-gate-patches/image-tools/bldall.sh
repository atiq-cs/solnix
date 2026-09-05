#!/bin/bash
# WHAT: rebuild the aarch64 genunix + unix carrying the GIC multi-region fix.
# WHY the priv_const.c step: uts/aarch64/Makefile generates priv_const.c in a
# "prereq" pass before the parallel build; invoking genunix directly (as we do,
# to avoid a full multi-hour nightly) skips that pass, so genunix fails to link
# on a missing priv_const.o. Generate it explicitly first.
# The -T aarch64 flag is MANDATORY: without it MACH defaults to the native i386
# and the whole build silently goes -m32/-Di386 with the host x86 assembler.
set -x
export PATH=/usr/gnu/bin:/opt/onbld/bin:/usr/bin:/usr/sbin:/bin:/opt/ooce/bin
export LOGNAME=omnios MAILTO=omnios
cd /aarch64/arm64-gate/illumos-gate || exit 1

/aarch64/arm64-gate/illumos-gate/usr/src/tools/scripts/bldenv -d -T aarch64 \
    /aarch64/arm64-gate/env/aarch64 <<'INNER'
set -x
cd $SRC/uts/aarch64 || exit 1
dmake $SRC/uts/common/os/priv_const.c
ls -la $SRC/uts/common/os/priv_const.c

cd $SRC/uts/aarch64/genunix || exit 1
dmake -j 32 all
echo "=== GENUNIX_RC=$? ==="
ls -la debug64/genunix obj64/libgenunix.so

cd $SRC/uts/armv8/unix || exit 1
dmake debug64/assym.h
dmake -j 32 all
echo "=== UNIX_RC=$? ==="
ls -la debug64/unix
INNER
echo "=== SCRIPT_DONE ==="
