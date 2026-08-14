#!/usr/bin/env bash
# fix-metal-boot.sh -- repair the illumos BIOS/CSM boot chain on an already-built
# solnix disk so it boots on EC2 bare-metal (Legacy-BIOS-only) instances.
#
# WHY: solnix v3 disks have a correct UEFI path (GPT ESP -> EFI/Boot/bootx64.efi)
# and Nitro VMs UEFI-boot fine. But EC2 bare-metal is Legacy-BIOS ONLY (AWS:
# "All Nitro instances support UEFI and Legacy BIOS EXCEPT bare metal
# instances"). Metal's SeaBIOS/CSM runs the MBR/PMBR stage1 -> gptzfsboot
# (stage2) -> loader chain, ignoring the ESP. The v3 build installed stage2 on
# the pcfs ESP slice (s0) instead of the ZFS pool slice (s1), so the PMBR
# stage1 pointed at LBA 256 with no gptzfsboot there -> metal hangs at POST.
#
# THE FIX (one installboot, to the ZFS pool slice): put gptzfsboot in the ZFS
# pool boot area and rewrite the PMBR stage1 with a correct stage2 pointer.
# Non-destructive to pool DATA -- it only writes the vdev boot reserve + PMBR.
#
#   fix-metal-boot.sh <disk>            # e.g. c1t1d0  (running-node's own root)
#   fix-metal-boot.sh <disk> <pool-slice>   # override slice (default: the tag-4
#                                             or non-ESP slice holding the pool)
#
# Run on a booted solnix system against the TARGET disk (its own root disk works
# because the running node UEFI-boots; rewriting the BIOS chain does not change
# the current UEFI boot). Then snapshot the disk and register a LEGACY-BIOS AMI.
set -u
PATH=/usr/sbin:/usr/bin:/sbin; export PATH

DISK="${1:?usage: fix-metal-boot.sh <disk cNtNdN> [pool-slice cNtNdNsN]}"
POOL_SLICE="${2:-}"

BOOTDIR="${BOOTDIR:-/boot}"
PMBR="$BOOTDIR/pmbr"
GPTZFSBOOT="$BOOTDIR/gptzfsboot"
[ -f "$PMBR" ]       || { echo "FATAL: $PMBR not found" >&2; exit 1; }
[ -f "$GPTZFSBOOT" ] || { echo "FATAL: $GPTZFSBOOT not found" >&2; exit 1; }

# Find the ZFS pool slice: the illumos/Solaris ZFS partition is prtvtoc tag 4
# (V_USR) -- NOT tag 12 (the pcfs ESP) and NOT tag 11 (reserved). Default to s1
# which is where solnix-install lays the pool.
if [ -z "$POOL_SLICE" ]; then
  s=$(prtvtoc "/dev/rdsk/${DISK}s0" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && $2==4 {print $1; exit}')
  [ -n "$s" ] || s=1
  POOL_SLICE="${DISK}s${s}"
fi

echo "=== disk=$DISK  pool-slice=$POOL_SLICE ==="
echo "--- BEFORE: PMBR stage1 -> stage2 pointer ---"
installboot -i "/dev/rdsk/${DISK}p0" 2>&1 | grep -iE "STAGE1_STAGE2|Signature|Format" || true

echo "--- installing pmbr(stage1) + gptzfsboot(stage2) on ZFS pool slice $POOL_SLICE ---"
installboot -fm "$PMBR" "$GPTZFSBOOT" "/dev/rdsk/${POOL_SLICE}" || {
  echo "FATAL: installboot failed on $POOL_SLICE" >&2; exit 1; }

echo "--- AFTER: pool-slice VBR (should be Format: loader (illumos), valid sig, stage2 LBA in the pool) ---"
installboot -i "/dev/rdsk/${POOL_SLICE}" 2>&1 | grep -iE "STAGE1_STAGE2|Signature|Format" || true

# Verify gptzfsboot actually landed in the pool boot area: its head is
# 31 c9 8e c1 8e d9 ...  The pool-slice VBR reports the ABSOLUTE stage2 LBA;
# convert to a slice-relative sector (large skips on the whole-disk p0 minor
# read short on some illumos builds, so read via the slice device) and compare.
vbr=$(installboot -i "/dev/rdsk/${POOL_SLICE}" 2>&1)
lba=$(printf '%s\n' "$vbr" | awk '/STAGE1_STAGE2_LBA/{v=$NF} END{print v}')      # last = the 525568 stage2 LBA
slice_start=$(prtvtoc "/dev/rdsk/${POOL_SLICE}" 2>/dev/null | awk -v s="${POOL_SLICE##*s}" '$1==s && $2 ~ /^[0-9]+$/ {print $4; exit}')
if [ -n "$lba" ] && [ -n "$slice_start" ]; then
  rel=$(( lba - slice_start ))
  got=$(dd if="/dev/rdsk/${POOL_SLICE}" bs=512 skip="$rel" count=1 2>/dev/null | od -A n -t x1 | head -1 | tr -s ' ' | sed 's/^ //' | cut -d' ' -f1-6)
  want="31 c9 8e c1 8e d9"
  echo "--- stage2 head @abs LBA $lba (slice-rel $rel): [$got]  expect: [$want] ---"
  case "$got" in
    "$want"*) echo "OK: gptzfsboot (stage2) is in the pool boot area; BIOS/CSM chain is complete." ;;
    *)        echo "WARN: stage2 head mismatch -- inspect manually." ;;
  esac
fi

echo "=== DONE. Snapshot $DISK's volume and register a Legacy-BIOS AMI:"
echo "  aws ec2 register-image --boot-mode legacy-bios --ena-support ... "
echo "  Launch on a *.metal instance (Legacy-BIOS only). The UEFI ESP path is"
echo "  untouched, so Nitro VMs still UEFI-boot the same disk."
