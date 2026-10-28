#!/bin/bash
# ib-img.sh <tag> : on ib (c6g.metal booted from aa64g-1). New image = aa64g-1's root (armpool/ROOT/braich@image,
# the shipped toplevel/nix/bash, byte-identical) + the 9 kernel modules from /big/kmods-<tag>.tar + a fresh
# boot_archive, as a GPT disk image /big/<tag>.img (ESP loader64.efi + ZFS armpool, aa64g-img.sh step 5 layout).
# Log /big/img-<tag>.log.
exec >/big/img-$1.log 2>&1
set -eux; date
export PATH=/usr/bin:/usr/sbin:/sbin; T=$1; IMG=/big/root-$T; POOL=armpool; TMP=imgpool; MNT=/big/espmnt; OUT=/big/$T.img
zfs list bigpool/root-$T >/dev/null 2>&1 && zfs destroy -r bigpool/root-$T
# the as-shipped aa64g-1 root (its @nix snapshot = what aa64g-img.sh sent into the image)
S=armpool/ROOT/braich@nix; zfs list $S
zfs send $S | zfs receive -u bigpool/root-$T; zfs set mountpoint=$IMG bigpool/root-$T; zfs mount bigpool/root-$T
cd $IMG; digest -a sha256 /big/kmods-$T.tar; tar xf /big/kmods-$T.tar
( cd $IMG && while read h m; do [ "$(digest -a sha256 $m)" = "$h" ] || { echo "KMOD_MISMATCH $m"; exit 6; }; done < /big/kmods-$T.sha256 )
[ -x /usr/bin/gzip ] || { cp -p /big/gz/gzip /usr/bin/gzip; RMGZ=1; }   # create_ramdisk gzips the archive (bootstrap only, not shipped)
ksh $IMG/boot/solaris/bin/create_ramdisk -R $IMG -p aarch64 -f cpio 2>&1 | tail -5
ls -la $IMG/platform/armv8/aarch64/boot_archive
# boot_archive gate: every rebuilt module inside == proto (bh-verify-g.sh, here against the tar)
D=/big/bag.$$; mkdir -p $D; cd $D; gzip -dc $IMG/platform/armv8/aarch64/boot_archive | cpio -idm 2>&1 | tail -1
while read h m; do [ "$(digest -a sha256 $m 2>/dev/null)" = "$h" ] && echo "BA_OK $m" || echo "BA_MISMATCH $m"; done < /big/kmods-$T.sha256
cd /; find $D -depth -delete
[ "$(grep -c "^BA_OK" /big/img-$T.log)" = 9 ] || { echo FATAL_BA; exit 7; }
zfs umount bigpool/root-$T; zfs set mountpoint=legacy bigpool/root-$T; zfs snapshot bigpool/root-$T@img
rm -f $OUT; mkfile 10g $OUT
D=$(lofiadm -la $OUT); FAT=$(echo $D | sed 's/p0/s0/'); FATR=$(echo $FAT | sed 's,/dsk/,/rdsk/,')
zpool create -B -t $TMP -m none $POOL ${D%p0}
zfs create -o canmount=noauto -o mountpoint=legacy $TMP/ROOT
zfs send bigpool/root-$T@img | zfs receive -u $TMP/ROOT/braich
zfs set canmount=noauto $TMP/ROOT/braich; zfs set mountpoint=legacy $TMP/ROOT/braich
zfs set org.opensolaris.libbe:uuid=$(uuidgen) $TMP/ROOT/braich; zfs set org.opensolaris.libbe:policy=static $TMP/ROOT/braich
zfs create -sV 1G $TMP/swap; zfs create -V 1G $TMP/dump
zpool set bootfs=$TMP/ROOT/braich $TMP; zpool set cachefile="" $TMP
zfs set canmount=noauto $TMP; zfs set mountpoint=/$POOL $TMP
zpool export $TMP
[ -e /boot/pmbr ] || { printf '\353\074\220' > /boot/pmbr; dd if=/dev/zero bs=1 count=507 >> /boot/pmbr 2>/dev/null
  printf '\125\252' >> /boot/pmbr; RMPMBR=1; }
yes | mkfs -F pcfs -o fat=32 $FATR
[ -n "${RMPMBR:-}" ] && rm -f /boot/pmbr
mkdir -p $MNT; mount -F pcfs $FAT $MNT; mkdir -p $MNT/EFI/BOOT
cp /boot/loader64.efi $MNT/EFI/BOOT/bootaa64.efi
ls -la $MNT/EFI/BOOT; umount $MNT
lofiadm -d $OUT
[ -n "${RMGZ:-}" ] && rm -f /usr/bin/gzip
digest -a sha256 $OUT; echo IMG-OK; date
