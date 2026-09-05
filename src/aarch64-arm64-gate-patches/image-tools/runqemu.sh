#!/usr/bin/ksh93
# WHAT: build the bootable disk image, capturing the exit status.
# build_qemu.sh also runs `set -e`, so record $? explicitly (same reason as
# runimg2.sh: failures otherwise vanish behind cleanup).
export PATH=/usr/gnu/bin:/opt/onbld/bin:/usr/bin:/usr/sbin:/bin:/opt/ooce/bin
cd /aarch64/arm64-gate || exit 1
/usr/bin/ksh93 -x ./tools/build_qemu.sh
rc=$?
echo "=== BUILD_QEMU_RC=$rc ==="
ls -la /aarch64/arm64-gate/*.img /aarch64/arm64-gate/out/*.img 2>/dev/null
