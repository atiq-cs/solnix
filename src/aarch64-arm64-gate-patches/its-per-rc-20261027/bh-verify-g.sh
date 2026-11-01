#!/bin/bash
exec >/build/verify-g.log 2>&1
D=/var/tmp/bag.$$; mkdir -p $D; cd $D
gzip -dc /braich_image/platform/armv8/aarch64/boot_archive | cpio -idm 2>&1 | tail -1
P=/aarch64/arm64-gate/illumos-gate/proto/root_aarch64
for m in platform/armv8/kernel/aarch64/unix kernel/aarch64/genunix kernel/drv/aarch64/wc kernel/drv/aarch64/ena kernel/drv/aarch64/nvme platform/armv8/kernel/drv/aarch64/gicv3_its kernel/drv/aarch64/ecam kernel/misc/aarch64/pcierc platform/armv8/kernel/drv/aarch64/rootnex; do
  a=$(digest -a sha256 $m 2>&1 | cut -c1-16); b=$(digest -a sha256 $P/$m | cut -c1-16)
  [ "$a" = "$b" ] && r=OK || r=MISMATCH
  echo "$r $m ba $a proto $b"
done
A=etc/driver_aliases
echo "ba aliases $(digest -a sha256 $A | cut -c1-16) ntm $(digest -a sha256 etc/name_to_major | cut -c1-16)"
echo "pl011=$(grep -c 'arm,pl011' $A) its=$(grep -c '^gicv3_its ' $A)"
cd /; find $D -depth -delete
echo VERIFY_G_DONE
