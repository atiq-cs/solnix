# arnold: install solnix on the Ampere RTX 3080 Ti machine (dual-boot, keep Fedora)

Status: PLAN (read-only facts gathered; no changes made to arnold). Maintainer runs
the privileged + physical steps (sudo needs a password; drive install is physical).

## Why arnold
- arnold = ThinkPad X1 Extreme Gen 5 (21DE001EUS), i9-12900H, 30 GiB RAM.
- iGPU: Intel Alder Lake-P Iris Xe (8086:46a6). dGPU: NVIDIA GA103M RTX 3080 Ti
  Mobile (10de:2420) = AMPERE = Turing+ = SUPPORTED by src/drm-port/nvidia-oss
  (whose MIT display/KMS/i2c path compiles 34/34 clean against our illumos headers).
- This is the FIRST machine where the NVIDIA driver can go from "compiles" to
  "attaches/runs" -- dixi's Pascal GTX 1050 Ti never can.

## Verified hardware facts (live, 2026-10-11)
- Boot: UEFI, Secure Boot DISABLED (illumos loader needs SB off -- good, no change needed).
- Storage: ONE M.2 populated = nvme0n1 WD SN810 1.9TB, ENTIRELY Fedora
  (p1 600M EFI vfat /boot/efi, p2 1G ext4 /boot, p3 1.9T btrfs /home, 1.2T free).
- X1 Extreme Gen5 has TWO M.2 2280 slots; only one controller is present ->
  slot 2 is almost certainly EMPTY (confirm physically / `dmidecode -t slot`).
- sudo needs a password -> maintainer runs privileged steps.

## Strategy: install to a SECOND M.2 drive, dual-boot. Do NOT wipe Fedora.
Reasons: Fedora is a useful reference Linux (compare GPU/driver behavior); the
single drive is full of Fedora with no spare partition; a second drive is the
clean, reversible path. Options for the second drive:
  (A) a fresh M.2 2280 NVMe (preferred -- nothing to lose), OR
  (B) dixi's current 1TB drive -- but that takes dixi DOWN; only if you want to
      retire dixi. Recommend (A): keep dixi as the reliable solnix box.

## Install steps (maintainer-run; the agent/orchestrator prepares + verifies)
1. PHYSICAL: power off arnold, install the second M.2 drive in the free slot, boot.
   Confirm Fedora still boots (slot 1 untouched) and the new drive enumerates
   (lsblk shows a second nvmeXn1, empty).
2. MEDIA: write the TUI developer-preview image (being built now by stream
   da068370) to a USB stick. (Until it's published, the last good image is
   artifacts/install-media/usb-image-20261009c-x1.) Boot arnold from USB
   (F12 boot menu; UEFI; SB already off).
3. INSTALL to the SECOND drive ONLY (scripts/solnix-install). Target the new
   nvmeXn1, NEVER nvme0 (Fedora). Create rpool on the second drive; the installer
   lays the BE + EFI. The X1-install flow is in docs/install-x1.md -- adapt the
   target disk; the X1 Extreme Gen5 specifics vs Gen1 (dixi): Alder Lake iGPU
   (Iris Xe, not UHD 630), Ampere dGPU, likely a different NVMe model + the AX2xx
   wifi (iwm/iwx coverage differs -- see below).
4. UEFI dual-boot: the solnix EFI entry + Fedora's coexist in NVRAM; pick at boot
   via the firmware boot menu, or add a loader entry. (Keep it simple: firmware
   boot-menu selection first; a unified bootloader entry later.)
5. FIRST BOOT: verify solnix boots on arnold's hardware (fresh install => correct
   path_to_inst for Alder Lake; no cloned-device-path problem).

## What works / what's new on arnold vs dixi
- Build capability: a fresh solnix install + the seedBuildTools default (0ba9a6f)
  = a full build/upstream host, SAME as dixi would be. GPU is irrelevant to builds.
- GPU graphics: near-term = SOFTWARE (lavapipe/smallvil/COSMIC apps), same as the
  X1. Hardware accel: iGPU Iris Xe via ANV/i915-KMS (C1 work); dGPU Ampere via
  src/drm-port/nvidia-oss (MIT path compiles clean -- the one-line thread_splitstack
  extern + the FOD'd RM src/ + this hardware = the first real NVIDIA attach attempt).
- Wifi: arnold's is 8086:51f0 = Alder Lake-P CNVi Wi-Fi (AX211). GOOD NEWS: this
  exact device id IS already in our iwx tree (src/ports/wifi/iwx/compat/dev/pci/
  pcidevs.h, PCI_PRODUCT_INTEL_WL_22500_11 = 0x51f0, AX211). So it is a KNOWN
  device; what remains is the iwx driver's own maturity vs the fully-proven
  iwm/AC-9560 path (iwm is the hardware-proven one; iwx is the newer-silicon
  sibling). A CNVi integrated radio differs from a discrete AX200 at the bus
  layer -- validate iwx attach on arnold as a follow-on; not an install blocker.

## NVIDIA bring-up on arnold (the payoff, staged, after solnix boots)
- Stage 0: fetch the FOD RM src/ (pin 8da2326) + apply the one-line thread_splitstack
  extern; `gmake modules` to build nvidia.kmod (MIT: nvidia+modeset+i2c).
- Stage 1: load the module (boot-once BE + deadman + dump armed, operator present --
  same discipline as i915 on dixi), open /dev/nvidiactl, confirm attach on the
  Ampere. This is the FIRST hardware test of the vendor-open-kernel-module path.
- CUDA/UVM: opt-in (nvidia-oss-cuda, GPLv2-gated) -- later, needs the thread_splitstack
  runtime resolution too.

## Safety (same discipline as dixi)
- Install to the SECOND drive only; nvme0 (Fedora) is never a target.
- Risky boot-time GPU changes go in a boot-once BE, never the default (the i915
  boot-loop lesson). deadman-arm before any module attach that could hard-hang.
- A fresh install can't net-wedge Fedora; the two OSes are independent on separate
  drives.

## Open items before/at install
- Confirm slot 2 is physically free (maintainer, at the machine).
- The TUI image must finish publishing (stream da068370) OR use usb-image-20261009c-x1.
- AX211 wifi: device id 0x51f0 is already known to iwx; validate the iwx driver
  attach on arnold's CNVi radio as a follow-on (non-blocking).
