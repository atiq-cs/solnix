#!/bin/bash
# WHAT: run the aarch64 nightly directly, bypassing `make illumos`.
# WHY bypass: `make illumos` depends on ALL SETUP_TARGETS, including u-boot,
# which fails on this host for lack of gnutls (mkeficapsule). u-boot is the
# QEMU/RPi4 boot path, irrelevant to Graviton (UEFI) -- so don't drag in an
# unneeded prerequisite.
# WHY unset ON_CLOSED_BINS: env/aarch64 sets it to /opt/onbld/closed, which does
# not exist here, and nightly's check_closed_bins aborts when the variable is
# set but the directory is absent. illumos needs no closed binaries (and
# NIGHTLY_OPTIONS carries -C), so clearing it is correct, not a workaround.
# NIGHTLY_OPTIONS='-FnCDAmprt'; the -p is what populates
# packages/aarch64/nightly/repo.redist, which build_image.sh consumes.
set -x
export PATH=/usr/gnu/bin:/opt/onbld/bin:/usr/bin:/usr/sbin:/bin:/opt/ooce/bin
export LOGNAME=omnios MAILTO=omnios
cd /aarch64/arm64-gate/illumos-gate || exit 1

# env/aarch64 exports ON_CLOSED_BINS; strip it after the env file is sourced by
# wrapping nightly in a shell that clears it.
cat > /tmp/nightly-env-override.sh <<'OVR'
. /aarch64/arm64-gate/env/aarch64
unset ON_CLOSED_BINS
OVR

ONBLD_NOENV= /aarch64/arm64-gate/illumos-gate/usr/src/tools/scripts/nightly \
    -T aarch64 /tmp/nightly-env-override.sh
echo "=== NIGHTLY_RC=$? ==="
