# solnix GPU/TPU compute-parity roadmap (the real goal: accelerator support at Linux parity)

## North star (sharpened)
solnix must provide **GPU / TPU / accelerator support as fast as Linux on the same
hardware**. CPU LLM inference (llama.cpp — done, 70 tok/s) is only a beachhead. The
real target is the full accelerated-compute stack: DRM/KMS → GBM/Mesa → **Vulkan
compute + vendor compute runtimes (CUDA / ROCm / oneAPI / NPU-TPU)** → the accelerated
LLM/ML backends. Desktop (COSMIC/Wayland) rides on the same DRM/GBM foundation but is
secondary to compute.

## The keystone: DRM/KMS is not just for desktop — it's the compute substrate
Every GPU compute path on Linux goes through DRM: CUDA (nvidia.ko/DRM), ROCm (amdgpu
DRM + KFD), Intel oneAPI (i915/xe DRM), Vulkan compute (DRM render nodes /dev/dri/renderD*).
So **G1 (illumos DRM/KMS, cribbed from NetBSD `external/bsd/drm2`) is THE compute
keystone**, not a desktop nicety. NetBSD already runs amdgpu/i915/nouveau/radeon DRM
drivers via its Linux-DRM compat shim on a BSD kernel — that is the proven crib for
illumos, the same pattern as the ena NIC (FreeBSD) and the RISC-V MD layer (NetBSD).

## "As fast as Linux" — what that demands (and the honest hard parts)
Linux's accelerator lead is mostly the **vendor kernel drivers + userspace runtimes**,
not the app layer. To match it:
- **DRM/KMS + per-GPU kernel drivers** (amdgpu/i915/xe/nouveau) — crib NetBSD drmkms;
  the GEM/TTM/dma-buf/scheduler plumbing is the bulk of the work.
- **Compute runtimes**: Vulkan (Mesa RADV/ANV/NVK — open, buildable once DRM lands),
  then the closed/heavy stacks: **ROCm** (amdgpu KFD ioctls — a big kernel surface),
  **CUDA** (nvidia's proprietary kernel module has no BSD/illumos port — the hardest;
  the open `nvidia-open` + NVK/Nouveau path is the realistic route), **oneAPI/Level-Zero**
  (Intel, open-ish).
- **TPU/NPU**: Google Coral/EdgeTPU (userspace + a kernel driver), other NPUs — each a
  driver port; most expose a PCIe/USB device + a userspace runtime.
- **dma-buf / heterogeneous memory / IOMMU** integration in the illumos VM.
REALITY: full CUDA parity is likely never (proprietary, Linux-only kernel module); the
achievable "Linux-parity" targets are **AMD (ROCm/amdgpu — fully open)**, **Intel
(oneAPI/xe — open)**, and **Vulkan-compute on all three** via Mesa. That is genuine
GPU-compute parity for the open stacks, which is where the industry + local-LLM tooling
(llama.cpp Vulkan, mlc, etc.) is heading anyway.

## Phased plan (compute-first ordering)

### C0 — CPU baseline (DONE)
llama.cpp CPU inference live (70 tok/s, OpenMP). ggml/BLAS CPU path. gfortran port in
flight (unlocks OpenBLAS → faster CPU BLAS + numpy/scipy).

### C1 — illumos DRM/KMS core (crib NetBSD drm2) [THE KEYSTONE]
Port the NetBSD `external/bsd/drm2` framework: drm core, KMS, **GEM + TTM + dma-buf**
(the buffer/memory objects compute needs), the drm scheduler, and the linux_* compat
shims (workqueue→taskq, dma-fence, reservation objects, mmu_notifier). Expose
`/dev/dri/card* + renderD*` + the drm ioctl ABI. First target: **QEMU virtio-gpu**
(virtio-gpu-drm — no real GPU, cheap CI) to prove the framework, then a real GPU family.
This is multi-quarter kernel work; break into C1a (drm core + GEM), C1b (KMS), C1c
(dma-buf + scheduler for compute).

### C2 — Mesa + GBM + Vulkan [gated on C1]
Mesa (Gallium + the Vulkan drivers RADV/ANV/NVK), GBM, EGL. **Vulkan compute** is the
first cross-vendor accelerated-compute win (llama.cpp/whisper.cpp have Vulkan backends).
lavapipe (CPU Vulkan) can precede C1 as a software Vulkan for API bring-up + testing.

### C3 — vendor compute runtimes [gated on C2, per-vendor]
- **AMD ROCm** (open): amdgpu DRM + KFD ioctl surface + the ROCm userspace (HIP/rocBLAS).
  The most tractable "real" GPU-compute parity target (fully open kernel + userspace).
- **Intel oneAPI / Level-Zero** (open-ish): xe/i915 DRM + Level-Zero + oneMKL.
- **NVIDIA**: NVK (Mesa open Vulkan) + nouveau/nvidia-open DRM — the only BSD-portable
  route; proprietary CUDA kernel module is Linux-only (document as out-of-reach).
- **TPU/NPU**: per-device driver ports (Coral EdgeTPU etc.) — case by case.

### C4 — accelerated ML/LLM backends [gated on C2/C3]
llama.cpp Vulkan backend (needs C2), then HIP/rocBLAS backend (C3-AMD), then the heavy
harnesses (PyTorch/vLLM need Python-C-ext + the compute runtime + often Rust/Go tooling).

## Parallel prerequisites (start now, they gate large swaths)
- **NetBSD-current source mirror** — the DRM crib reference (obtain + pin; net is reachable).
- **Rust toolchain on illumos** — gates NVK tooling, COSMIC, much modern ML/LLM tooling.
- **Go toolchain on illumos** — gates ollama + Go ML tools.
- **gfortran** (in flight) — OpenBLAS/LAPACK/numpy/scipy (the CPU numeric base under everything).
- **dma-buf + IOMMU** understanding in the illumos VM (design spike alongside C1).

## Honest framing for "as fast as Linux, as fast"
- The *app/runtime* layer (Mesa, Vulkan, ROCm userspace, llama.cpp) is portable C/C++ —
  buildable once the kernel DRM/compute ioctls exist; performance there tracks Linux closely.
- The *kernel driver* layer is the long pole: cribbing NetBSD drmkms gets the framework +
  the open drivers (amdgpu/i915/nouveau) — that's real GPU compute. It will lag Linux's
  newest-hardware enablement (Linux gets day-0 vendor drops) but can reach parity on
  established hardware for the open stacks. NVIDIA-proprietary/CUDA is the permanent gap;
  the open NVK/ROCm/oneAPI stacks are the parity targets.
- Sequencing: C1 (DRM keystone) is the gate. Everything accelerated waits on it. Start the
  NetBSD-drm2 port scaffolding NOW (C1a: drm core + GEM on virtio-gpu) in parallel with the
  breadth/toolchain work.
