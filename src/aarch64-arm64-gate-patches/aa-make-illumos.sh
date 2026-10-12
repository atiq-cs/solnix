#!/bin/bash
exec >>/var/log/aa-makeillumos.log 2>&1
set -x
echo "=== MAKE ILLUMOS (full nightly) START $(date) ==="
export PATH=/usr/gnu/bin:/opt/onbld/bin:/usr/bin:/usr/sbin:/bin:/opt/ooce/bin
export LOGNAME=root MAILTO=root
# ON_CLOSED_BINS is set by env to /opt/onbld/closed which EXISTS (illumos-closed installed)
cd /aarch64/arm64-gate/illumos-gate || exit 1
# nightly -T aarch64 env/aarch64 : -FnCDAmprt builds tools, world (DEBUG), packages.
# -t builds the tools (cw/vtfontcvt/ctf...) which the standalone unix build lacked.
/aarch64/arm64-gate/illumos-gate/usr/src/tools/scripts/nightly -T aarch64 /aarch64/arm64-gate/env/aarch64
echo "=== NIGHTLY_RC=$? $(date) ==="
