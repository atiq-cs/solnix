#!/bin/bash
# unpack boot_archive, compare pcierc/ecam/driver_aliases to the build outputs
exec >/build/verify-ba.log 2>&1
set -x
D=/var/tmp/ba.$$; mkdir -p $D; cd $D
BA=/braich_image/platform/armv8/aarch64/boot_archive
file $BA
( gzip -dc $BA 2>/dev/null || cat $BA ) | cpio -idm 2>&1 | tail -1
P=/aarch64/arm64-gate/illumos-gate/proto/root_aarch64
for m in kernel/misc/aarch64/pcierc kernel/drv/aarch64/ecam platform/armv8/kernel/aarch64/unix; do
  echo "$m $(digest -a sha256 $m | cut -c1-16) proto $(digest -a sha256 $P/$m | cut -c1-16)"
done
echo "aliases $(digest -a sha256 etc/driver_aliases | cut -c1-16) pl011=$(grep -c 'arm,pl011' etc/driver_aliases)"
cd /; find $D -depth -delete
echo VERIFY_BA_DONE
