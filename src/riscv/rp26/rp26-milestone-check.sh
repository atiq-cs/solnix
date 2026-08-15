#!/usr/bin/env bash
#
# rp26-milestone-check.sh -- re-runnable proof of the R-P26 milestone: the
# R-P25 booting illumos riscv64 kernel GROWN into a MULTIPROCESS kernel: a
# proc/lwp table + fork(2)/exec(2)/wait(2) + a runq dispatcher (a real context
# switch between process kernel stacks).  A parent process forks a child, both
# run through the dispatcher and print their pid, the child exits, and the
# parent waits + reaps it -- the first riscv64-solaris fork+wait.  Then a
# process fork+exec+waits a DIFFERENT embedded program.  All boot-verified
# under qemu-system-riscv64 -machine virt.
#
# Rebuilds the userland programs + the kernel from source and re-boots,
# asserting every sub-task (plus the R-P24 regression) from the fresh boot log.
set -e
export PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
cd /root/riscv-port/rp26/kernel
bash build-kernel.sh
echo
echo "R-P26 milestone: green (proc/lwp table + fork/exec/wait + a runq"
echo "dispatcher scheduling between process kernel stacks; R-P24 regress-green)."
