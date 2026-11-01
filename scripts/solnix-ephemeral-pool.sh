#!/bin/sh
# solnix-ephemeral-pool.sh -- bring up $POOL on $DISKS (modules/config/ephemeral-pool.nix).
# Env: POOL, DISKS, SOLNIX_EP_DATASETS (lines: name<TAB>mountpoint<TAB>owner<TAB>mode).
#   imported                         -> nothing to do
#   every disk labelled for $POOL    -> import it from exactly those disks (a reboot)
#   every disk blank                 -> create it (first boot, or after a stop wiped them)
#   anything else                    -> refuse, touch nothing, exit 1 (svcs -x shows why)
# The pool has cachefile=none, so a stop cannot leave a stale UNAVAIL entry behind.
# SOLNIX_EP_DRYRUN=1: print the zpool/zfs/chown commands instead of running them.
PATH=/usr/sbin:/usr/bin:/sbin
: "${POOL:?}" "${DISKS:?}" "${SOLNIX_EP_DATASETS:?}"
run() { if [ -n "${SOLNIX_EP_DRYRUN:-}" ]; then echo "would: $*"; else "$@"; fi; }

# blank <disk>: no ZFS label on p0 (zdb -l exits 0 when it unpacks one), no GPT at
# LBA 1, no MBR 55aa. Instance store reads back random, so not "all zero".
blank() {
  r=/dev/rdsk/${1}p0
  [ -c "$r" ] || { echo "$1: no $r"; return 1; }
  zdb -l "$r" >/dev/null 2>&1 && { echo "$1: has a ZFS label"; return 1; }
  [ "$(dd if="$r" bs=512 skip=1 count=1 2>/dev/null | dd bs=8 count=1 2>/dev/null)" = "EFI PART" ] \
    && { echo "$1: has a GPT"; return 1; }
  [ "$(dd if="$r" bs=1 skip=510 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')" = 55aa ] \
    && { echo "$1: has an MBR"; return 1; }
  return 0
}
# ours <disk>: a whole-disk vdev of $POOL (zpool create labels it EFI, data on s0).
ours() { zdb -l "/dev/rdsk/${1}s0" 2>/dev/null | grep -q "^ *name: '$POOL'\$"; }

if zpool list -H -o name "$POOL" >/dev/null 2>&1; then
  echo "$POOL is imported; nothing to create"
else
  nb=0; no=0; n=0; why=""
  for d in $DISKS; do
    n=$((n+1)); ours "$d" && { no=$((no+1)); continue; }
    w=$(blank "$d") && nb=$((nb+1)) || why="$why $w;"
  done
  if [ $no -eq $n ]; then
    L=/tmp/solnix-ep.$$; mkdir -p $L || exit 1
    for d in $DISKS; do ln -s /dev/dsk/${d}s0 $L/${d}s0; done
    run zpool import -o cachefile=none -d $L "$POOL"; rc=$?
    rm -f $L/*; rmdir $L; [ $rc -eq 0 ] || exit 1
  elif [ $nb -eq $n ]; then
    run zpool create -f -o cachefile=none -o autoexpand=on -O compression=lz4 -O atime=off \
      -O mountpoint=none "$POOL" $DISKS || exit 1
  else
    echo "REFUSE: $POOL not created or imported ($no/$n ours, $nb/$n blank):$why"; exit 1
  fi
fi
while IFS='	' read -r ds mp own mode; do
  [ -n "$ds" ] || continue
  zfs list -H -o name "$POOL/$ds" >/dev/null 2>&1 || run zfs create -p -o mountpoint="$mp" "$POOL/$ds" || exit 1
  # A dataset whose mountpoint directory already holds files does not mount (zfs refuses a non-empty dir), and the
  # chown below would then fix the ROOT disk's directory instead: what happened to dixi's /var/tmp/big after a switch
  # (builds wrote it on spool before data existed). Move the stray contents aside, then mount; never delete them.
  if [ "$(zfs get -H -o value mounted "$POOL/$ds")" != yes ]; then
    if [ -d "$mp" ] && [ -n "$(ls -A "$mp" 2>/dev/null)" ]; then
      a="$mp.pre-$POOL.$(date +%Y%m%d%H%M%S)"; run mv "$mp" "$a" && echo "moved non-empty $mp to $a" || exit 1
    fi
    run zfs mount "$POOL/$ds" || exit 1
  fi
  run chown "$own" "$mp" && run chmod "${mode:-0755}" "$mp" || exit 1
done < "$SOLNIX_EP_DATASETS"
echo "$POOL ready: $(zpool list -H -o name,size,health "$POOL" 2>/dev/null)"
exit 0
