#!/bin/bash
exec >>/var/log/aa-setupcross.log 2>&1
set -x
echo "=== SETUP CROSS START $(date) ==="
GATE=/aarch64/arm64-gate
SEED=/build/seed-unpack/seed
CROSS=$GATE/build/cross
SYSROOT=$GATE/build/sysroot
STAMPS=$GATE/stamps
mkdir -p $CROSS $SYSROOT $STAMPS

# ---- build/cross: the gcc install prefix layout ----
# Gate expects $CROSS/bin/<triple>-{gcc,as,ld,...}, $CROSS/lib/gcc, $CROSS/libexec/gcc,
# $CROSS/<triple>/..., and $CROSS/opt/onbld/bin/amd64/ld
rsync -a $SEED/usr/gcc/aarch64-14/ $CROSS/
# the Solaris link-editor (sgs output) that gcc --with-ld points at
mkdir -p $CROSS/opt/onbld/bin/amd64
rsync -a $SEED/opt/onbld/ $CROSS/opt/onbld/
echo "--- cross bin ---"; ls $CROSS/bin/ | head
echo "--- cross onbld ld ---"; ls -la $CROSS/opt/onbld/bin/amd64/ld

# ---- build/sysroot: the aarch64 target sysroot (headers + runtime libs) ----
# Gate expects $SYSROOT/usr/include, $SYSROOT/lib, $SYSROOT/usr/lib
rsync -a $SEED/lib/ $SYSROOT/lib/
rsync -a $SEED/usr/ $SYSROOT/usr/
echo "--- sysroot include ---"; ls $SYSROOT/usr/include/stdio.h $SYSROOT/usr/include/sys/types.h 2>&1
echo "--- sysroot libc/crt ---"; ls $SYSROOT/lib/libc.so.1 $SYSROOT/usr/lib/crt1.o 2>&1
echo "--- python3.13 headers in sysroot? (sgs wall check) ---"; ls $SYSROOT/usr/include/python3.13/Python.h 2>&1

# ---- touch the setup stamps so make illumos skips make setup ----
for s in sysroot binutils-gdb sgs boot-gcc gcc perl u-boot u-boot-qemu u-boot-rpi4 arm-trusted-firmware dtc barn; do
  touch $STAMPS/$s-stamp
done
echo "--- stamps ---"; ls $STAMPS/

# ---- verify the cross gcc runs from build/cross and emits aarch64 ----
echo "int main(void){return 0;}" > /tmp/h.c
$CROSS/bin/aarch64-unknown-solaris2.11-gcc --sysroot=$SYSROOT -c /tmp/h.c -o /tmp/h.o 2>&1 | head
file /tmp/h.o
echo "dumpmachine: $($CROSS/bin/aarch64-unknown-solaris2.11-gcc -dumpmachine)"
echo "=== SETUP CROSS DONE $(date) ==="
