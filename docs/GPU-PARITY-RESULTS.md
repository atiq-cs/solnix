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
