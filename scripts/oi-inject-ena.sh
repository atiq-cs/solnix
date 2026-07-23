#!/usr/bin/env bash
# oi-inject-ena.sh — run ON the Ubuntu ZFS helper. Adds the illumos `ena` driver
# to a mounted OpenIndiana boot environment so the image networks on AWS Nitro
# (the stock OI cloud image ships no ena driver -> no NIC on Nitro, only Xen).
#
# Needs, alongside this script on the helper: ena, ena.conf (the driver files
# pulled from a host where `pkg install driver/network/ena` ran).
#
# Injects: the module + conf, the /etc/driver_aliases entries, the
# /etc/name_to_major entry, and rebuilds the boot_archive so the driver is
# available at boot. Idempotent.
set -euo pipefail
POOL="${POOL:-rpool}"
BE_DS="${BE_DS:-}"    # e.g. rpool/ROOT/7f4803ff; auto-detected if empty
MNT=/mnt/be

zpool import -f -N -R /mnt "$POOL" 2>/dev/null || true
[ -n "$BE_DS" ] || BE_DS=$(zfs list -H -o name -r "$POOL/ROOT" | grep -E "/ROOT/." | head -1)
echo "BE dataset: $BE_DS"
zfs set mountpoint=legacy "$BE_DS" 2>/dev/null || true
mkdir -p "$MNT"; mountpoint -q "$MNT" || mount -t zfs "$BE_DS" "$MNT"

echo "=== inject ena module + conf ==="
install -m 0755 -o 0 -g 3 ena     "$MNT/kernel/drv/amd64/ena"   # gid 3 = sys
install -m 0644 -o 0 -g 3 ena.conf "$MNT/kernel/drv/ena.conf"

echo "=== driver_aliases ==="
for a in 'pciex1d0f,ec2' 'pciex1d0f,1ec2' 'pciex1d0f,ec20' 'pciex1d0f,ec21'; do
  grep -q "^ena \"$a\"" "$MNT/etc/driver_aliases" || echo "ena \"$a\"" >> "$MNT/etc/driver_aliases"
done

echo "=== name_to_major (pick a free major if 152 is taken) ==="
if ! grep -qw '^ena' "$MNT/etc/name_to_major"; then
  MAJ=$(awk '{print $2}' "$MNT/etc/name_to_major" | sort -n | tail -1)
  MAJ=$((MAJ+1))
  echo "ena $MAJ" >> "$MNT/etc/name_to_major"
  echo "assigned major $MAJ"
fi

echo "=== NOTE: boot_archive rebuild must happen ON illumos (bootadm), not here."
echo "    The driver is on the disk; illumos loads it after root mounts from disk."
echo "    If the NIC still doesn't attach, boot once and run: bootadm update-archive"

sync
zpool export "$POOL"
echo "=== ena injected into $BE_DS ==="
