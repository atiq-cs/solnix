#!/usr/bin/ksh93
# WHAT: run build_image.sh and CAPTURE its exit status.
# WHY: the script runs `set -e` with a `trap 'zfs destroy -r $DATASET' EXIT`, so
# any failing step tears down the dataset and leaves the log ending mid-step with
# no error text. Recording $? (and disabling the trap's masking by logging first)
# is the only way to see which step actually failed.
export PATH=/usr/gnu/bin:/opt/onbld/bin:/usr/bin:/usr/sbin:/bin:/opt/ooce/bin
cd /aarch64/arm64-gate || exit 1
/usr/bin/ksh93 -x ./tools/build_image.sh
rc=$?
echo "=== BUILD_IMAGE_RC=$rc ==="
