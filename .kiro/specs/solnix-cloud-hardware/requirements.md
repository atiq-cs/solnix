# solnix Cloud Hardware Enablement — Requirements

Make solnix **boot, run, and expose ALL hardware** presented by cloud instances
across AWS/EC2, Azure, and GCP — on every architecture solnix targets (x86_64,
aarch64, and later sparcv9/riscv64 where a cloud offers them). This spans two
layers: (1) the aarch64 **kernel port** to server-class ARM (GICv3 + ACPI + SBBR/
SystemReady-SR), without which NO ARM cloud instance boots; and (2) **device
driver** coverage for each cloud's virtualized + passthrough hardware (NICs,
storage, accelerators, RNG, IOMMU, timers, PCIe, etc.).

This is the deployment-target counterpart to the build-out: today solnix builds
packages by cross-compiling on amd64 and boot-tests aarch64 under QEMU virt
(GICv2/devicetree). To DEPLOY solnix as a first-class guest on real cloud metal/
Nitro/Hyper-V/KVM, the below is required.

## Motivation & scope

- **Booting is arch+firmware-gated.** x86_64 already boots on EC2 (proven). ARM
  cloud (Graviton, Azure Cobalt, GCP Axion) presents GICv3 + ACPI/SBBR — the
  illumos arm64 port does GICv2 + devicetree only, so it boots on NONE of them
  today. The kernel port below is the prerequisite for ALL ARM cloud work.
- **Hardware exposure is driver-gated.** Even where solnix boots (x86_64 EC2), we
  must enumerate + drive EVERY device the instance presents — not just NIC+disk,
  but RNG, IOMMU, PCIe hotplug, accelerators, enhanced networking, local NVMe,
  GPUs where present — so nothing is "present but unavailable".
- **All three clouds, all instance families.** AWS (Nitro: Intel/AMD/Graviton +
  accelerator instances Inf/Trn/G/P), Azure (Hyper-V + Cobalt ARM + ND/NC GPU),
  GCP (KVM/gVNIC + Axion ARM + A2/A3 GPU). Pairs with PS-7 (qualify ALL EC2 types).

## Requirements

- **R1 (ARM server kernel port):** illumos aarch64 boots on GICv3/GICv3-ITS +
  ACPI (SBBR) server-class ARM. Includes a GICv3 driver, an aarch64 ACPI parser +
  SBBR table handling, SystemReady-SR bringup, and the boot path (UEFI + ACPI, not
  u-boot+DTB). Done upstream-first (contribute to richlowe/arm64-gate + IPD 24).
- **R2 (boot on every cloud, every arch):** solnix boots to multi-user-server as a
  guest on: AWS EC2 (x86 done; Graviton after R1), Azure (x86 + Cobalt ARM), GCP
  (x86 + Axion ARM). Real instances, not just QEMU.
- **R3 (full device enumeration):** on each supported instance type, EVERY device
  the platform presents is enumerated and driven (or explicitly, knowingly
  stubbed) — verified by a per-instance-type device audit (prtconf/prtdiag/
  cfgadm clean; no "device present, no driver").
- **R4 (enhanced/perf hardware):** enhanced NICs (ENA v5/v6, gVNIC, Azure
  Accelerated Networking/MANA), local NVMe instance storage, SR-IOV/passthrough,
  IOMMU/SMMU, high-res timers, hardware RNG — all driven for performance parity.
- **R5 (accelerators):** GPU/accelerator instances (AWS G/P/Inf/Trn, Azure NC/ND,
  GCP A2/A3) — inventory + drive what is tractable (RNG/NVMe first; GPU/NPU is a
  major long-horizon port, coordinated with the AI/LLM track T3.3). Honest about
  what is out of reach near-term.
- **R6 (packaged + declarative):** every driver is packaged pkgs.solnix.* +
  cached + selectable via a NixOS-style hardware/cloud module (e.g.
  services.cloud.aws.enable) so an image for a given cloud/instance pulls the
  right driver set declaratively.
- **R7 (verified + regression-gated):** a boot+device-audit CI matrix per
  cloud×arch×instance-family (leveraging PS-7). Each qualified instance type is
  recorded with its device audit + a bootable image artifact.

## Non-goals (this spec)

- The x86_64 package build-out (separate). This is hardware/kernel/driver.
- Full GPU compute stacks (CUDA/ROCm userland) — that's T3.3 (AI/LLM); this spec
  covers the DRIVER/enumeration layer, handing off to T3.3 for the compute libs.
