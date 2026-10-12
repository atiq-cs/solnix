#!/bin/bash
# aa-assemble-metal.sh — A6/A8 hybrid: banked COMPLETE proto + fresh drain-fixed
# kernel + pkg-style driver tables + injected libxml2/libgcc_s + OpenSSH + SMF
# site profile -> bootable GPT metal disk (ESP loader64.efi + ZFS armpool).
# Target: real c6g.metal (Nitro UEFI boots loader64.efi directly, no u-boot).
exec >>/var/log/aa-assemble.log 2>&1
set -x
echo "=== ASSEMBLE METAL START $(date) ==="

BANKED=/build/proto/root_aarch64
FRESH=/aarch64/arm64-gate/illumos-gate/proto/root_aarch64
TABLES=/build/drivertables
EXT=/build/braich-files
HARNESS=/aarch64/arm64-gate
OUT=/build/out
DISK=$OUT/illumos-metal.img
DISKSIZE=10g
POOL=armpool
MNT=/armmnt
ROOTFS=ROOT/braich
IMGDS=rpool/braich_image
IMGROOT=/braich_image
BE_UUID=$(/usr/bin/uuidgen)

[ "$(zonename)" = global ] || { echo "FATAL: not global zone"; exit 2; }
mkdir -p $OUT

echo "=== 1. stage root FS from banked COMPLETE proto ==="
zfs list $IMGDS >/dev/null 2>&1 && zfs destroy -r $IMGDS
zfs create -o mountpoint=$IMGROOT $IMGDS
/usr/gnu/bin/cp -a $BANKED/. $IMGROOT/
echo "staged $(find $IMGROOT -type f 2>/dev/null | wc -l) files"

echo "=== 2. SWAP IN fresh drain-fixed kernel (unix+genunix+kmods) ==="
# unix (marker-free console = drain-fixed)
cp $FRESH/platform/armv8/kernel/aarch64/unix $IMGROOT/platform/armv8/kernel/aarch64/unix
# genunix + the whole fresh kernel/aarch64 kmod set (built against the same unix)
/usr/gnu/bin/cp -a $FRESH/kernel/aarch64/. $IMGROOT/kernel/aarch64/
# fresh platform kmods (rootnex/ecam/gic/arm_gtmr etc under platform/armv8/kernel)
/usr/gnu/bin/cp -a $FRESH/platform/armv8/kernel/. $IMGROOT/platform/armv8/kernel/
# fresh loader (efipart chunked-read)
cp $FRESH/boot/loader64.efi $IMGROOT/boot/loader64.efi
ls -la $IMGROOT/platform/armv8/kernel/aarch64/unix
echo "unix swapped: $(cksum $IMGROOT/platform/armv8/kernel/aarch64/unix)"

echo "=== 3. driver tables (pkg-style) ==="
cp $TABLES/name_to_major $IMGROOT/etc/name_to_major
cp $TABLES/driver_aliases $IMGROOT/etc/driver_aliases
echo "name_to_major=$(wc -l < $IMGROOT/etc/name_to_major) driver_aliases=$(wc -l < $IMGROOT/etc/driver_aliases)"

echo "=== 4. inject external libs (libxml2 = svccfg root cause; libgcc_s) ==="
cp $EXT/libxml2.so.16.1.4 $IMGROOT/lib/libxml2.so.16.1.4
( cd $IMGROOT/lib && ln -sf libxml2.so.16.1.4 libxml2.so.16 && ln -sf libxml2.so.16.1.4 libxml2.so )
cp $EXT/libgcc_s.so.1 $IMGROOT/lib/libgcc_s.so.1
# usr/lib compat
ln -sf ../../lib/libxml2.so.16.1.4 $IMGROOT/usr/lib/libxml2.so.16 2>/dev/null || true
ls -la $IMGROOT/lib/libxml2* $IMGROOT/lib/libgcc_s.so.1

echo "=== 5. OpenSSH (bonus; needs libcrypto which we did NOT inject -> may stay maint) ==="
cp $EXT/sshd $IMGROOT/usr/sbin/sshd 2>/dev/null || true
cp $EXT/ssh $IMGROOT/usr/bin/ssh 2>/dev/null || true
cp $EXT/ssh-keygen $IMGROOT/usr/bin/ssh-keygen 2>/dev/null || true
mkdir -p $IMGROOT/usr/libexec
cp $EXT/sshd-session $IMGROOT/usr/libexec/sshd-session 2>/dev/null || true
cp $EXT/sshd-auth $IMGROOT/usr/libexec/sshd-auth 2>/dev/null || true
cp $EXT/sftp-server $IMGROOT/usr/libexec/sftp-server 2>/dev/null || true
cp $EXT/ssh-keysign $IMGROOT/usr/libexec/ssh-keysign 2>/dev/null || true
chmod 0755 $IMGROOT/usr/sbin/sshd $IMGROOT/usr/bin/ssh $IMGROOT/usr/bin/ssh-keygen 2>/dev/null || true
mkdir -p $IMGROOT/var/empty  # OpenSSH privsep dir
[ -f $EXT/sshd_config ] && cp $EXT/sshd_config $IMGROOT/etc/ssh/sshd_config 2>/dev/null || true

echo "=== 6. nodename/hosts/no-password + reconfigure + boot config ==="
echo "solnix-aa" > $IMGROOT/etc/nodename
[ -f $IMGROOT/etc/default/login ] && sed -i 's/^PASSREQ=YES/PASSREQ=NO/' $IMGROOT/etc/default/login
[ -f $IMGROOT/etc/ssh/sshd_config ] && sed -i '/PermitRootLogin/s/no/yes/' $IMGROOT/etc/ssh/sshd_config
touch $IMGROOT/reconfigure
mkdir -p $IMGROOT/tmp $IMGROOT/proc $IMGROOT/system/contract $IMGROOT/system/object \
         $IMGROOT/etc/svc/volatile $IMGROOT/var/run 2>/dev/null || true
# writable dirs (proto ships 0555; x86 gotcha #7)
find $IMGROOT -type d ! -perm -u+w -exec chmod u+w {} + 2>/dev/null || true

# metal boot config: serial console, verbose, impl-arch bootfile
mkdir -p $IMGROOT/boot/conf.d
cat > $IMGROOT/boot/conf.d/00-aarch64-defaults.conf <<'BCFG'
bootfile="/platform/${IMPLARCH}/kernel/${ISADIR}/unix;/platform/${BASEARCH}/kernel/${ISADIR}/unix"
console="${default-uart-name},text"
boot-args="-vm verbose"
BCFG

echo "=== 7. SMF: minimal /dev + repository seed + site profile ==="
[ -f $HARNESS/arm64-gate/tools/dev.tar ] && tar -xf $HARNESS/arm64-gate/tools/dev.tar -C $IMGROOT 2>/dev/null
# SMF profiles symlinks (like build_image.sh)
if [ -d $IMGROOT/etc/svc/profile ]; then
  ( cd $IMGROOT/etc/svc/profile
    [ -f ns_files.xml ] && ln -sf ns_files.xml name_service.xml
    [ -f generic_limited_net.xml ] && ln -sf generic_limited_net.xml generic.xml
    [ -f inetd_generic.xml ] && ln -sf inetd_generic.xml inetd_services.xml
    [ -f platform_none.xml ] && ln -sf platform_none.xml platform.xml ) 2>/dev/null || true
fi
# seed the SMF repository DB from the proto seed (full svccfg import at first boot
# via manifest-import -- svccfg now works because libxml2 is injected)
if [ -f $IMGROOT/lib/svc/seed/global.db ]; then
  cp $IMGROOT/lib/svc/seed/global.db $IMGROOT/etc/svc/repository.db
  chown root:sys $IMGROOT/etc/svc/repository.db 2>/dev/null || true
  chmod 0600 $IMGROOT/etc/svc/repository.db
fi
# site profile: disable maintenance-prone peripherals (A5 recipe) so milestones reach
mkdir -p $IMGROOT/etc/svc/profile/site
cat > $IMGROOT/etc/svc/profile/site/solnix-aa.xml <<'SITE'
<?xml version="1.0"?>
<!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
<service_bundle type="profile" name="solnix-aa">
  <service name="network/rpc/bind" version="1" type="service">
    <instance name="default" enabled="false"/></service>
  <service name="network/inetd-upgrade" version="1" type="service">
    <instance name="default" enabled="false"/></service>
  <service name="system/rbac" version="1" type="service">
    <instance name="default" enabled="false"/></service>
  <service name="system/update-man-index" version="1" type="service">
    <instance name="default" enabled="false"/></service>
  <service name="system/dumpadm" version="1" type="service">
    <instance name="default" enabled="false"/></service>
  <service name="system/intrd" version="1" type="service">
    <instance name="default" enabled="false"/></service>
  <service name="network/sendmail-client" version="1" type="service">
    <instance name="default" enabled="false"/></service>
  <service name="system/fm/smtp-notify" version="1" type="service">
    <instance name="default" enabled="false"/></service>
  <service name="system/hal" version="1" type="service">
    <instance name="default" enabled="false"/></service>
</service_bundle>
SITE

# swap/dump vfstab
echo "/dev/zvol/dsk/$POOL/swap - - swap - no -" >> $IMGROOT/etc/vfstab

echo "=== 8. boot_archive (create_ramdisk) ==="
mkdir -p $IMGROOT/platform/armv8/aarch64
if [ -x $IMGROOT/boot/solaris/bin/create_ramdisk ]; then
  ksh $IMGROOT/boot/solaris/bin/create_ramdisk -R $IMGROOT -p aarch64 -f cpio 2>&1 | tail -15
  echo "boot_archive: $(ls -la $IMGROOT/platform/armv8/aarch64/boot_archive 2>&1)"
else
  echo "WARN: no create_ramdisk"
fi

echo "=== 9. snapshot + zfs send ==="
zfs snapshot $IMGDS@image
zfs send $IMGDS@image > $OUT/illumos.zfs
echo "illumos.zfs: $(ls -la $OUT/illumos.zfs | awk '{print $5}') bytes"

echo "=== 10. GPT metal disk: ESP(pcfs) + ZFS armpool ==="
rm -f $DISK
mkfile $DISKSIZE $DISK
BLK_DEVICE=$(lofiadm -la $DISK)
FAT_RAW=$(echo $BLK_DEVICE | sed 's,/dsk/,/rdsk/,; s/p0/s0/')
FAT_BLK=$(echo $BLK_DEVICE | sed 's/p0/s0/')
echo "lofi=$BLK_DEVICE fatraw=$FAT_RAW fatblk=$FAT_BLK"
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

echo "=== 11. populate ESP with loader ==="
yes | mkfs -F pcfs -o fat=32,b=bootfs $FAT_RAW || true
mkdir -p $MNT
mount -F pcfs $FAT_BLK $MNT
mkdir -p $MNT/EFI/BOOT
cp $FRESH/boot/loader64.efi $MNT/EFI/BOOT/bootaa64.efi
ls -la $MNT/EFI/BOOT/
umount $MNT
lofiadm -d $DISK

echo "=== DONE: $DISK $(ls -la $DISK | awk '{print $5}') bytes $(date) ==="
echo "ASSEMBLE-OK"
