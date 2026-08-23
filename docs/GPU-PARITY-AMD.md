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
- 2b THE EXACT BLOCKER: with the panic fixed, init(8) SIGKILL-loops (936x). Ruled out SMF (persists at
  -m milestone=none) + device-state (persists with empty path_to_inst self-reconfigure across 4 AMI builds).
  A second AMD-userland fault; needs a kmdb/serial pre-loop capture to name the faulting op. The V520 amdgpu
  bind was NEVER attempted -- no userland on g4ad yet.

## STEP 3 -- measurement: NOT RUN. No /dev/dri/card0 -> no solnix V520 tok/s. Nothing fabricated. Linux V520
baseline stands at 1995 pp / 283 tg.

## Net
solnix now BIOS-boots on the AMD/V520 g4ad (a real win -- the boot-block surgery + the cu_flags MSR fix are
durable, in the AMIs). The amdgpu measurement is blocked one layer earlier than the GPU: an AMD-specific
illumos userland fault (init SIGKILL loop) that needs a kmdb capture to pinpoint. So the GPU-parity path on
AMD is: fix the init-loop (2b) -> userland -> amdgpu C3 bind -> GGML_VULKAN -> the first solnix V520 number
vs Linux 1995/283. The NVIDIA path is blocked earlier still (no nouveau kernel driver at all).
