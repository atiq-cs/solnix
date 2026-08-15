#!/usr/bin/env bash
#
# rp27-milestone-check.sh -- R-P27 re-runnable proof.  Rebuilds the userland
# programs + the userland ld.so.1 + the initramfs + the kernel, boots it under
# qemu-system-riscv64 -machine virt (OpenSBI), and asserts every R-P27 sub-task
# from the boot log plus the R-P24 + R-P26 regressions:
#   R-P27.1 timer-tick PREEMPTION  -- two CPU-bound procs INTERLEAVE via the
#           100 Hz tick (neither monopolizes; cooperative -> preemptive)
#   R-P27.2 fs-backed exec + ramfs -- exec(path) resolves the ELF by name out
#           of a linked-in initramfs archive
#   R-P27.3 ld.so.1 hosts the DYNAMIC hello -- exec sees PT_INTERP, loads
#           ld.so.1, which relocates the app + jumps to it (first dynamically-
#           linked riscv64-solaris process; proven by the captured exit status)
# build-kernel.sh performs the build + boot + per-sub-task grep asserts; this
# wrapper just runs it and echoes the verdict.
set -e
export PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:$PATH
bash /root/riscv-port/rp27/kernel/build-kernel.sh
echo "=== R-P27 milestone check complete (see the PASS lines above) ==="
