# solnix ILP32-on-AMD (g4ad / Zen2) fix

## Summary
The ILP32 (32-bit) SIGKILL loop on AMD was NOT a kernel bug — it is a solnix
userland packaging bug in libc. No kernel source change is required.

## Root cause
- solnix shipped the BASE /lib/libc.so.1 as the SYSENTER variant of illumos
  libc: it tags CA_SUNW_HW_1 requiring AV_386_SEP (0x8) and emits the
  `sysenter` instruction for its syscall stubs (193 occurrences).
- The illumos amd64 kernel removes X86FSET_SEP on all AMD
  (usr/src/uts/intel/os/cpuid.c, ~line 4628: "AMD processors don't support
  sysenter in long mode"). X86FSET_SEP also drives the 32-bit userland hwcap
  AV_386_SEP via x86fset_to_av1[] (cpuid.c:5829).
- On AMD therefore: ld.so.1 rejects the SEP-requiring libc (fatal ->
  process dies, seen as SIGKILL/9). If the hwcap tag is stripped, libc loads
  but `sysenter` in 32-bit compat mode under the long-mode kernel #UDs ->
  SIGILL/4. Every 32-bit process dies -> init(8) restart loop -> no userland.

## Fix (userland; the actual change that was applied on the g4ad root)
Replace the base libc with the int/syscall variant solnix already builds:

    cp /usr/lib/libc/libc_hwcap3.so.1 /lib/libc.so.1

libc_hwcap3.so.1: 0 sysenter, 208 `int $0x91` (T_SYSCALLINT) + 144 `syscall`,
hwcap CA_SUNW_HW_1 = 0x861 (FPU|CMOV|MMX|SSE — all present on Zen2, no SEP).
The amd64 kernel supports both on AMD:
  - sys_syscall_int  (the int $0x91 / T_SYSCALLINT trap gate) — always.
  - MSR_AMD_CSTAR = sys_syscall32 (the 32-bit `syscall` insn) — programmed in
    usr/src/uts/i86pc/os/mp_startup.c init_cpu_syscall() when X86FSET_ASYSC is
    set (true on AMD).

Backup of the broken sysenter base libc left at /lib/libc.so.1.sysenterbak.

## Permanent fix (solnix build)
Make the solnix libc package install the int/syscall build as the base
/lib/libc.so.1 (upstream illumos does exactly this). Keep the sysenter build
(libc_hwcap1.so.1) only as an Intel-selected hwcap variant. The base libc must
never require AV_386_SEP, because illumos-on-AMD deliberately never advertises
it (correct: AMD lacks sysenter in long mode).

## No kernel diff needed
cpuid.c removing X86FSET_SEP on AMD is CORRECT for the kernel's own syscall
path. The only defensible optional kernel change would be to advertise
AV_386_SEP for 32-bit compat processes on AMD (Zen2 supports sysenter in
legacy/compat mode) — but that is unnecessary and riskier than shipping the
correct base libc, which is what upstream does. Recommended fix stays in
userland packaging.
