#!/bin/bash
# aa-assemble-metal.sh — A6/A8 hybrid: banked COMPLETE proto + fresh drain-fixed
# kernel + pkg-style driver tables + injected libxml2/libgcc_s + OpenSSH + SMF
# site profile -> bootable GPT metal disk (ESP loader64.efi + ZFS armpool).
# Target: real c6g.metal (Nitro UEFI boots loader64.efi directly, no u-boot).
exec >/build/assemble-trace.log 2>&1
set -x
echo "=== ASSEMBLE METAL START $(date) ==="

BANKED=/build/proto/root_aarch64
FRESH=/aarch64/arm64-gate/illumos-gate/proto/root_aarch64
TABLES=/build/patches
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
# the WHOLE fresh kernel/ tree (genunix, drv/ incl. ecam, misc/ incl. pcierc, fs/, ...).
# The old recipe copied only kernel/aarch64 -> every driver stayed the banked (stale) build.
/usr/gnu/bin/cp -a $FRESH/kernel/. $IMGROOT/kernel/
# fresh platform kmods: the whole platform/ tree (armv8 + QEMU,virt + RaspberryPi,4)
/usr/gnu/bin/cp -a $FRESH/platform/. $IMGROOT/platform/
# fresh loader (efipart chunked-read)
cp $BANKED/boot/loader64.efi $IMGROOT/boot/loader64.efi
ls -la $IMGROOT/platform/armv8/kernel/aarch64/unix
echo "unix swapped: $(cksum $IMGROOT/platform/armv8/kernel/aarch64/unix)"
# GATE: every fresh kernel module must be byte-identical in the image (no stale driver ships)
( cd $FRESH && find kernel platform -type f ) | while read m; do
  cmp -s "$FRESH/$m" "$IMGROOT/$m" || echo "STALE_OR_MISSING $m"
done > /build/stale-kmods.txt
echo "stale kmods: $(wc -l < /build/stale-kmods.txt)"
[ -s /build/stale-kmods.txt ] && { head /build/stale-kmods.txt; echo "FATAL: stale kernel modules"; exit 4; }
strings $IMGROOT/kernel/drv/aarch64/ecam | grep -c AAECAM

echo "=== 3. driver tables (pkg-style) ==="
cp $TABLES/aa-name_to_major-pkgstyle.txt $IMGROOT/etc/name_to_major
cp $TABLES/aa-driver_aliases-nopl011.txt $IMGROOT/etc/driver_aliases
echo "name_to_major=$(wc -l < $IMGROOT/etc/name_to_major) driver_aliases=$(wc -l < $IMGROOT/etc/driver_aliases)"

echo "=== 4+5. EC2 login overlay (braich OpenSSH/libs/curl, DHCP ena0, IMDS key) ==="
bash /build/patches/aa64-overlay.sh $IMGROOT

echo "=== 6. nodename/hosts/no-password + reconfigure + boot config ==="
echo "solnix-aa64" > $IMGROOT/etc/nodename
sed -i "/^TZ/c\\
TZ=UTC
" $IMGROOT/etc/default/init
[ -f $IMGROOT/etc/default/login ] && sed -i 's/^PASSREQ=YES/PASSREQ=NO/' $IMGROOT/etc/default/login
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
tar -xf $HARNESS/tools/dev.tar -C $IMGROOT; echo DEVTAR=$?
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
SVCCFG=/aarch64/arm64-gate/illumos-gate/usr/src/tools/proto/root_i386-nd/opt/onbld/bin/i386/svccfg
SVCCFG_CONFIGD_PATH=/aarch64/arm64-gate/illumos-gate/usr/src/tools/proto/root_i386-nd/opt/onbld/bin/i386/svc.configd
export SVCCFG_CONFIGD_PATH
REPO=/build/aa64-repo.$$
cp $IMGROOT/lib/svc/seed/global.db $REPO; chmod u+w $REPO
env PKG_INSTALL_ROOT=$IMGROOT SVCCFG_DTD=$IMGROOT/usr/share/lib/xml/dtd/service_bundle.dtd.1 \
    SVCCFG_REPOSITORY=$REPO SVCCFG_CHECKHASH=1 SVCCFG_CONFIGD_PATH=$SVCCFG_CONFIGD_PATH \
    $SVCCFG import -p /dev/stdout $IMGROOT/lib/svc/manifest > /build/svccfg-import.log 2>&1
echo SVCCFG_IMPORT_RC=$?; tail -3 /build/svccfg-import.log
cp $REPO $IMGROOT/etc/svc/repository.db; rm -f $REPO
chown root:sys $IMGROOT/etc/svc/repository.db; chmod 0600 $IMGROOT/etc/svc/repository.db
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
cp $BANKED/boot/loader64.efi $MNT/EFI/BOOT/bootaa64.efi
ls -la $MNT/EFI/BOOT/
umount $MNT
lofiadm -d $DISK

echo "=== DONE: $DISK $(ls -la $DISK | awk '{print $5}') bytes $(date) ==="
echo "ASSEMBLE-OK"
