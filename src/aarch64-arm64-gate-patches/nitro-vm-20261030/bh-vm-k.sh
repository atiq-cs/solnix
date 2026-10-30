#!/bin/bash
# bh-vm-k.sh <tag> <fixpatcher> : on bh. Reset Makefile.rules, force a dboot rebuild (its objects do not depend on
# Makefile.rules), then the aa64h kernel build with FIX=<fixpatcher>; pack kmods. Log /build/k-aa64h-<tag>.log
T=$1; F=$2; G=/aarch64/arm64-gate/illumos-gate; U=$G/usr/src/uts
cd $G && git checkout -- usr/src/uts/armv8/Makefile.rules usr/src/uts/aarch64/sys/bootinfo.h || exit 1
[ -f /build/aa64vm/boot_uart.c.base ] || cp $U/armv8/boot/boot_uart.c /build/aa64vm/boot_uart.c.base
cp /build/aa64vm/boot_uart.c.base $U/armv8/boot/boot_uart.c   # m4's base edit (drain drop); p12 edits it
find $U/armv8/unix/dboot/debug64 -name '*.o' -exec rm -f {} +
cp /build/aa64vm/$F.py /build/aa64h/$F.py
TAG=$T FIX=$F bash /build/aa64h/bh-aa64h-k.sh
bash /build/aa64h/bh-kpack.sh $T > /build/kpack-$T.log 2>&1; tail -1 /build/kpack-$T.log
