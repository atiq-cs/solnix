#!/bin/ksh93
# aa-make-image.sh — assemble a bootable aarch64 illumos QEMU-virt disk from the
# RESTORED proto/root_aarch64 (no pkg repo, no cross toolchain needed). Adapted
# from richlowe/arm64-gate tools/build_image.sh + build_qemu.sh, but the root FS
# is populated directly from the archived proto instead of `pkg image-create`
# (the nightly pkg repo + OmniOS braich repo were NOT archived; only the proto).
#
# Produces: /aarch64/out/illumos-disk.img — a GPT disk with
#   - an ESP (pcfs FAT32) holding loader64.efi -> EFI/BOOT/bootaa64.efi
#   - a ZFS pool `armpool` with ROOT/braich (the proto), bootfs set, swap+dump.
# Boot it with: qemu-system-aarch64 -machine virt -bios <u-boot|edk2> -drive ...
#
# RUN AS ROOT in the global zone. Runs on the amd64 illumos host (ZFS/lofi/pcfs
# are host tooling; the aarch64 bits are just files copied in). Long-ish (ZFS
# send/recv of ~1GB proto) -> run via scripts/oi-job.sh detached.
set -e

PROTO=/aarch64/arm64-gate/illumos-gate/proto/root_aarch64
HARNESS=/aarch64/gate/arm64-gate           # for tools/dev.tar + svc profiles
OUT=/aarch64/out
DISK=$OUT/illumos-disk.img
DISKSIZE=8g
POOL=armpool
MNT=/armmnt
ROOTFS=ROOT/braich
ROOT=$MNT/$ROOTFS
IMGDS="$(zfs list -Ho name / | cut -d/ -f1)/braich_image"
IMGROOT=/braich_image
BE_UUID=$(/usr/bin/uuidgen)

[ -f $PROTO/boot/loader64.efi ] || { echo "FATAL: no loader64.efi in proto" >&2; exit 2; }
[ -f $PROTO/platform/armv8/kernel/aarch64/unix ] || { echo "FATAL: no aarch64 unix" >&2; exit 2; }
[ "$(zonename)" = global ] || { echo "FATAL: not global zone" >&2; exit 2; }

mkdir -p $OUT

echo "=== 1. stage the root FS from proto into a scratch ZFS dataset ==="
zfs list $IMGDS >/dev/null 2>&1 && zfs destroy -r $IMGDS
zfs create -o mountpoint=$IMGROOT $IMGDS
# cp -a preserves symlinks (lib/64 -> ., usr/lib/*.so), perms, CTF in kmods.
/usr/gnu/bin/cp -a $PROTO/. $IMGROOT/

echo "=== 2. minimal /dev + reconfigure + boot config ==="
[ -f $HARNESS/tools/dev.tar ] && tar -xf $HARNESS/tools/dev.tar -C $IMGROOT || echo "WARN: no dev.tar (skeleton /dev missing)"
touch $IMGROOT/reconfigure
mkdir -p $IMGROOT/tmp $IMGROOT/proc $IMGROOT/system/contract $IMGROOT/system/object \
         $IMGROOT/etc/svc/volatile $IMGROOT/var/run 2>/dev/null || true

# nodename + hosts + no password (dev image)
echo "solnix-aa" > $IMGROOT/etc/nodename
[ -f $IMGROOT/etc/default/login ] && sed -i 's/^PASSREQ=YES/PASSREQ=NO/' $IMGROOT/etc/default/login 2>/dev/null || true

# SMF profiles (the proto ships the generic ones; link them like build_image.sh)
if [ -d $IMGROOT/etc/svc/profile ]; then
  ( cd $IMGROOT/etc/svc/profile
    [ -f ns_files.xml ] && ln -sf ns_files.xml name_service.xml || true
    [ -f generic_limited_net.xml ] && ln -sf generic_limited_net.xml generic.xml || true
    [ -f inetd_generic.xml ] && ln -sf inetd_generic.xml inetd_services.xml || true
    [ -f platform_none.xml ] && ln -sf platform_none.xml platform.xml || true )
fi

# swap/dump vfstab + dumpadm (zvols created below)
echo "/dev/zvol/dsk/$POOL/swap - - swap - no -" >> $IMGROOT/etc/vfstab

# SMF repository: seed from the proto's seed DB (a fresh svccfg import needs the
# onbld svc.configd which is NOT in the restored proto; the seed DB is enough to
# reach a boot milestone -- svc.startd will populate from manifests at first boot
# via the manifest-import service). This is the minimal path to a booting kernel.
if [ -f $IMGROOT/lib/svc/seed/global.db ]; then
  cp $IMGROOT/lib/svc/seed/global.db $IMGROOT/etc/svc/repository.db
  chown root:sys $IMGROOT/etc/svc/repository.db 2>/dev/null || true
  chmod 0600 $IMGROOT/etc/svc/repository.db
fi

# name_to_major / driver_aliases: the gate proto ships a near-empty table (pkg
# install would assemble the full one). Inject the generated full table so the
# kernel can bind rootnex + the arm platform drivers (else: panic "Couldn't
# find major number for 'rootnex'"). See aa-fix-ntm.sh.
if [ -f $OUT/name_to_major.aarch64 ]; then
  cp $OUT/name_to_major.aarch64 $IMGROOT/etc/name_to_major
  echo "injected name_to_major ($(wc -l < $IMGROOT/etc/name_to_major) entries)"
fi
if [ -f $OUT/driver_aliases.aarch64 ]; then
  cp $OUT/driver_aliases.aarch64 $IMGROOT/etc/driver_aliases
  echo "injected driver_aliases ($(wc -l < $IMGROOT/etc/driver_aliases) entries)"
fi

echo "=== 3. boot config: serial console, verbose, impl-arch bootfile ==="
mkdir -p $IMGROOT/boot/conf.d
cat > $IMGROOT/boot/conf.d/00-aarch64-defaults.conf <<'EOF'
bootfile="/platform/${IMPLARCH}/kernel/${ISADIR}/unix;/platform/${BASEARCH}/kernel/${ISADIR}/unix"
console="${default-uart-name},text"
boot-args="-vm verbose"
EOF

echo "=== 4. boot_archive (ramdisk) via create_ramdisk ==="
mkdir -p $IMGROOT/platform/armv8/aarch64
if [ -x $IMGROOT/boot/solaris/bin/create_ramdisk ]; then
  # create_ramdisk is a ksh script; run it against the staged root.
  ksh $IMGROOT/boot/solaris/bin/create_ramdisk -R $IMGROOT -p aarch64 -f cpio 2>&1 | tail -20 \
    || echo "WARN: create_ramdisk failed (loader may still boot unix directly)"
else
  echo "WARN: no create_ramdisk in proto"
fi

echo "=== 5. snapshot + zfs send stream ==="
zfs snapshot $IMGDS@image
zfs send $IMGDS@image > $OUT/illumos.zfs
echo "illumos.zfs: $(ls -la $OUT/illumos.zfs | awk '{print $5}') bytes"

echo "=== 6. build the GPT disk: ESP(pcfs) + ZFS armpool ==="
rm -f $DISK
mkfile $DISKSIZE $DISK
BLK_DEVICE=$(lofiadm -la $DISK)          # e.g. /dev/dsk/c1t...p0
RAW_DEVICE=${BLK_DEVICE/dsk/rdsk}
FAT_RAW=${RAW_DEVICE/p0/s0}
FAT_BLK=${BLK_DEVICE/p0/s0}

# -B adds the boot (ESP) slice; zpool create partitions the whole lofi device.
zpool create -B -t $POOL -m $MNT $POOL ${BLK_DEVICE%p0}
zfs create -o canmount=noauto -o mountpoint=legacy $POOL/ROOT
zfs receive -u $POOL/$ROOTFS < $OUT/illumos.zfs
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

echo "=== 7. populate the ESP with the illumos loader ==="
yes | mkfs -F pcfs -o fat=32,b=bootfs $FAT_RAW || true
mkdir -p $MNT
mount -F pcfs $FAT_BLK $MNT
mkdir -p $MNT/EFI/BOOT
cp $PROTO/boot/loader64.efi $MNT/EFI/BOOT/bootaa64.efi
umount $MNT
lofiadm -d $DISK

echo "=== DONE: $DISK ==="
ls -la $DISK
echo "IMAGE-OK"
