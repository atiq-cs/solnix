#!/bin/sh
# constraint-test BEs on bhost rpool (clones; default BE untouched)
set -x
mkdir -p /nix/ctest
cp -p /platform/i86pc/kernel/amd64/unix /nix/ctest/unix
cp -p /platform/i86pc/amd64/boot_archive /nix/ctest/boot_archive
cp -p /sbin/init /nix/ctest/init
for be in ctA ctB1 ctB2; do beadm destroy -Ffs $be >/dev/null 2>&1; beadm create $be; done
mkdir -p /mnt/ctA /mnt/ctB1 /mnt/ctB2
beadm mount ctA /mnt/ctA; beadm mount ctB1 /mnt/ctB1; beadm mount ctB2 /mnt/ctB2
M=/mnt/ctA; mkdir -p $M/ct
ln -s ../platform/i86pc/kernel/amd64/unix   $M/ct/unix-rel
ln -s /platform/i86pc/kernel/amd64/unix     $M/ct/unix-abs
ln -s /nix/ctest/unix                       $M/ct/unix-nix
ln -s /nonexistent/unix                     $M/ct/unix-dangling
ln -s ../platform/i86pc/amd64/boot_archive  $M/ct/ba-rel
ln -s /nix/ctest/boot_archive               $M/ct/ba-nix
ls -l $M/ct $M/nix | head -20
# B1: init symlinked ACROSS datasets into rpool/nix (BE has only an empty /nix mountpoint dir)
M=/mnt/ctB1; mv $M/sbin/init $M/sbin/init.real; ln -s /nix/ctest/init $M/sbin/init
# B2: init symlinked WITHIN the BE dataset (positive control)
M=/mnt/ctB2; mv $M/sbin/init $M/sbin/init.real; ln -s /sbin/init.real $M/sbin/init
ls -l /mnt/ctB1/sbin/init /mnt/ctB2/sbin/init /mnt/ctB1/nix
for be in ctA ctB1 ctB2; do beadm unmount $be; done
beadm list; zpool get bootfs rpool
