#!/bin/ksh93

set -e

DISK=$PWD/qemu-setup/illumos-disk.img
POOL=armpool			# Must match build_image
MNT=/mnt
ROOTFS=ROOT/braich
ROOT=$MNT/$ROOTFS
DISKSIZE=8g
BE_UUID=`/usr/bin/uuidgen`

if [[ ! -f Makefile || ! -d illumos-gate ]]; then
	print -u2 "$0 should be run from the root of arm64-gate"
	exit 2
fi

if [ ! -f $PWD/illumos-gate/proto/root_aarch64/boot/loader64.efi ]; then
	print -u2 "loader64.efi not found in proto area"
	exit 2
fi

if [ ! -f $PWD/build/u-boot-qemu/u-boot.bin ]; then
	print -u2 "u-boot-qemu/u-boot.bin not found in build area"
	exit 2
fi

if [[ $(zonename) != global ]]; then
	print -u2 "$0 should be run in the global zone"
	exit 2
fi

mkdir -p $PWD/qemu-setup

mkfile $DISKSIZE $DISK
BLK_DEVICE=$(lofiadm -la $DISK)
RAW_DEVICE=${BLK_DEVICE/dsk/rdsk}
FAT_RAW=${RAW_DEVICE/p0/s0}
FAT_BLK=${BLK_DEVICE/p0/s0}

print "Building a GPT-partitioned image"
zpool create -B -t $POOL -m $MNT $POOL ${BLK_DEVICE%p0}

print "Populating root"

zfs create -o canmount=noauto -o mountpoint=legacy $POOL/ROOT

zfs receive -u $POOL/$ROOTFS < out/illumos.zfs
zfs set canmount=noauto $POOL/$ROOTFS
zfs set mountpoint=legacy $POOL/$ROOTFS
zfs set org.opensolaris.libbe:uuid=$BE_UUID $POOL/$ROOTFS
zfs set org.opensolaris.libbe:policy=static $POOL/$ROOTFS

zfs create -sV 1G $POOL/swap
zfs create -V 1G $POOL/dump

zpool set bootfs=$POOL/$ROOTFS $POOL
zpool set cachefile="" $POOL
zfs set canmount=noauto $POOL
zfs set mountpoint=/$POOL $POOL
zpool export $POOL

print "Populating boot"
# Format the FAT partition and copy in the boot files.
yes | mkfs -F pcfs -o fat=32,b=bootfs $FAT_RAW
mount -F pcfs $FAT_BLK $MNT
mkdir -p $MNT/EFI/BOOT
cp $PWD/illumos-gate/proto/root_aarch64/boot/loader64.efi \
    $MNT/EFI/BOOT/bootaa64.efi
umount $MNT

lofiadm -d $DISK
cp build/u-boot-qemu/u-boot.bin qemu-setup
