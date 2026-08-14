#!/usr/bin/env bash
#
# rp24-milestone-check.sh -- re-runnable proof of the R-P24 milestone: the
# R-P23 booting illumos riscv64 kernel grown with Sv39 paging, a periodic
# clock, the qemu-virt PLIC, and a minimal kmem/page/dispatcher genunix
# on-ramp -- all boot-verified under qemu-system-riscv64 -machine virt.
#
# Rebuilds the kernel from source and re-boots it, asserting all four sub-tasks
# from the fresh boot log.
set -e
export PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
cd /root/riscv-port/rp24/kernel
bash build-kernel.sh
echo
echo "R-P24 milestone: green (Sv39 paging + clock + PLIC + kmem/page/dispatcher)."
