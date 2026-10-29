#!/bin/bash
# rb-img.sh <tag> : on box b (booted from m2). m3 = m2's root as shipped (armpool/ROOT/braich@img, the image's own
# snapshot) + site/aa64-archive-sync (/var/tmp/aa64-archive-sync.{sh,xml}). boot_archive unchanged (neither file is
# in the archive filelist). Disk layout = /scratch/solnix/aa64tls/ib-tls-img.sh step 4. Work pool "big" on instance
# store c3t1d0. Out: /big/<tag>.img, dd'd to the sdg volume c2t1d0 with read-back, /big/<tag>.img.gz. Log /var/tmp/img-<tag>.log
exec >/var/tmp/img-$1.log 2>&1
set -eux; date
export PATH=/usr/bin:/usr/sbin:/sbin:/usr/gnu/bin; T=$1; TMP=imgpool; POOL=armpool; MNT=/big/espmnt; OUT=/big/$T.img; TGT=c2t1d0
zpool list big >/dev/null 2>&1 || zpool create -f -m /big big c3t1d0
IMG=/big/root-$T
zfs list big/root-$T >/dev/null 2>&1 && zfs destroy -r big/root-$T
zfs send armpool/ROOT/braich@img | zfs receive -u big/root-$T; zfs destroy big/root-$T@img
zfs set mountpoint=$IMG big/root-$T; zfs mount big/root-$T
[ "$(head -1 $IMG/etc/path_to_inst)" = "#path_to_inst_bootstrap_1" ] && [ -f $IMG/reconfigure ] || { echo "NOT_PRISTINE"; exit 4; }
cp /var/tmp/aa64-archive-sync.sh $IMG/usr/lib/aa64/; chmod 0555 $IMG/usr/lib/aa64/aa64-archive-sync.sh
cp /var/tmp/aa64-archive-sync.xml $IMG/lib/svc/manifest/site/; chmod 0644 $IMG/lib/svc/manifest/site/aa64-archive-sync.xml
chown root:root $IMG/usr/lib/aa64/aa64-archive-sync.sh $IMG/lib/svc/manifest/site/aa64-archive-sync.xml
svccfg validate $IMG/lib/svc/manifest/site/aa64-archive-sync.xml
ls -l $IMG/usr/lib/aa64 $IMG/lib/svc/manifest/site; digest -a sha256 $IMG/usr/lib/aa64/* $IMG/lib/svc/manifest/site/* $IMG/platform/armv8/aarch64/boot_archive
zfs umount big/root-$T; zfs set mountpoint=legacy big/root-$T; zfs snapshot big/root-$T@img
rm -f $OUT; mkfile 10g $OUT
D=$(lofiadm -la $OUT); FAT=$(echo $D | sed 's/p0/s0/'); FATR=$(echo $FAT | sed 's,/dsk/,/rdsk/,')
zpool create -B -t $TMP -m none $POOL ${D%p0}
zfs create -o canmount=noauto -o mountpoint=legacy $TMP/ROOT
zfs send big/root-$T@img | zfs receive -u $TMP/ROOT/braich
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
mkdir -p $MNT; mount -F pcfs $FAT $MNT; mkdir -p $MNT/EFI/BOOT; cp /boot/loader64.efi $MNT/EFI/BOOT/bootaa64.efi; umount $MNT
lofiadm -d $OUT
RAW=$(digest -a sha256 $OUT); echo "RAW $RAW"
dd if=$OUT of=/dev/rdsk/${TGT}p0 bs=1024k; sync
RB=$(dd if=/dev/rdsk/${TGT}p0 bs=1024k count=10240 2>/dev/null | digest -a sha256); echo "READBACK $RB"
[ "$RAW" = "$RB" ] || { echo "READBACK_MISMATCH"; exit 8; }
/var/tmp/gzip -1 -c $OUT > $OUT.gz; echo "GZ $(digest -a sha256 $OUT.gz)"; ls -l $OUT.gz
echo IMG-OK; date
