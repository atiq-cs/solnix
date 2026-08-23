# solnix GPU parity on AMD V520 (g4ad): the honest result

## STEP 1 -- BIOS-boot solnix AMI for g4ad: SOLVED
g4ad is BIOS-only + rejected the UEFI solnix AMI. Fix:
- `register-image --boot-mode legacy-bios` of the snapshot (ami-08aca42aec39d5457) was ACCEPTED by g4ad
  (dry-run) but did NOT boot -- the disk had no MBR/BIOS boot block (UEFI-registered ZFS root).
- DISK SURGERY on a native illumos helper: `installboot -m -f /boot/pmbr /boot/gptzfsboot /dev/rdsk/cNt1d0s1`
  writes the illumos BIOS stage1 (pmbr->MBR) + stage2 (gptzfsboot->ZFS pool boot area) onto the GPT/ZFS disk.
  Re-snapshot, register legacy-bios.
- RESULT: solnix BIOS-BOOTS on g4ad.2xlarge -- serial console shows the full illumos loader ("Welcome to
  illumos", autoboot), Loading unix + boot_archive, AMD EPYC kernel up (32GB, TSC calibrated). First solnix
  boot on a BIOS-only AMD/V520 instance. Durable AMIs: ami-024c278b8ea631a92 (boot-block),
  ami-0223f9a80bfaf2735 (boot-block + cu_flags-fix).

## STEP 2 -- amdgpu V520 bind: BLOCKED by two solnix-on-AMD kernel bugs (found en route to userland)
- 2a FIXED: boot-loop kernel panic -- wrmsr #GP on MSR 0xc0010000 (AMD PERF_CTL0), which the g4ad hypervisor
  rejects, via illumos's cu/kcpc PMC path. Fix: `set cu_flags = 0` inside the BOOT_ARCHIVE (/etc/system is
  read from the boot_archive ramdisk, NOT the ZFS root -- the key detail). Panic gone.
- 2b ROOT-CAUSED (init SIGKILL loop): the exact fault class is now named. The kernel (exit.c restart_init)
  re-execs PID1 /sbin/init, it runs, then dies by SIGKILL, 936x. Diagnostic-init probes (swap /sbin/init for
  a shell script that prints a console marker, via offline ZFS+boot_archive edits) PROVED:
    * 32-bit interp (#!/sbin/sh = 32-bit ksh93): SIGKILLed, no marker -- loop persists.
    * 64-bit interp (#!/usr/bin/ksh93 = 64-bit ksh93): "SOLNIX-DIAG64 ALIVE" PRINTED -- loop halts, banner shows.
  => 64-bit (LP64) userland RUNS on the g4ad AMD EPYC 7R32 (Zen2); EVERY 32-bit (ILP32) process is silently
  force-SIGKILLed. illumos userland is ~90% 32-bit (init/svc.startd/sulogin/syseventd all 32-bit i386 ELF),
  so a 64-bit-only init is no workaround -- it needs a KERNEL fix. With tudebug=1/fpe/sse/bpt the ONLY trap
  seen is a benign on_trap-caught pid=0 kernel #gp on rdmsr(0xC0010055 MSR_AMD_INT_PENDING_CMP_HALT, the C1E
  probe -- another AMD MSR the hypervisor rejects, but caught so non-fatal). NO user-mode trap for the dying
  32-bit init => the death is a silent in-kernel force-kill in the ILP32 process bring-up / return-to-user
  path, not a user instruction fault, not XSAVE (xsave_force_disable negative), not SMP (use_mp=0 negative).
  Pinning the exact instruction needs kmdb (blocked: IAM denies serial-console-SSH key push on this account).
  Observability method that worked: rapid 3-6s get-console-output polling right after reboot (the loop
  saturates the 64KB console ring in <6s, so only a fast poll catches the banner). The amdgpu V520 bind was
  NEVER attempted -- no 32-bit-capable userland on g4ad yet. See /root/GPU-BENCH-SOLNIX.md on the box.

## STEP 3 -- measurement: NOT RUN. No /dev/dri/card0 -> no solnix V520 tok/s. Nothing fabricated. Linux V520
baseline stands at 1995 pp / 283 tg.

## Net
solnix now BIOS-boots on the AMD/V520 g4ad (a real win -- the boot-block surgery + the cu_flags MSR fix are
durable, in the AMIs). The amdgpu measurement is blocked one layer earlier than the GPU: an AMD-specific
illumos userland fault (init SIGKILL loop) that needs a kmdb capture to pinpoint. So the GPU-parity path on
AMD is: fix the init-loop (2b) -> userland -> amdgpu C3 bind -> GGML_VULKAN -> the first solnix V520 number
vs Linux 1995/283. The NVIDIA path is blocked earlier still (no nouveau kernel driver at all).
