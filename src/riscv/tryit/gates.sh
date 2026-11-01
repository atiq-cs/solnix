#!/usr/bin/env bash
# gates.sh KERNEL TAG N -- tryit1: boot KERNEL N times under qemu virt -smp 4 with build-unix.sh's device set
# (the uts rootfs.img/disk.img/data.img made by user/build-user.sh) and count the 8 boot gates.
set -u; K=$1; T=$2; N=${3:-1}; U="$(cd "$(dirname "$0")/../uts" && pwd)"; L=${LOGS:-$HOME/w/logs}; mkdir -p $L
for i in $(seq 1 $N); do
  W=$(mktemp -d); cp $U/rootfs.img $U/data.img $U/disk.img $W/
  timeout -s KILL 150 qemu-system-riscv64 -machine virt -smp 4 -nographic -bios default -kernel $K -global virtio-mmio.force-legacy=false \
    -drive file=$W/disk.img,if=none,id=hd0,format=raw -device virtio-blk-device,drive=hd0 \
    -drive file=$W/rootfs.img,if=none,id=fs0,format=raw -device virtio-blk-device,drive=fs0 \
    -drive file=$W/data.img,if=none,id=data0,format=raw -device virtio-blk-device,drive=data0 \
    -netdev user,id=n0 -device virtio-net-device,netdev=n0 -device virtio-gpu-device < /dev/null > $L/gates-$T-$i.log 2>&1 &
  Q=$!	# every gate has run once the console login prompt appears: stop there (else wait out the timeout)
  for _ in $(seq 1 150); do grep -q 'solnix-riscv login' $L/gates-$T-$i.log 2>/dev/null && break; kill -0 $Q 2>/dev/null || break; sleep 1; done
  pkill -9 -P $Q 2>/dev/null; kill -9 $Q 2>/dev/null; wait $Q 2>/dev/null
  n=0; for g in "TP GATE PASS" "SOCKTEST PASS" "POLLTEST PASS" "PORTTEST PASS" "FPTEST PASS" "FBTEST PASS" "MINIWL PASS" "NEWLIBTEST PASS"; do
    grep -q "$g" $L/gates-$T-$i.log && n=$((n+1)) || echo "  boot $i MISSING: $g"; done
  echo "gates $T boot $i: $n/8 pass; login=$(grep -c 'solnix-riscv login' $L/gates-$T-$i.log) panics=$(grep -ci panic $L/gates-$T-$i.log)"
  find $W -delete
done
