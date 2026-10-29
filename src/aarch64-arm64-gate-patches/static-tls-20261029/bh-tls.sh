#!/bin/bash
# bh-tls.sh : on bh. TAG=<t> [DIFFS="rtld libc ld"]. Reset the 4 files to the pin, apply the aa64tls diffs, seed the proto's
# userland from the banked proto (once), build libc then sgs (rtld, ld, libld ...) DEBUG as the image, pack. Log /build/tls-$TAG.log
exec >/build/tls-${TAG:-x}.log 2>&1
set -x; date
G=/aarch64/arm64-gate/illumos-gate; P=$G/proto/root_aarch64; cd $G || exit 1
git checkout -- usr/src/cmd/sgs/rtld/common/elf.c usr/src/cmd/sgs/rtld/common/tls.c \
  usr/src/lib/libc/port/threads/tls.c usr/src/cmd/sgs/libld/common/machrel.aarch64.c || exit 1
for d in ${DIFFS-rtld libc ld}; do gpatch -p1 < /build/aa64tls/aa64tls-$d.diff || { echo PATCH_FAIL $d; exit 3; }; done
git diff --stat -- usr/src/cmd/sgs usr/src/lib/libc
[ -f $P/lib/libc.so.1 ] || rsync -a --ignore-existing /stage/rproto/root_aarch64/ $P/ || exit 4
export PATH=/usr/gnu/bin:/opt/onbld/bin:/usr/bin:/usr/sbin:/bin:/opt/ooce/bin LOGNAME=root MAILTO=root
./usr/src/tools/scripts/bldenv -d -t -T aarch64 /aarch64/arm64-gate/env/aarch64 <<'INNER'
cd $SRC/lib/libc && dmake -e install; echo "=== RC libc=$? ==="
cd $SRC/cmd/sgs && dmake -e install; echo "=== RC sgs=$? ==="
INNER
cd $P; F="lib/ld.so.1 lib/libc.so.1 lib/liblddbg.so.4 lib/librtld.so.1 lib/libld.so.4 lib/libelf.so.1 usr/bin/ld"
ls -la $F; tar cf /stage/tls-${TAG:-x}.tar $F && digest -a sha256 /stage/tls-${TAG:-x}.tar $F
echo "=== TLS_BUILD_DONE $(date) ==="
