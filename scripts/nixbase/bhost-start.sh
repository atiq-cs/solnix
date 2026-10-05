#!/usr/bin/env bash
# bhost with two extra scratch disks (constraint-test disk + target disk)
cd /var/tmp/bhost
OV=/nix/store/0wbr8qhmbddqd419hfapj3pkzn71xrq1-OVMF-202402-fd/FV
rm -f serial.sock mon.sock qemu.pid
setsid qemu-system-x86_64 -enable-kvm -cpu host -M q35 -m 8192 -smp 6 \
  -drive if=pflash,format=raw,unit=0,readonly=on,file=$OV/OVMF_CODE.fd \
  -drive if=pflash,format=raw,unit=1,file=/var/tmp/bhost/vars.fd \
  -drive file=/var/tmp/bhost/bhost.qcow2,format=qcow2,if=none,id=d0 -device virtio-blk-pci,drive=d0,bootindex=0 \
  -drive file=/var/tmp/nixbase/cdisk.qcow2,format=qcow2,if=none,id=d1 -device virtio-blk-pci,drive=d1 \
  -drive file=/var/tmp/nixbase/target.qcow2,format=qcow2,if=none,id=d2 -device virtio-blk-pci,drive=d2 \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n0 \
  -chardev socket,id=s0,path=/var/tmp/bhost/serial.sock,server=on,wait=off,logfile=/var/tmp/bhost/serial.log \
  -serial chardev:s0 -display none -monitor unix:/var/tmp/bhost/mon.sock,server,nowait \
  -pidfile /var/tmp/bhost/qemu.pid </dev/null >/var/tmp/bhost/qemu.out 2>&1 &
disown; sleep 3; echo "pid=$(cat /var/tmp/bhost/qemu.pid 2>/dev/null)"
