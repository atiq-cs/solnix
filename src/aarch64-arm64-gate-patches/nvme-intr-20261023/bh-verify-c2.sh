#!/bin/bash
exec >/build/verify-c2.log 2>&1
D=/var/tmp/bac2.$$; mkdir -p $D; cd $D
gzip -dc /braich_image/platform/armv8/aarch64/boot_archive | cpio -idm 2>&1 | tail -1
P=/aarch64/arm64-gate/illumos-gate/proto/root_aarch64
for m in kernel/misc/aarch64/pcierc kernel/drv/aarch64/ecam platform/armv8/kernel/aarch64/unix kernel/drv/aarch64/nvme platform/armv8/kernel/drv/aarch64/gicv3_its; do
  echo "$m $(digest -a sha256 $m | cut -c1-16) proto $(digest -a sha256 $P/$m | cut -c1-16)"
done
A=etc/driver_aliases
echo "ba aliases $(digest -a sha256 $A | cut -c1-16) ntm $(digest -a sha256 etc/name_to_major | cut -c1-16)"
echo "pl011=$(grep -c 'arm,pl011' $A) its=$(grep -c '^gicv3_its ' $A) v2m=$(grep -c '^gicv2m ' $A) cpudrv=$(grep -c '^cpudrv ' $A)"
ls kernel/drv/aarch64/nvme.conf kernel/drv/nvme.conf 2>&1
cd /; find $D -depth -delete
echo VERIFY_C2_DONE
