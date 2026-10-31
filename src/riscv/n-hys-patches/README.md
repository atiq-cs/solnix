# Patches on n-hys/illumos-gate (osport/v2021.07 3f7cd4cf) for dixr, the riscv64 solnix build host

Each one was found and checked on a qemu virt guest on EC2 (dixr2, 2026-10-31; docs/dixr-build-host-plan.md).
- 0001: four fixes to the n-hys tree:
  - openssh uses --with-solaris-privs --with-sandbox=solaris. A cross build assumed the rlimit sandbox, which sets
    RLIMIT_NOFILE to 0, so illumos poll() gave EINVAL in sshd's preauth child.
  - nss_dns links -lresolv. Without it, its resolver slots jumped to 0 and getent and login died with SIGSEGV.
  - riscv64 libc exports 6 symbols it defined but didn't export, including qsort_r for libgit2.
  - uts/riscv64/asm/atomic.h uses __inline__, so -std=c90 builds compile.
- 0002: gcc 11.1, a backport of r12-1697 for PR c++/80431. It silently skipped a member's constructor in nix's settings
  classes, so nix aborted or segfaulted. The bug's reproducer passes with the backport; the old compiler fails it.
- 0003: nix 2.24.15 on gcc 11's libstdc++ (visit on a type derived from std::variant); goes away with gcc >= 12.
