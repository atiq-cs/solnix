#!/bin/sh
set -x
beadm mount ctA /mnt/ctA
M=/mnt/ctA
# layout (i): a store INSIDE the BE dataset (BE's own /nix dir, shadowed on the live host by rpool/nix)
mkdir -p $M/nix/store/xxxx-kernel/platform/i86pc/kernel/amd64 $M/nix/store/xxxx-kernel/platform/i86pc/amd64
cp -p /platform/i86pc/kernel/amd64/unix $M/nix/store/xxxx-kernel/platform/i86pc/kernel/amd64/unix
cp -p /platform/i86pc/amd64/boot_archive $M/nix/store/xxxx-kernel/platform/i86pc/amd64/boot_archive
ln -s /nix/store/xxxx-kernel/platform/i86pc/kernel/amd64/unix $M/ct/unix-instore
ln -s /nix/store/xxxx-kernel/platform $M/ct/plat
ln -s /nix/store/xxxx-kernel/platform/i86pc/amd64/boot_archive $M/ct/ba-instore
ls -l $M/ct
beadm unmount ctA
# B3: svc.startd -> rpool/nix (cross-dataset), no early mount
# B4: same + inittab sysinit mounting rpool/nix BEFORE the smf entry
cp -p /lib/svc/bin/svc.startd /nix/ctest/svc.startd
for be in ctB3 ctB4; do beadm destroy -Ffs $be >/dev/null 2>&1; beadm create $be; mkdir -p /mnt/$be; beadm mount $be /mnt/$be
  mv /mnt/$be/lib/svc/bin/svc.startd /mnt/$be/lib/svc/bin/svc.startd.real
  ln -s /nix/ctest/svc.startd /mnt/$be/lib/svc/bin/svc.startd
done
awk '/^smf::sysinit/{print "nx::sysinit:/sbin/zfs mount rpool/nix >/dev/msglog 2<>/dev/msglog </dev/console"} {print}' /mnt/ctB4/etc/inittab > /tmp/it && cp /tmp/it /mnt/ctB4/etc/inittab
grep -v '^#' /mnt/ctB4/etc/inittab
for be in ctB3 ctB4; do ls -l /mnt/$be/lib/svc/bin/svc.startd; beadm unmount $be; done
zfs list -H -o name,mountpoint,canmount rpool/nix
