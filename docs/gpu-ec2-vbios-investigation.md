# EC2 GPU (g4ad V520) vBIOS/POST investigation -- the honest scope answer

## Question
solnix's amdgpu binds the real V520 + /dev/dri exists, but the GPU is UNPOSTED (register fabric reads
0xffffffff -- docs/gpu2-v520-psp-mp0-wall-smn.md). Powering it up needs a vBIOS/ATOM POST. Is a vBIOS
GUEST-ACCESSIBLE on the g4ad -- i.e. is the EC2 GPU number reachable at all?

## Findings (measured on a Linux g4ad.xlarge, AL2023)
- The V520 is a **Display-class (0380) device**, NOT primary VGA (the Amazon 1d0f:1111 is the VGA). System
  firmware does not POST class-0380 secondaries.
- **NO guest-readable PCI option ROM** (/sys/bus/pci/devices/.../rom absent).
- **NO ACPI VFCT table** (the AMD "vBIOS-in-ACPI" fallback amdgpu uses when there's no PCI ROM -- absent;
  only DSDT + 2 SSDTs present).
- **NO EFI** (g4ad is legacy BIOS -- so no EFI GOP/vBIOS path either).
- **NO firmware-shipped vBIOS/ip_discovery blob** for navi12 in linux-firmware (the modern no-ROM path).
- BARs ARE mapped (256M VRAM aperture, 512K reg BAR) -- so the device decodes, it's just unclocked/unposted.
- Stock AL2023 (kernel 6.1) doesn't even ship amdgpu; the Linux BASELINE (1995/283) required a NEWER kernel
  (6.18) + modules-extra + the decompressed navi12 firmware (docs/GPU-PARITY-RESULTS.md) -- i.e. Linux ALSO
  had to actively bring up the GPU; the hypervisor did NOT hand it a POSTed card.

## Conclusion (honest)
There is NO vBIOS reachable via any standard guest path (PCI ROM / ACPI VFCT / EFI / shipped firmware) on the
g4ad. So the newer Linux amdgpu that DOES drive this card must obtain the ATOM/vBIOS image some other way --
most likely: it embeds/derives the POST from the IP-discovery table it reads over the (already-mapped) BAR,
and/or a newer amdgpu carries the navi12 vBIOS internally. That means:
- A solnix GPU number on g4ad IS potentially reachable, but ONLY by porting amdgpu's full ATOM/vBIOS-less
  POST + SMU power-on path (amdgpu_discovery + amdgpu_atombios + the SMU firmware bring-up) -- a LARGE driver
  effort (the ATOM interpreter + the discovery-table parse + the SMU power sequence), NOT a small register
  fix. The exact vBIOS SOURCE the newer amdgpu uses on this card must be confirmed by running the working
  6.18 amdgpu on g4ad + capturing its dmesg vBIOS-source line (a follow-up, on a 6.18 kernel).
- The CHEAPER path to a real solnix GPU number is a substrate where the GPU IS POSTed for the guest or
  exposes a vBIOS: a BARE-METAL AMD box, OR the Milk-V Jupiter's PowerVR on real silicon (the PowerVR stack
  is compile-complete; on real hardware the firmware/POST is the vendor's).

## Recommendation
EC2 g4ad GPU parity is NOT structurally impossible, but it's gated on porting amdgpu's ATOM/discovery POST
path (large) -- it is NOT a quick win. For a near-term real GPU number, real silicon (bare-metal AMD or the
Milk-V PowerVR) is the higher-leverage target. The g4ad amdgpu bind (compile + /dev/dri + register plumbing +
the sOS-fw_id fix) is real, banked progress that carries forward whenever the POST path is written.
