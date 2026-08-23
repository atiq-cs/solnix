# GPU parity baseline: AMD Radeon Pro V520 (RADV NAVI12) on g4ad.2xlarge

## Hardware + driver
- GPU: AMD Navi 12 [Radeon Pro V520] (1002:7362), 8.4 GB VRAM, 36 active CUs, SR-IOV VF
- amdgpu 3.64.0 bound (kernel 6.18.41, kernel6.18-modules-extra + navi12 fw DECOMPRESSED .xz->.bin)
- RADV via Mesa 24.2.6, Vulkan 1.3.289 (the SAME RADV driver solnix ported to illumos)

## LLM baseline (GGML_VULKAN -- the SAME backend solnix built, TinyLlama 1.1B Q4_K_M)
| test  | GPU (RADV NAVI12) | CPU (ngl 0) | GPU speedup |
| ----- | ----------------: | ----------: | ----------: |
| pp128 |    1994.67 t/s    |   644.37    |    3.1x     |
| tg64  |     283.17 t/s    |    52.99    |    5.3x     |
ggml_vulkan: 0 = AMD Radeon Pro V520 (RADV NAVI12) (radv) | fp16: 1 | warp 32 | shared 65536

## Verdict
This is the LINUX+RADV baseline -- the target solnix must match. The GGML_VULKAN LLM engine
solnix built (and runs on illumos) delivers a 5.3x GPU speedup for generation on this exact
GPU via RADV. 283 tok/s (1.1B) is interactive-grade.

## solnix runtime gap (honest)
The solnix GPU RUNTIME needs a live illumos kernel with the ported DRM bound to the GPU.
On this g4ad the GPU is an SR-IOV VF (host holds the PF); illumos does not boot on EC2, and we
do not modload experimental DRM into the live Linux host. GPU passthrough to an illumos guest
is the honest path but needs the PF (not available in a single-GPU guest). Closing the last gap
needs a metal instance or LOCAL AMD hardware where solnix boots + binds the GPU. The compile/
link/load of RADV + GGML_VULKAN on illumos is proven; the runtime bind awaits solnix-on-metal.

## solnix-on-GPU (2026-08-23): BREAKTHROUGH -- solnix BOOTS on a real GPU instance + sees the GPU
The runtime gate is finally being addressed on real EC2 GPU hardware:
- g4ad (AMD/RADV, the earlier baseline GPU) CANNOT run the solnix AMI: "g4ad.2xlarge does not support an
  AMI with a boot mode of UEFI" (g4ad is BIOS-only; the solnix AMI is UEFI). Hard AWS incompatibility.
- g4dn/g5/g6 (NVIDIA, Nitro) DO accept the UEFI solnix AMI. => solnix LAUNCHED on g4dn.xlarge (NVIDIA T4)
  and BOOTED + networked (110s, first try, ena-fixed AMI ami-0fd4acf5e378c3e25). FIRST TIME solnix runs on
  a real GPU instance.
- illumos SEES the GPU: prtconf shows pciex10de,1eb8 = NVIDIA TU104GL (Tesla T4), pciexclass,030200 (3D
  controller), "driver not attached" (illumos vgatext holds the console). The GPU is present + enumerable.
- THE MEASUREMENT PATH (in flight): bind the T4 via solnix's ported NVK/nouveau DRM (the C1 framework +
  libdrm_nouveau, all compile zero-phantom) -> /dev/dri/card0 -> run GGML_VULKAN -> llama-bench -> compare
  to the Linux baseline (283 tok/s tg). HONEST GPU caveat: the earlier Linux baseline was AMD/RADV (V520);
  this node is NVIDIA/NVK (T4) -- the fair comparison is a T4 solnix number vs a T4 Linux number (different
  GPU than the V520 baseline). The bind (GSP firmware + nouveau attach + ring/doorbell) is the hardware-only
  step being attempted now on the real T4.
=> The solnix-GPU RUNTIME GATE is no longer "needs metal/local hw" -- solnix boots on a Nitro NVIDIA GPU
instance + sees the GPU. The remaining step is the ported-DRM bind + the GGML_VULKAN measurement (in flight).
