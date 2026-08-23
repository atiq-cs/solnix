# solnix GPU parity on AMD V520 (g4ad) — Stage 1 root cause + honest verdict

Instance i-037b2e911e4d08f4d, g4ad.2xlarge, AMD EPYC 7R32 (family 23 / model 49 = Zen 2 "Rome"),
8 vCPU @ 2800 MHz, AMD Radeon Pro V520 (Navi 12). AMI ami-0223f9a80bfaf2735 (BIOS-boot + cu_flags=0).

## STAGE 1 — init(8) SIGKILL loop: ROOT CAUSE ISOLATED (not yet fixed)

### Observability was the first wall
- Serial-console SSH is BLOCKED: IAM denies ec2-instance-connect:SendSerialConsoleSSHPublicKey and
  SendSSHPublicKey for user chiuso (account-level enable-serial-console-access succeeded, but the key-push
  API is denied). No interactive console / kmdb.
- get-console-output floods: the init loop emits ~936 identical "WARNING: init(8) exited on fatal signal 9:
  restarting automatically" lines in <6 s, saturating the 64 KB console ring before AWS snapshots it, so the
  kernel banner and any fault are overwritten. Caught the boot window only by rapid (3-6 s) polling right
  after reboot and keeping every distinct buffer.

### Kernel-source trace (illumos-gate)
- The message is emitted by the KERNEL: uts/common/os/exit.c restart_init() -> exit_reason(CLD_KILLED, 9).
  The kernel re-execs PID 1 (/sbin/init) each time it dies. "restarting automatically" (not "system reboot
  required") => exec_init SUCCEEDS every iteration; init RUNS then dies by SIGKILL (SKILLED flag).
- /sbin/init is a 32-bit i386 ELF (interp /lib/ld.so.1). start_init_common() also forces DATAMODEL_ILP32.

### The decisive experiment (diagnostic-init probes, via offline boot_archive/ZFS edits)
Replaced /sbin/init with shell-script diagnostics that print a unique marker to /dev/console and loop:
- 32-bit interpreter (#!/sbin/sh -> 32-bit ksh93): SIGKILLed, loop persists, NO marker.
- 64-bit interpreter (#!/usr/bin/ksh93 -> 64-bit ksh93): *** "SOLNIX-DIAG64: 64bit userland ALIVE" + TICK 0
  PRINTED ***. Loop HALTED; full kernel banner became visible.

CONCLUSION: **64-bit (LP64) userland runs fine on the g4ad AMD Zen2. Every 32-bit (ILP32) process is
force-SIGKILLed.** illumos userland is ~90% 32-bit here (init, svc.startd, sulogin, syseventd, most of
/sbin and /usr/sbin are 32-bit i386 ELF; counts: sbin 36/38 32-bit, usr/sbin 182/245, lib/svc/bin 6/7).
So a 64-bit-only init is NOT a workaround — startd and the rest still die. This needs a KERNEL fix.

### Fault character (what it is / is NOT)
- With set tudebug=1 tudebugfpe=1 tudebugsse=1 tudebugbpt=1, the ONLY trap dump ever printed is a benign,
  on_trap()-caught kernel #gp in pid=0: rdmsr(0xC0010055 = MSR_AMD_INT_PENDING_CMP_HALT, the C1E-disable
  probe in post_startup_cpu_fixups()) — the g4ad hypervisor rejects that AMD MSR (same class as the earlier
  cu_flags/MSR-0xc0010000 fix), but it is wrapped in on_trap so the system continues (root mounts, devices
  probe). It is NOT the init killer.
- There is NO user-mode trap dump for the dying 32-bit init in any capture (no SIGSEGV/SIGILL/SIGFPE via
  trap()). => the 32-bit process death is a SILENT in-kernel force-kill during process/LWP setup or the
  return-to-user path for compat mode, BEFORE the process executes a faulting user instruction. Most likely
  the ILP32 lwp_load/setregs segment-selector setup or the 32-bit sysret/return-to-user trampoline on this
  AMD+hypervisor combination.

### Tunables tried (in the boot_archive /etc/system, the ramdisk illumos actually reads), all NEGATIVE:
- set xsave_force_disable = 1  (force legacy FXSAVE, mask XSAVE/AVX/F16C/FMA) — loop persists.
- set use_mp = 0               (single-CPU; rules out AP-featureset-mismatch — boot shows "Not in MP mode"
                                and the "cpuN feature mismatch" warnings, but the loop persists) — negative.
- (cu_flags = 0 and exclude pcbe.AuthenticAMD were already baked; they fixed the earlier PMC #gp panic.)

### Verdict for Stage 1
NOT fixed. Root cause narrowed to: **the illumos 32-bit (ILP32 compat-mode) process bring-up / return-to-user
path faults on AMD Zen2 under the g4ad hypervisor, silently SIGKILLing every 32-bit process; 64-bit userland
is unaffected.** Pinning the exact faulting instruction requires kmdb (an early kernel breakpoint on the
return-to-user / lwp_rtt / sysret32 path), which is blocked by the IAM/serial-console restrictions on this
account. The next concrete step is a kmdb-equipped boot (needs serial-console SSH IAM perms) or a small
targeted kernel patch/instrumentation in the ILP32 setregs/sysret path, rebuilt into the boot_archive.

## STAGE 2 — amdgpu V520 bind: NOT REACHED (gated by Stage 1 — no userland, no add_drv/update_drv).

## STAGE 3 — measurement: NOT RUN. No /dev/dri, no solnix V520 tok/s. Nothing fabricated.
Linux V520 baseline stands: GGML_VULKAN TinyLlama-1.1B-Q4 = 1995 pp / 283 tg tok/s.

## Net
This session turned the opaque "init SIGKILL-loops 936x" blocker into a precise, reproducible
characterization: 64-bit solnix userland runs on the AMD g4ad; 32-bit userland is force-killed by a
silent in-kernel fault in the ILP32 bring-up/return-to-user path (not a user trap, not XSAVE, not SMP).
That is the first real solnix-on-AMD-userland data point and the exact seam the fix must target.
