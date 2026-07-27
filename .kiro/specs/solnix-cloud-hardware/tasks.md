# solnix Cloud Hardware Enablement — Tasks

Boot + run + expose ALL hardware on AWS/EC2, Azure, GCP across architectures.
Prereq for ARM clouds = the kernel port (CH-1). Driver work = CH-2..CH-8.
Upstream-first where it's an illumos-gate/arm64-gate change (contribute, don't fork).
Pairs with PS-7 (qualify all EC2 types), T3.2 (guest drivers), T3.3 (AI/GPU compute).

## CH-1 — ARM server-class kernel port (GICv3 + ACPI + SystemReady-SR)

THE prerequisite for every ARM cloud instance (Graviton, Azure Cobalt, GCP Axion).
The illumos arm64 port (richlowe/arm64-gate, IPD 24) does GICv2 + devicetree (EBBR)
only; cloud ARM presents GICv3/GICv3-ITS + ACPI (SBBR). Multi-month; upstream-first.
- **CH-1a GICv3/GICv3-ITS driver:** interrupt controller for server ARM — distributor/
  redistributor, LPIs/ITS (MSI), CPU interface (ICC sysreg). Model on the Linux/
  illumos GICv2 driver + the GICv3 arch spec. The single biggest kernel piece.
- **CH-1b aarch64 ACPI parser + SBBR:** the port targets devicetree; add ACPI table
  parsing (MADT/GTDT/DSDT/MCFG/SPCR/IORT) for server ARM. illumos x86 HAS ACPICA —
  evaluate reusing ACPICA on aarch64 vs a fresh parser. Wire MADT->GICv3, GTDT->
  timer, MCFG->PCIe, IORT->SMMU, SPCR->console.
- **CH-1c SystemReady-SR boot path:** UEFI + ACPI boot (not u-boot+DTB). EFI stub/
  loader entry, ACPI handoff, EFI memory map, RSDP discovery. Get to krtld+genunix
  under SBBR firmware (EDK2/AAVMF locally, then Nitro/Hyper-V/KVM ARM).
- **CH-1d SMMUv3 (IOMMU) driver:** server ARM DMA remapping (IORT-described) — for
  passthrough/SR-IOV + DMA safety.
- **CH-1e generic timer + PPI/SPI plumbing** under GICv3; PSCI CPU_ON SMP bringup
  on GICv3 redistributors.
- **Method:** develop against QEMU `-machine virt,gic-version=3 -bios AAVMF` +
  SBSA-ref first (server-class emulation), then real Graviton. Upstream to
  arm64-gate; track IPD 24 alignment.
- **Gate:** aarch64 illumos boots to multi-user-server under QEMU SBSA/virt-gicv3
  + AAVMF ACPI, then on a real Graviton instance. Contribute the drivers upstream.

## CH-2 — AWS EC2 / Nitro: full hardware (x86_64 + aarch64)

Every device a Nitro instance presents, all families.
- **NICs:** ENA (have) + ENA v5/v6 (gate fix 17939), ENA Express (SRD), EFA
  (elastic fabric adapter — HPC/ML RDMA) — inventory + drive.
- **Storage:** NVMe (EBS + instance-store local NVMe), the Nitro NVMe variants,
  multi-queue. **RNG:** the Nitro/virtio RNG. **PCIe:** Nitro PCIe topology,
  hotplug. **IOMMU:** Nitro vIOMMU. **Timers/PMU.**
- **Metadata/lifecycle:** IMDSv2 (org-enforced) fully in-kernel/agent, hibernation,
  live-migration events where applicable.
- **After CH-1:** the same on Graviton (aarch64 Nitro).
- **Gate:** on each EC2 family (general/compute/memory/storage/accelerator, x86 AND
  Graviton), device audit clean; enhanced networking + local NVMe at expected perf.

## CH-3 — Microsoft Azure: full hardware (x86_64 + Cobalt ARM)

Azure = Hyper-V. This is likely the largest driver gap (illumos Hyper-V support
is thin).
- **Hyper-V core:** VMBus, `hv_*` — netvsc (NIC), storvsc (storage), the Hyper-V
  timer/clock, KVP/heartbeat/shutdown integration services, PCIe passthrough (vPCI).
- **Accelerated Networking:** MANA (Microsoft Azure Network Adapter) + the older
  Mellanox/mlx SR-IOV VF path. **Storage:** NVMe direct + storvsc.
- **Cobalt 100 (Azure ARM):** after CH-1 (GICv3/ACPI) — Azure ARM SBBR firmware.
- **Boot:** Azure Gen2 UEFI, the Azure agent (waagent analog) for provisioning.
- **Gate:** solnix boots + networks (accelerated) as an Azure VM (x86 Gen2; Cobalt
  ARM after CH-1); VMBus device audit clean.

## CH-4 — Google Cloud (GCP): full hardware (x86_64 + Axion ARM)

GCP = KVM-based.
- **NICs:** virtio-net + **gVNIC** (Google's high-perf NIC) + IDPF (the newer
  Intel/Google infra data-path). **Storage:** virtio-scsi, NVMe (Local SSD +
  Persistent/Hyperdisk), virtio-blk. **RNG:** virtio-rng. **PCIe/IOMMU:** virtio-iommu.
- **Axion (GCP ARM):** after CH-1 — GCP ARM SBBR/UEFI.
- **Boot:** GCP UEFI + the guest environment (google-guest-agent analog, OS Login,
  metadata server).
- **Gate:** solnix boots + networks (gVNIC) as a GCE instance (x86; Axion after
  CH-1); virtio + gVNIC device audit clean.

## CH-5 — Accelerators (GPU/NPU) driver layer

The device/enumeration layer for accelerator instances (compute libs = T3.3).
- Inventory per cloud: AWS G/P (NVIDIA), Inf/Trn (Inferentia/Trainium), Azure NC/ND
  (NVIDIA), GCP A2/A3 (NVIDIA) + TPU. What does the guest even SEE (PCIe BDF, BARs)?
- **Tractable first:** enumerate the PCIe device + its RNG/NVMe siblings; basic
  BAR mapping. **Hard/long-horizon (honest):** the actual GPU/NPU driver + firmware
  — NVIDIA (no illumos driver), Inferentia/Trainium/TPU (proprietary). Flag as a
  major port; coordinate with T3.3 (which does CPU inference first).
- **Gate:** accelerator instances boot + enumerate the accelerator PCIe device
  (even if compute-unusable initially); documented reality of what's drivable.

## CH-6 — Declarative cloud/hardware modules

- NixOS-style modules: `services.cloud.<aws|azure|gcp>.enable`, hardware profiles
  per instance family, so an image for a target cloud/instance pulls exactly the
  right driver + agent set declaratively. Mirror nixpkgs' `profiles/qemu-guest`,
  `amazon-image`, `azure-image`, `google-compute-image`.
- Per-cloud image builders (like the x86 boot-AMI/make-be flow) producing bootable
  images per cloud×arch.
- **Gate:** `solnix build .#images.aws-graviton` (etc.) emits a bootable image with
  the correct driver closure.

## CH-7 — Per-instance-type device-audit CI matrix

- Extend PS-7: for each cloud×arch×instance-family, boot the image + run a device
  audit (prtconf/prtdiag/cfgadm/dladm) + a perf smoke (network throughput, disk
  IOPS). Record pass + the audit + a bootable-image artifact per qualified type.
- **Gate:** a living matrix (AWS/Azure/GCP × x86_64/aarch64 × families) of
  boots-clean / device-complete / perf-ok, gating regressions.

## CH-8 — Upstream collaboration

- CH-1 (GICv3/ACPI/SBBR), Hyper-V (CH-3), gVNIC (CH-4) are illumos-gate/arm64-gate
  contributions, not solnix forks. Coordinate with Rich Lowe (arm64-gate/IPD 24)
  and illumos-hackers; land drivers upstream so solnix consumes them + the whole
  illumos community benefits. Track submitted/merged status here.

## Sequencing

CH-1 (ARM kernel port) is the long pole + prereq for all ARM cloud work — start
its QEMU-SBSA development early, in parallel with x86 driver work (CH-2 x86,
CH-3 x86 Hyper-V, CH-4 x86 gVNIC) which needs no kernel port. Accelerators (CH-5)
and full ARM-cloud (CH-2/3/4 aarch64) follow CH-1. CH-6/7 productionize; CH-8 runs
throughout. This is a MAJOR multi-quarter effort — largely post-stable, but the
x86 driver pieces (Azure Hyper-V, GCP gVNIC) can start now to make solnix a
first-class guest on Azure/GCP x86 before the ARM port lands.

## CH-0 (build-infra, do EARLY) — harden builder-AMI first boot

NOT a deploy target — a BUILD-FLEET reliability fix, but it belongs with the
cloud-hardware/Nitro work. Observed: 37-60% of freshly-launched builders come up
port-22-dead with ENA DHCP "Cannot assign requested address" at boot (Nitro ENA/
DHCP race + OI metadata-agent IMDSv1 hang). Cost: wasted instances every wave +
throughput loss (wave 14 got 4/16). FIX: rebuild the builder AMI with (a) the
metadata-shim baked into first-boot SMF (not added post-boot), (b) an ENA/dlmgmtd/
DHCP ordering + retry (dladm/ipadm settle loop before sshd), (c) a first-boot
health gate. Target: >90% first-boot SSH success. Interim workaround (works):
launch +40%, reap dead, count SSH-able as capacity. Do this EARLY — it compounds.
