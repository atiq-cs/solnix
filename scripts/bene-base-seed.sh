#!/bin/bash
# bene-base-seed.sh — runs ON the Ubuntu 24.04 OpenZFS helper (as root, detached).
#
# Turns a raw OpenIndiana cloud-image volume into the solnix x86_64 base:
#   * grow the ZFS partition + pool to the whole disk (OFFLINE, before import)
#   * single import at an altroot, mount the boot environment
#   * metadata shim (IMDSv2-proof, single DHCP addrobj) over /usr/lib/metadata
#   * strip the dual-addrobj (ena0/v4) + stale DHCP lease state
#   * ena driver with the MTU-1500 default (+ aliases/major if the image lacks it)
#   * set pit_is_broken=1 so the unreliable Nitro emulated i8254 PIT can never
#     wedge tsc_calibrate_pit() pre-userland
#   * root ssh key + PermitRootLogin
#   * rebuild the boot_archive OFFLINE as raw gzip'd odc cpio so the kernel sees
#     /etc/system + the fixed ena from the RAMDISK (it reads them long before the
#     ZFS root is mounted); on-disk copies updated too so a first-boot bootadm
#     rebuild reproduces the same content
#   * stage the prebuilt native illumos Nix bootstrap tarball in /root
#   * clean export (never reguid, never a second import)
set -uxo pipefail
exec >/tmp/seed.log 2>&1
POOL=rpool
NIX_BOOTSTRAP_URL="https://s3.solnix.io/solnix-cache/bootstrap/nix-illumos-2.3.16.tar.zst"

export DEBIAN_FRONTEND=noninteractive
until apt-get update -y; do sleep 5; done
apt-get install -y zfsutils-linux gdisk cloud-guest-utils cpio zstd
modprobe zfs

ROOT=$(findmnt -no SOURCE / | sed 's/p\?[0-9]*$//')
DATA=""
for d in /dev/nvme*n1; do [ "$d" = "$ROOT" ] && continue; DATA=$d; done
echo "ROOT=$ROOT DATA=$DATA"
[ -n "$DATA" ] || { echo SEED_FAILED_NODISK; exit 1; }
lsblk
sgdisk -p "$DATA" || true

# ---- 1. grow the ZFS partition to fill the disk (pool NOT yet imported) ------
# The raw image is authored at ~1.95GiB, so the pool sits in a 1.7GiB partition on
# a much larger EBS volume. growpart cannot help: the illumos layout puts the 8MiB
# Solaris reserved partition (type BF07, number 9) IMMEDIATELY after the ZFS
# partition, leaving it no adjacent free space. So the table is rewritten wholesale
# with the ZFS partition extended to the disk tail and the reserved partition moved
# behind it, preserving every partition's start (for p1/p2), type code, UUID and
# name. The ZFS data is untouched -- only GPT entries change -- and the pool is
# expanded after import with `zpool online -e`, which grows a vdev to its device
# size regardless of autoexpand. All of this runs with the pool NOT imported, so no
# partition table is ever rewritten under a live pool.
#
# sfdisk, not sgdisk: the OI image's GPT holds only 9 entries and its partition
# table is smaller than the GPT spec minimum, which makes sgdisk refuse EVERY
# create ("Could not create partition N", changes not saved) while still happily
# performing deletes -- i.e. sgdisk can only destroy this table. sfdisk applies a
# full declarative table in one atomic write and accepts the short table as-is.
ZLINE=$(sfdisk -d "$DATA" | grep -i 'type=6A898CC3' | head -1)   # Solaris /usr & ZFS
RLINE=$(sfdisk -d "$DATA" | grep -i 'type=6A945A3B' | head -1)   # Solaris reserved
ZEND=$(echo "$ZLINE" | sed -n 's/.*start= *\([0-9]*\), *size= *\([0-9]*\).*/\1 \2/p' | awk '{print $1+$2}')
LASTLBA=$(sfdisk -d "$DATA" | sed -n 's/^last-lba: *//p')
echo "zfs partition ends at $ZEND; last usable lba $LASTLBA"
if [ -n "$ZLINE" ] && [ -n "$LASTLBA" ] && [ "$ZEND" -lt $((LASTLBA - 65536)) ]; then
  RESV_SECT=32768                                   # keep the 16MiB Solaris reserved slice
  ZSTART=$(echo "$ZLINE" | sed -n 's/.*start= *\([0-9]*\).*/\1/p')
  RSTART=$((LASTLBA - RESV_SECT))
  ZSIZE=$((RSTART - ZSTART))
  {
    sfdisk -d "$DATA" | grep -viE 'type=6A898CC3|type=6A945A3B'
    echo "$ZLINE" | sed "s/size= *[0-9]*/size= $ZSIZE/"
    [ -n "$RLINE" ] && echo "$RLINE" | sed "s/start= *[0-9]*/start= $RSTART/"
  } > /tmp/tbl.sfdisk
  cat /tmp/tbl.sfdisk
  sfdisk --no-reread --force "$DATA" < /tmp/tbl.sfdisk 2>&1 | tail -12
  partprobe "$DATA" 2>/dev/null || true
  sleep 3
else
  echo "zfs partition already fills the disk (or layout unrecognized) -- no repartition"
fi
sgdisk -p "$DATA" || true
lsblk "$DATA"

# ---- 2. single import at an altroot -----------------------------------------
zpool import 2>&1 || true
if ! zpool import -f -N -R /mnt "$POOL"; then
  echo "ZPOOL_IMPORT_FAILED for $POOL"; zpool import -d /dev 2>&1 || true
  echo SEED_FAILED_ZFS; exit 1
fi
zpool status "$POOL" | head -30
ZDEV=$(zpool status "$POOL" | awk 'NR>1 && /ONLINE/ && !/state:/ {print $1}' | grep -v "^$POOL$" | head -1)
echo "vdev=$ZDEV — expanding to device size"
zpool online -e "$POOL" "$ZDEV" 2>&1 || echo "online -e failed (non-fatal)"
zpool list "$POOL"

BE=$(zfs list -H -o name -r "$POOL/ROOT" 2>/dev/null | grep -E "/ROOT/." | head -1)
echo "BE=$BE"
[ -n "$BE" ] || { echo NO_BE_FOUND; zfs list; echo SEED_FAILED_NOBE; exit 1; }
zfs set mountpoint=legacy "$BE" || true
mkdir -p /mnt/be
mount -t zfs "$BE" /mnt/be || { echo MOUNT_FAILED; echo SEED_FAILED_MOUNT; exit 1; }
R=/mnt/be
ls "$R"

echo "=== pre-fix state ==="
ls -la "$R/usr/lib/metadata" 2>&1 | head -2
ls -la "$R/kernel/drv/amd64/ena" 2>&1 | head -2
grep -w '^ena' "$R/etc/name_to_major" 2>&1 || echo "(no ena in name_to_major)"
grep -c ena "$R/etc/driver_aliases" 2>&1 || true
cat "$R/etc/ipadm/ipadm.conf" 2>&1 | head -10
ls -la "$R/platform/i86pc/amd64/" 2>&1 | head -10
cat "$R/etc/system" 2>&1 | tail -5
ls "$R/etc/system.d/" 2>&1 || echo "(no /etc/system.d)"

echo "=== APPLYING FIXES (root filesystem) ==="
# metadata shim: the stock OI metadata-agent is an IMDSv1 client and hangs to its
# 300s timeout under enforced IMDSv2, gating svc:/milestone/network.
install -m 0755 /tmp/metadata-shim.sh "$R/usr/lib/metadata" && echo SHIM_INSTALLED

# One DHCP address object only. A baked ena0/v4 alongside ena0/dhcp makes both
# claim the same lease; the second fails configure_v4_lease ("Cannot assign
# requested address") and the interface comes up with no lease.
if [ -f "$R/etc/ipadm/ipadm.conf" ]; then
  grep -v '_aobjname=ena0/v4' "$R/etc/ipadm/ipadm.conf" > /tmp/ipadm.new \
    && cp /tmp/ipadm.new "$R/etc/ipadm/ipadm.conf" && echo IPADM_SCRUBBED
fi
find "$R/etc/dhcp" -maxdepth 1 -name '*.dhc' -delete 2>/dev/null || true
find "$R/etc/dhcp" -maxdepth 1 \( -name duid -o -name iaid \) -delete 2>/dev/null || true
find "$R/var/lib" -maxdepth 1 -name 'solnix-dhcp-*' -delete 2>/dev/null || true

# ena with the MTU-1500 default: on Nitro a queue programmed with jumbo-sized Rx
# buffers does not reliably deliver the small broadcast DHCP OFFER on cold boot.
install -m 0755 -o 0 -g 3 /tmp/ena "$R/kernel/drv/amd64/ena" && echo ENA_INSTALLED
install -m 0644 -o 0 -g 3 /tmp/ena.conf "$R/kernel/drv/ena.conf"
for a in 'pciex1d0f,ec2' 'pciex1d0f,1ec2' 'pciex1d0f,ec20' 'pciex1d0f,ec21'; do
  grep -q "^ena \"$a\"" "$R/etc/driver_aliases" || echo "ena \"$a\"" >> "$R/etc/driver_aliases"
done
if ! grep -qw '^ena' "$R/etc/name_to_major"; then
  MAJ=$(awk '{print $2}' "$R/etc/name_to_major" | sort -n | tail -1); MAJ=$((MAJ+1))
  echo "ena $MAJ" >> "$R/etc/name_to_major"; echo "ena major $MAJ (added)"
fi

# PIT tunable, in BOTH /etc/system.d (the modular location) and /etc/system (read
# unconditionally by mod_read_system_file inside kmem_init, which runs before
# startup_tsc, so the tunable is in effect in time to gate the PIT path).
mkdir -p "$R/etc/system.d"
install -m 0644 /tmp/solnix-nitro-pit.system.d "$R/etc/system.d/solnix-nitro-pit"
if ! grep -q 'pit_is_broken' "$R/etc/system"; then
  cat >> "$R/etc/system" <<'SYS'
* The AWS Nitro emulated i8254 PIT is unreliable on cold boot; the legacy PIT
* calibration (tsc_pit_also -> tsc_calibrate_pit -> freq_tsc_pit) intermittently
* wedges startup_tsc() before device probe. The TSC frequency comes from the
* hypervisor CPUID leaf and the APIC calibrates off the TSC, so the PIT path is
* pure legacy diagnostics.
set pit_is_broken = 1
SYS
  echo SYSTEM_PIT_ADDED
fi
tail -8 "$R/etc/system"

# root ssh (the shim enables sshd once the NIC is up)
mkdir -p "$R/root/.ssh"; chmod 700 "$R/root/.ssh"
cp /tmp/mypub "$R/root/.ssh/authorized_keys"; chmod 600 "$R/root/.ssh/authorized_keys"
if [ -f "$R/etc/ssh/sshd_config" ]; then
  sed -i 's/^#*PermitRootLogin .*/PermitRootLogin yes/' "$R/etc/ssh/sshd_config"
  grep -q '^PermitRootLogin yes' "$R/etc/ssh/sshd_config" || echo 'PermitRootLogin yes' >> "$R/etc/ssh/sshd_config"
  echo SSHD_CONFIGURED
fi

# The loader verifies boot_archive.hash unless told not to; an offline repack
# changes the archive, so disable the check rather than reimplement bootadm's digest.
LC="$R/boot/loader.conf"
if [ -f "$LC" ]; then
  grep -q 'boot_archive.hash_load' "$LC" \
    && sed -i 's/^boot_archive.hash_load=.*/boot_archive.hash_load="NO"/' "$LC" \
    || echo 'boot_archive.hash_load="NO"' >> "$LC"
  grep -q 'boot_archive_hash_load' "$LC" || echo 'boot_archive_hash_load="NO"' >> "$LC"
  cat "$LC"
fi

# ---- 3. offline boot_archive repack ----------------------------------------
BA="$R/platform/i86pc/amd64/boot_archive"
if [ ! -f "$BA" ]; then
  echo "NO_BOOT_ARCHIVE at $BA"; ls -la "$R/platform/i86pc/amd64" 2>&1; echo SEED_FAILED_NOBA; exit 1
fi
WD=/tmp/ba.work; mkdir -p "$WD/root"
gunzip -c "$BA" > "$WD/ba.cpio" 2>/dev/null || cp "$BA" "$WD/ba.cpio"
file "$WD/ba.cpio"
if ! file "$WD/ba.cpio" | grep -qi cpio; then
  echo "BOOT_ARCHIVE_NOT_CPIO: $(file "$WD/ba.cpio")"; echo SEED_FAILED_BAFORMAT; exit 1
fi
( cd "$WD" && cpio -it --quiet < ba.cpio > order.txt )
wc -l "$WD/order.txt"
( cd "$WD/root" && cpio -idm --quiet < "$WD/ba.cpio" )
ls "$WD/root"

# Overwrite the archive's copies with the fixed root copies; append any entry the
# archive did not already carry, preserving the original order otherwise.
add_entry() { grep -qx "$1" "$WD/order.txt" || echo "$1" >> "$WD/order.txt"; }
for f in kernel/drv/amd64/ena kernel/drv/ena.conf etc/driver_aliases etc/name_to_major \
         etc/system etc/system.d/solnix-nitro-pit etc/ipadm/ipadm.conf; do
  if [ -f "$R/$f" ]; then
    mkdir -p "$WD/root/$(dirname "$f")"
    cp -p "$R/$f" "$WD/root/$f"
    add_entry "$f"
    echo "archive <- $f"
  fi
done
add_entry etc/system.d
grep -c . "$WD/order.txt"
( cd "$WD/root" && cpio -o -H odc --quiet < "$WD/order.txt" > "$WD/ba.new.cpio" )
ls -l "$WD/ba.cpio" "$WD/ba.new.cpio"
cp -p "$BA" /tmp/boot_archive.stock.gz
gzip -c -9 "$WD/ba.new.cpio" > "$BA"
ls -l "$BA"
# sanity: the repacked archive must still list the fixed entries
gunzip -c "$BA" | cpio -it --quiet | grep -E '^(kernel/drv/amd64/ena|etc/system|etc/system.d/solnix-nitro-pit)$' || echo "WARN: repack verify grep found nothing"
gunzip -c "$BA" > /tmp/verify.cpio
mkdir -p /tmp/verify && ( cd /tmp/verify && cpio -idm --quiet < /tmp/verify.cpio )
cmp /tmp/verify/kernel/drv/amd64/ena /tmp/ena && echo VERIFY_ENA_IN_ARCHIVE || echo VERIFY_ENA_MISMATCH
grep -q pit_is_broken /tmp/verify/etc/system && echo VERIFY_PIT_IN_ARCHIVE || echo VERIFY_PIT_MISSING

# Keep bootadm's per-file cache consistent so a first-boot rebuild cannot
# reintroduce the stock module.
for f in kernel/drv/amd64/ena etc/system; do
  C="$R/platform/i86pc/amd64/archive_cache/$f"
  if [ -f "$C" ]; then gzip -1 -c "$R/$f" > "$C"; echo "archive_cache <- $f"; fi
done

# ---- 4. stage the native illumos Nix bootstrap (no compiler needed on target) -
curl -fsSL "$NIX_BOOTSTRAP_URL" -o "$R/root/nix-illumos-2.3.16.tar.zst" \
  && curl -fsSL "$NIX_BOOTSTRAP_URL.sha256" -o "$R/root/nix-illumos-2.3.16.tar.zst.sha256" \
  && ( cd "$R/root" && sha256sum -c nix-illumos-2.3.16.tar.zst.sha256 ) \
  && echo NIX_BOOTSTRAP_STAGED || echo "NIX_BOOTSTRAP_STAGE_FAILED (non-fatal)"

sync
echo "=== post-fix verify ==="
grep -q 'solnix shim' "$R/usr/lib/metadata" && echo VERIFY_SHIM_OK || echo VERIFY_SHIM_BAD
grep -q '_aobjname=ena0/v4' "$R/etc/ipadm/ipadm.conf" 2>/dev/null && echo VERIFY_DUAL_REMAINS || echo VERIFY_NO_DUAL
grep -q pit_is_broken "$R/etc/system" && echo VERIFY_PIT_ON_ROOT || echo VERIFY_PIT_MISSING_ROOT
ls -l "$R/kernel/drv/amd64/ena" "$R/root/.ssh/authorized_keys"
df -h /mnt/be
zfs list -o name,used,avail "$POOL"

umount /mnt/be || true
zpool export "$POOL" || { sleep 5; zpool export -f "$POOL"; }
echo SEED_DONE
