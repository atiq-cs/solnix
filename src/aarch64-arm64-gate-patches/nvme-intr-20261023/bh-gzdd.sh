#!/bin/bash
# bh-gzdd.sh <name> <vol-serial> : raw sha, gzip, gz sha, dd to the EBS image disk, readback sha
exec >/build/gzdd-$1.log 2>&1
set -x; date
cd /build/out
digest -a sha256 illumos-metal.img > $1.raw.sha256; cat $1.raw.sha256
gzip -1 -c illumos-metal.img > $1.img.gz; digest -a sha256 $1.img.gz > $1.gz.sha256; cat $1.gz.sha256
bash /build/patches/bh-dd.sh $2 /build/out/$1.img.gz
cat /build/dd.log | tail -4
echo "=== GZDD_DONE $(date) ==="
