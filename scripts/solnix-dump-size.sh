#!/bin/sh
# solnix-dump-size.sh -- size the root pool's crash-dump zvol for THIS machine, then make it the dump device.
# An image carries a 1G placeholder <pool>/dump (built on a host whose RAM is not the target's); this grows it
# to the installer's rule -- half of RAM, 1..16 GiB, at most a quarter of the pool -- and runs `dumpadm -d`.
# Leaves alone any dedicated dump device (this zvol or one the operator chose): resizing a dumpified zvol
# re-initialises the dump area (uts/common/fs/zfs/zvol.c zvol_update_live_volsize), which would free a crash
# dump savecore has not read. Never shrinks. No <pool>/dump -> nothing to do. Runs every boot; a no-op after the first.
PATH=/usr/sbin:/usr/bin:/sbin
POOL=${SOLNIX_DUMP_POOL:-$(awk '$2=="/"{split($1,a,"/"); print a[1]; exit}' /etc/mnttab)}
ZV=$POOL/dump; DEV=/dev/zvol/dsk/$ZV; G=1073741824
[ -n "$POOL" ] && zfs list -H -o name "$ZV" >/dev/null 2>&1 || { echo "no $ZV; nothing to do"; exit 0; }
if dumpadm 2>/dev/null | grep -q 'Dump device:.*(dedicated)'; then echo "a dedicated dump device is set; $ZV not resized"; exit 0; fi
mb=$(prtconf 2>/dev/null | awk '/^Memory size/{print $3; exit}')
want=$(( ${mb:-2048} / 2 / 1024 )); [ "$want" -lt 1 ] && want=1; [ "$want" -gt 16 ] && want=16
q=$(( $(zpool list -Hp -o size "$POOL") / 4 / G )); [ "$want" -gt "$q" ] && want=$q; [ "$want" -lt 1 ] && want=1
have=$(( $(zfs get -Hp -o value volsize "$ZV") / G ))
echo "RAM ${mb}MB pool/4 ${q}G -> want ${want}G, $ZV is ${have}G"
if [ "$want" -gt "$have" ]; then zfs set volsize=${want}G "$ZV" || echo "WARN: zfs set volsize=${want}G $ZV failed"; fi
dumpadm -d "$DEV" || echo "WARN: dumpadm -d $DEV failed"
exit 0
