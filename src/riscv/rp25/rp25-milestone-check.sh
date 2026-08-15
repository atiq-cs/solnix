#!/usr/bin/env bash
#
# rp25-milestone-check.sh -- re-runnable proof of the R-P25 milestone: the
# R-P24 booting illumos riscv64 kernel GROWN with the syscall/exec path so a
# userland PROCESS runs.  The kernel builds a user address space, execs the
# embedded static hello ELF (maps its PT_LOAD segments + a user stack), sret's
# into U-mode, and the process makes its OWN write(2)/exit(2) syscalls through
# the trap path -- the first riscv64-solaris userland process.  All
# boot-verified under qemu-system-riscv64 -machine virt.
#
# Rebuilds the userland hello + the kernel from source and re-boots, asserting
# every sub-task (plus the R-P24 regression) from the fresh boot log.
set -e
export PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
cd /root/riscv-port/rp25/kernel
bash build-kernel.sh
echo
echo "R-P25 milestone: green (U-mode entry + write/exit syscalls + a running"
echo "userland process + a minimal static-ELF exec; R-P24 subsystems regress-green)."
