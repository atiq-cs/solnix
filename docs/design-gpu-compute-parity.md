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

## C1b DONE (2026-08-13): virtio-gpu path compiles — GEM mmap + shims + SET_SCANOUT
The full virtio-gpu 2D path compiles as one ET_REL/EM_AMD64 illumos kernel object (`drm`):
- GEM real page backing: ddi_umem_alloc(9F) + cb_devmap/devmap_umem_setup(9F) -> userland mmap of a
  GEM handle faults in real pages.
- linux-compat shim primitives: workqueue->ddi_taskq, kthread->thread_create, completion->kcondvar_t,
  rwsem->krwlock_t (kref/idr/mutex/kmem from C1a). NetBSD linux_work.c/linux_kthread.c/completion.h/
  linux_rwsem.c used as the API checklist, mapped to illumos primitives.
- virtio-gpu attach + GET_DISPLAY_INFO over the REAL illumos virtio framework KPI (same KPI vioif/vioblk
  use; every virtio_* undef confirmed in /kernel/misc/amd64/virtio's exports, zero phantom).
- SET_SCANOUT modeset: full RESOURCE_CREATE_2D->ATTACH_BACKING->SET_SCANOUT->TRANSFER_TO_HOST_2D->
  RESOURCE_FLUSH chain. wire protocol cribbed verbatim from Linux/QEMU virtio_gpu.h (BSD-licensed);
  command flow follows Linux virtgpu_vq.c + NetBSD, re-expressed on the illumos virtio KPI (no .c lifted).
QEMU boot NOT reached: the EC2 build node is non-metal (TCG-only, no /dev/kvm) -> full illumos guest
boot under TCG is prohibitively slow. Verified the symbol boundary STATICALLY instead (all virtio_*
present in kernel exports). Stayed off the live kernel (panic risk on a device-less driver). A metal
instance (or local hardware) is needed for the runtime scanout proof.
Committed: src/drm-port/{src/*.c,*.h, virtio_gpu*, linux-compat, uapi, test/test_c1b.c}. ~1496 LOC.
NEXT C1c: dma-fence (cv-backed) + dma-resv/ww_mutex + dma-buf fd-sharing (the hard illumos gap) +
sync_file + drm scheduler -> gates C2 (Mesa/GBM/Vulkan). Also C1b runtime proof needs a metal instance.

## C1c DONE (2026-08-13): DRM compile-phase COMPLETE -> C2 (Mesa/Vulkan) unblockable
All C1c primitives compile in the single ET_REL/AMD64 `drm` object; 95 undef syms all real illumos KPI
(genunix/specfs/unix/virtio), ZERO phantom (no dma_buf_*/linux_*/anon_inode/kmalloc):
- dma-fence: init/signal/wait/callbacks over kref+kmutex+kcondvar+atomic flags (NetBSD linux_dma_fence.c
  semantics, RCU dropped -> readers take the lock).
- ww_mutex + dma-resv: real wound/wait (global ticket per acquire-ctx, -EDEADLK + lock_slow retry);
  dma_resv = ww_mutex + excl fence + growable shared array.
- drm scheduler: single FIFO run-queue + one worker kthread; each job carries a finished dma_fence.
- **dma-buf-fd / PRIME (the load-bearing design, DESIGN.md §D.1)**: illumos has no anon-file dma_buf,
  but falloc(9F) (fd over a vnode) + makespecvp() (spec-vnode over a dev_t routing to our cb_ops)
  compose into it. The solnix PRIME fd = falloc'd fd whose f_vnode is a spec-vnode over THIS drm
  device's char node at a private per-export minor (>= DRM_PRIME_MINOR_BASE) encoding the GEM handle.
  -> passes cross-process via SCM_RIGHTS; mmap(fd) faults through the C1b cb_devmap onto the GEM
  ddi_umem pages; FD_TO_HANDLE reverses via getf->f_vnode->getminor->export->object. The
  DRM_IOCTL_PRIME_HANDLE_TO_FD/FD_TO_HANDLE UAPI is the REAL Linux DRM contract -> libdrm/GBM/Mesa
  unchanged. sync_file reuses the same fd mechanism.
=> **C2 (Mesa/GBM/Vulkan) is unblockable at the compile/ABI level**: C1c is the exact synchronization +
buffer-sharing surface Mesa builds on, it compiles against real illumos KPI, and the DRM UAPI (incl
PRIME) is preserved. Committed src/drm-port/ (~3453 LOC total, C1a+C1b+C1c).
RUNTIME gaps (need a metal QEMU host, NOT compile-blocking): carve the PRIME/sync_file minors into a
real 2nd minor space + cb_close teardown; wire scheduler run_job->virtio_gpu_exec; sync_file poll(2)
via cb_chpoll+pollwakeup; C1b polish (virtio-PCI-child bind, devfsadm /dev/dri rule, completion-interrupt,
zero-copy scanout). NEXT: C2 Mesa bring-up (softpipe/llvmpipe first for API, then virtio-gpu Gallium) +
a metal instance for the C1 runtime proof.

## C2 REACHED: software OpenGL renders on illumos (Mesa 24.0.9 softpipe + OSMesa, NO GPU)
First GL on solnix. Mesa built as a standalone host build (native gcc-14 + a host-python venv meson
1.4.2 + samurai/ninja) and frozen with `nix-store --add`; host-free. The nixpkgs meson/ninja/python3
and LLVM derivations don't build through this fork (python3 -> libffi -> dejagnu -> expect wedges on
pty_termios.o; the same wedge blocks the X11 graph on a fresh v3 node), so the standalone-shell +
nix-store-add pattern (as the prior lavapipe node used) is the path.
- Config (the no-DRM software path): `-Dgallium-drivers=swrast -Dllvm=disabled -Dosmesa=true
  -Dplatforms= -Dglx=disabled -Degl=disabled -Dgbm=disabled -Ddri3=disabled`. swrast+llvm=disabled ==
  softpipe (pure C rasterizer, NO LLVM). OSMesa = offscreen GL to a CPU buffer (cleanest headless proof).
- Smoke: an OSMesa RGBA context renders a Gouraud triangle to a 256x256 memory buffer, reads pixels
  back -> GL_VERSION `3.3 (Compatibility Profile) Mesa 24.0.9`, GL_RENDERER `softpipe`, 16200 lit px.
  `OSMESA TRIANGLE SMOKE: PASS`. No GPU, no DRM, no X11, no LLVM.
- illumos source patches (upstreamable): (1) u_atomic.h gate the __sun Solaris-atomic backend on
  `!__GNUC__` so gcc-14 __atomic intrinsics are used (Solaris atomic.h predates p_atomic_read_relaxed);
  (2) u_thread.c add `!__sun` to the pthread_getcpuclockid guard (no per-thread CPU clock on illumos).
- illumos build fix (not a source patch): the host has a PARTIAL libdrm (xf86drm.h + libdrm.pc, no
  drm.h). Mesa's meson auto-detects it via pkg-config, defines HAVE_LIBDRM, and gallium aux
  (u_screen.c/renderonly.c) `#include <xf86drm.h>` -> missing drm.h. FIX: `PKG_CONFIG_LIBDIR=<shim-only>`
  so meson can't see the host libdrm.pc.
- Output: /nix/store/bgh83...-mesa-softpipe-24.0.9 {lib/libOSMesa.so*, lib/libglapi.so*, include/GL}.
  Published to cache.solnix.io. Recipe: artifacts/gpu-mesa-c2/{mesa.nix,build-mesa-softpipe.sh,osmesa_tri.c}.
- llvmpipe (stretch, deferred): same config with `-Dllvm=enabled -Dshared-llvm=disabled` + a hand-built
  static LLVM 18 (X86, RTTI/EH/PIC on). The prior lavapipe node already proved llvmpipe (LLVM 18.1.8) +
  lavapipe SW-Vulkan run on illumos (vulkaninfo DRIVER_ID_MESA_LLVMPIPE; llama.cpp Vulkan compute OK).
  softpipe was taken first because it needs no multi-hour LLVM build and still proves the rasterizer.
- xlib-GLX libGL.so (deferred): needs the X11 graph, which is blocked on this node by the same python3
  pty.h wedge; OSMesa already proves software GL, so this second flavor was not rebuilt via standalone
  scripts.
- GBM / real-GPU (C2-stretch): `-Dgbm=enabled` needs libdrm (the C1 UAPI drm.h under
  src/drm-port/src/uapi/drm/ satisfies the ABI) AND a runtime /dev/dri device. This non-metal node has
  no DRM device, so GBM belongs on a metal instance running the C1 kernel module.

## C2 MILESTONE (2026-08-13): first GL on solnix — Mesa softpipe + OSMesa
Mesa 24.0.9 softpipe (pure-C rasterizer, NO LLVM) + OSMesa built for x86_64-solaris, host-free
(libOSMesa.so runs with no LD_LIBRARY_PATH, resolves via store RUNPATH). GL SMOKE PASS: OSMesa offscreen
RGBA context rendered a Gouraud triangle to a 256x256 CPU buffer -> GL_VERSION "3.3 Mesa 24.0.9",
GL_RENDERER softpipe, 16200 lit pixels read back. Software GL on illumos, no GPU/DRM/X11/LLVM.
meson config (no-DRM software path): -Dgallium-drivers=swrast -Dllvm=disabled -Dosmesa=true
-Dplatforms= -Dglx=disabled -Degl=disabled -Dgbm=disabled -Ddri3=disabled -Dopengl=true
-Dshared-glapi=enabled. illumos fixes: PKG_CONFIG_LIBDIR to hide the host's partial libdrm (no drm.h);
u_atomic.h gate __sun backend on !__GNUC__ (use gcc __atomic intrinsics); u_thread.c !__sun on
pthread_getcpuclockid. Recipe: solnix-pkgs mesa-softpipe.nix. Published.
NOTE: the prior lavapipe node ALREADY proved llvmpipe (LLVM 18.1.8) + lavapipe SOFTWARE-VULKAN run on
illumos -> software Vulkan is validated too. So the software GL+Vulkan stack works on illumos CPU NOW
(unblocks gtk4-GL + CPU-Vulkan compute like llama.cpp's Vulkan backend for API bring-up).
GBM (real-GPU bridge) needs a runtime /dev/dri device (the C1 kernel module on a metal instance).
NEXT: llvmpipe/lavapipe as real derivations (faster SW GL/Vulkan); GBM + the C1 runtime on metal;
then hardware Gallium drivers (C3).

## C1d DONE (2026-08-14): accelerated virtio-gpu path COMPILE-COMPLETE (kernel + userspace)
C1d closes the last KERNEL gap for accelerated GPU. All 10 DRM_IOCTL_VIRTGPU_* wired, `drm` object
still ET_REL/AMD64 (96 undef syms all real illumos KPI or virtio exports, zero phantom):
- EXECBUFFER: copyin virgl/venus command stream -> drm_sched_job whose run_job ships SUBMIT_3D ->
  drm_sched_entity_push_job -> finished C1c dma-fence is the out-fence (wrapped in a C1c sync_file fd);
  in-fence waited first. THIS wires the C1c scheduler run_job -> virtio submission (the step C1c named).
- CTX_CREATE/DESTROY (CONTEXT_INIT parses CAPSET_ID = virgl vs venus), RESOURCE_CREATE_3D (GEM +
  ATTACH_BACKING + CTX_ATTACH), GET_CAPS/GETPARAM (capset blobs Mesa queries), TRANSFER_3D + MAP
  (reuses C1b cb_devmap) + WAIT. Cribbed 3D wire structs + DRM UAPI verbatim from Linux virtio_gpu.h +
  virtgpu_drm.h (so Mesa binds unchanged); flow from virtgpu_vq.c/virtgpu_ioctl.c re-expressed on the
  illumos virtio KPI + C1c scheduler/fence/sync_file. DRM port ~4917 LOC total (C1a-d).
=> STACK STATUS: with C3a's built virgl + Venus Vulkan ICD, the C1+C2+C3a stack is COMPILE-COMPLETE for
accelerated virtio-gpu on illumos -- the host's GPU renders via QEMU -device virtio-gpu-gl +
virglrenderer, through the C1 DRM + Mesa virgl/venus. PENDING ONLY THE METAL RUNTIME PROOF (QEMU+KVM+
host-GPU; build nodes are TCG-only). The metal DRM-runtime agent is proving C1a-c 2D; C1d 3D + a
GPU-having QEMU host is the accelerated proof.
C1d ceilings (runtime, noted in-code): one 3D ctx/device (-> per-drm_file); SUBMIT_3D synchronous under
the FIFO scheduler (-> async hw-fence + completion interrupt); per-BO dma_resv fencing; zero-copy 3D
transfers over the GEM umem cookie. All runtime upgrades, not compile-blocking.
NEXT: metal runtime (C1a-c 2D lit, then C1d 3D on a GPU host); then llama.cpp GGML_VULKAN over Venus =
accelerated LLM. amdgpu (real-hw ROCm) is the C3 tail.

## C4 DONE (2026-08-14): llama.cpp GGML_VULKAN compile-complete + loader->ICD dispatch proven
llama.cpp b4991 built -DGGML_VULKAN=ON for x86_64-solaris: libggml-vulkan.so (exports ggml_backend_vk_*,
NEEDED libvulkan.so.1), vulkan-shaders-gen ran (SPIR-V embedded), 55 host-free bins. Deps: Vulkan-Headers
1.3.280, Vulkan-Loader (libvulkan.so.1, illumos fixes: SunOS in the Unix branch, __sun in
COMMON_UNIX_PLATFORMS, getexecname for exe-path), glslang 14.3.0 (glslc->glslang shim, no shaderc).
RUNTIME PROOF (non-metal, no GPU): the C4 loader read the C3a Venus ICD manifest, dlopen'd
libvulkan_virtio.so, called vkCreateInstance -> -3 INITIALIZATION_FAILED (Venus needs /dev/dri/renderD*).
This PROVES the loader->ICD dispatch is wired end-to-end -- the only missing piece is a live DRM render
node (real GPU or the C1 runtime). CUDA-free; one build drives AMD/Intel/NVIDIA-via-NVK.
=> The ENTIRE GPU-compute-to-accelerated-LLM SOFTWARE CHAIN compiles on illumos: C1 DRM kernel -> C2/C3a
Mesa GL+Vulkan (virgl/Venus) -> C4 llama.cpp GGML_VULKAN. Pending only a live DRM render node on real hw.
NEXT (real GPU): EC2 GPU instances (g4dn/g5/g6 = NVIDIA T4/A10G/L4 via PCI passthrough to the VM guest --
NO metal/kvm needed, the GPU is directly on the instance). The C1 DRM + a real GPU driver (nouveau/NVK
for NVIDIA open path, or amdgpu on a g4ad AMD instance) binds the passthrough GPU. This is the real-GPU
runtime + parity target, reachable on regular (bootable) EC2 GPU instances.

## C3-amdgpu-c DONE (2026-08-14): amdgpu ring bring-up compiles -- driver compile-phase ~complete
navi12 reg-base (SOC15 reg_offset[hwip][inst] -> RREG32/WREG32 address each IP block), GMC/GART (512MB,
page-table BO from amdgpu_bo), GFX+SDMA amdgpu_ring_init (ring BO from amdgpu_bo GTT, rptr/wptr/doorbell/
fence-writeback, amdgpu_ring_write), IH ring skeleton. Wiring compiles end-to-end: amdgpu_transport_attach
-> amdgpu_ttm_init -> amdgpu_ip_blocks_init -> reg-base + wb + GMC + GFX/SDMA rings + IH. drm+amdgpu
ET_REL, 124 undefs all real illumos KPI, zero phantom. Cribbed navi12_ip_offset.h + navi12_reg_base_init
+ soc15_common + amdgpu_ring.c/ih.h/gart.c VERBATIM (register bases, no .c lifted). amdgpu ~2100 LOC.
=> The amdgpu real-GPU driver COMPILE-PHASE is essentially complete (device + memory/TTM + IP-blocks/
rings all compile). ONLY C3-amdgpu-d remains: firmware load (request_firmware navi12_*.bin) + PSP/SMU
power-up + live .hw_init register programming + rings wired to the C1 scheduler for live EXECBUFFER +
KFD -- and that NEEDS REAL HARDWARE (a g4ad instance, gated on GPU quota). So: the ENTIRE accelerated-GPU
stack (amdgpu kernel driver + C1 DRM + C2 Mesa + C3a Vulkan + C4 llama-Vulkan) compiles on illumos;
runtime bring-up (C3-amdgpu-d live) is the real-hardware phase on g4ad (GPU quota CASE_OPENED) or local
x86+GPU hw.

## C3-amdgpu-d DONE (2026-08-14): amdgpu driver COMPILE-PHASE COMPLETE
Firmware-load (amdgpu_ucode_load via illumos firmware(9F) firmware_open/get_size/read/close; validate
REJECTS truncated/OOB/foreign/v0 blobs before any byte reaches the GPU -- asserted off-hardware) +
hw_init sequences (psp_v11_0 auth/load, gmc_v10 gart_enable+TLB, gfx_v10 RLC+CP+ring, sdma_v5 ring;
real RREG32/WREG32 against the SOC15 model, poll-loops time out cleanly off-hw = never a false success)
+ EXECBUFFER->C1-scheduler wiring (amdgpu_job -> drm_sched -> amdgpu_ib_schedule -> PACKET3
INDIRECT_BUFFER ring_write -> doorbell). drm+amdgpu ET_REL, 128 undefs all real illumos KPI, zero
phantom. amdgpu ~2700 LOC (a/b/c/d). Firmware pkg: separate solnix amdgpu-firmware ships redistributable
linux-firmware navi12_*.bin (driver bundles no blob, license-clean; fetch-failure non-fatal).
=> THE ENTIRE ACCELERATED-GPU STACK NOW COMPILES ON ILLUMOS: amdgpu kernel driver (device+TTM+rings+
firmware+hw_init+EXECBUFFER) + C1 DRM + C2 Mesa GL + C3a Venus Vulkan + C4 llama.cpp-Vulkan. Nothing
left to COMPILE. 
HARDWARE-GATED RUNTIME CHECKLIST (g4ad/local GPU, ordered): 1.fw present 2.PSP sOS RUNNING 3.PSP fw
auth (biggest live unknown) 4.SMU ready 5.GMC gart+TLB+PTE-fill 6.GFX RLC+CP 7.SDMA idle 8.live
EXECBUFFER (ring rptr + fence writeback advance; needs the deferred BAR2 doorbell map) 9.IH interrupt
delivery. Skipped-until-powered-GPU: BAR2 doorbell map, per-page PTE-fill loop, IH IV-decode, KFD.
=> RUNTIME needs a real V520 (g4ad, gated on the GPU-quota support case PS-GPU-QUOTA) OR local x86+GPU hw.

## North-star restatement (2026-08-17, maintainer): accelerator parity, not CPU inference
The maintainer reaffirmed: CPU LLM inference (llama.cpp @70 tok/s) was only a BEACHHEAD. The long-term
goal is solnix providing GPU/TPU/accelerator support AS FAST AS LINUX on similar hardware. GPU support is
CRITICAL. Maintainer is requesting the GPU instance limit increase.

READINESS (what's done, non-hardware): the accelerated software stack is COMPILE-COMPLETE + zero-phantom
(src/drm-port ~9089 LOC): C1 DRM/KMS + C2 Mesa (softpipe/llvmpipe/lavapipe) + C3a virgl/Venus Vulkan ICD +
C3-amdgpu (device/TTM/navi12/rings/firmware) + C4 llama.cpp GGML_VULKAN. scripts/gpu-bringup.sh is the
one-command launch-to-runtime flow (refuses while quota=0; fires on the grant). The 9-step bring-up is
documented (design-gpu-amdgpu.md).

THE RUNTIME GATE (hardware-only): a real GPU that boots solnix = a GPU EC2 instance (g4ad: AMD V520,
fully-open amdgpu/ROCm, PCI-passthrough to a normally-booting Nitro VM -- NO metal/kvm needed) on the quota
grant, OR local x86+GPU hardware. Live register sequences (PSP fw-auth, ring rptr/fence, BAR2 doorbell, KFD)
are hardware-only -- never modload experimental kernel code into a live host kernel.

PARITY VECTORS (the plan, lead with the broadest):
- Vulkan-compute FIRST (the lead vector): one llama.cpp GGML_VULKAN reaches EVERY vendor once a DRM render
  node runs -- AMD (RADV/amdgpu), Intel (ANV/xe), NVIDIA (NVK, the open path). Broadest reach per unit work.
- ROCm/HIP (AMD) via amdgpu + KFD (/dev/kfd) -- the deepest AMD compute path; C3-amdgpu-d + the KFD char
  device (deferred A3-f). The g4ad V520 is the parity target.
- oneAPI/Level-Zero (Intel) via the xe DRM driver -- a future crib (same C1 DRM framework).
- TPU/other accelerators: most modern accelerators expose a DRM/accel char device + a userspace runtime;
  the C1 DRM framework + the dma-buf/PRIME + scheduler shape generalize. The Linux drivers/accel/ subsystem
  (Habana/etc.) is the crib reference when a specific TPU is targeted -- same crib-BSD/upstream-and-adapt
  doctrine.
NON-HARDWARE WORK THAT STILL ADVANCES PARITY (compile-verified, not runtime-gated): keep the Mesa/Vulkan
driver surface broadening (RADV for AMD, ANV for Intel -- both compile against the C1 DRM ioctls), the KFD
compute-ioctl surface, and the ROCm userspace runtime (HSA/ROCr) porting -- each a bounded first-step
compile with zero phantom symbols, exactly like every prior port. These land BEFORE the hardware so the
grant is instant-to-measurement.

## C3-RADV progress (2026-08-17): the real AMD Vulkan driver's wrapper layer compiled zero-phantom
Advancing GPU parity (the real AMD hardware Vulkan driver RADV, vs software lavapipe) -- compile-phase,
ahead of the g4ad hardware. Persisted src/drm-port/radv/ (286 LOC + RADV-STATUS.md):
- libdrm_amdgpu COMPILED (libdrm 2.4.120 -Damdgpu=enabled) against the C1/amdgpu ioctls, ZERO-PHANTOM
  (nm -u -D: 62 undefs all real -- 24 drm* via libdrm.so.2 NEEDED + 36 libc + 2 CRT). LOAD-BEARING FIX:
  the C1 drm-port decodes the LINUX _IOC ioctl scheme, not illumos <sys/ioccom.h>; libdrm falls into its
  BSD branch on __sun (incompatible encoding) -> forced the Linux encoding via radv/linux-ioctl-compat.h
  (8/8/14/2 nr/type/size/dir). PROVEN on-node (ioctl-encoding-test.c): AMDGPU_GEM_CREATE=0xc0086440,
  CS nr=0x44, INFO nr=0x45 dir=W -- the exact Linux DRM AMDGPU encoding the C1/amdgpu kernel decodes.
- RADV meson config SUCCEEDS (Mesa 24.0.9, -Dvulkan-drivers=amd,virtio, -Dllvm=disabled -> ACO no-LLVM),
  zero remaining dependency gaps; the ICD manifest (radeon_icd.x86_64.json, vk_icdGetInstanceProcAddr) is
  emitted by the build (loader->ICD contract, same shape as C3a Venus).
- REMAINING BLOCKER (build-tool, NOT a port gap): RADV's C objects need generated SPIR-V headers
  (bvh/*.spv.h, meta shaders) from a REAL glslangValidator. ⚠️ HONEST: the node currently has only a STUB
  glslangValidator ("Glslang Version: stub 11.0.0") -- NOT the real tool. So RADV's libvulkan_radeon.so is
  NOT yet compiled. RESUME STEP: build REAL glslang (needs cmake -- bootstrap cmake, then glslang, then the
  RADV core compile finishes). This is a host build-tool chain (cmake->glslang->RADV), not an illumos
  portability problem -- the port surface (libdrm_amdgpu + ioctl ABI + RADV config + ACO) is proven clean.
- Hardware-gated (g4ad/quota): real device enum, queue submit, draw -- the runtime measurement.
NEXT: build real glslang (cmake bootstrap) -> compile libvulkan_radeon.so -> zero-phantom .so audit -> wire
the ICD -> ready for the g4ad parity proof. RADV (the real AMD hw Vulkan path) is the driver that makes
GGML_VULKAN run FAST on the V520 (vs software lavapipe).

## C3-RADV COMPLETE (compile-phase) (2026-08-17): libvulkan_radeon.so -- the REAL AMD Vulkan driver on illumos
THE GPU-parity milestone (compile-phase, ahead of the g4ad hardware): the real AMD hardware Vulkan driver
RADV COMPILED for illumos x86_64. This is the FAST GGML_VULKAN path on the V520 (vs software lavapipe).
- REAL glslang 14.3.0 built (cmake 3.29.6 bootstrap -> KhronosGroup/glslang, ENABLE_OPT=0; replaced the
  stub). Verified: glslangValidator --version = 11:14.3.0, trivial .vert->.spv (664B, magic 0x07230203),
  the exact RADV bvh invocation emits SPIR-V C headers -- 19 .spv.h generated in-build (the gate the stub
  couldn't pass).
- libvulkan_radeon.so COMPILED: 16MB, 90 RADV objects (amdgpu winsys + device/queue/cmd_buffer/meta/nir/
  si_cmd_buffer/layers) + 30 ACO objects (the shader compiler, NO LLVM). RADV ~22.8k LOC + ACO ~14.7k LOC.
- 5 illumos compile breaks fixed crib-and-adapt (banked in the build scripts): libdrm drm.h shim install,
  alloca <alloca.h> guard (util/macros.h+aco_ir.h, root-cause), getpwuid_r 4-arg SunOS form, libsync.h
  _IOWR via linux-ioctl-compat.h (Linux _IOC matches the C1 kernel), int8_t!=signed-char -Werror relax.
- ZERO-PHANTOM AUDIT: 5326 WEAK undefs = same-.so Vulkan dispatch aliases (wsi_/vk_common_/radv_/layer
  trampolines + ACO TLS -- WEAK = intra-.so, not external); 336 GLOB undefs individually grepped against
  the union of NEEDED libs -> TRULY-UNRESOLVED = 0 (all resolve to libc/libdrm_amdgpu[->C1 ioctl path]/
  libdrm/libexpat/libstdc++/libm/libz/libgcc_s/libelf). Compile-verified proof (can't RUN without the GPU).
- ICD wired: radeon_icd.x86_64.json (api 1.3.274) + the .so exports vk_icdGetInstanceProcAddr +
  vk_icdGetPhysicalDeviceProcAddr + vk_icdNegotiateLoaderICDInterfaceVersion (the full loader contract).
COMPILE-COMPLETE: glslang + libdrm_amdgpu + RADV core + ACO + the .so + the ICD + the zero-phantom audit.
HARDWARE-GATED (g4ad V520 / quota): device enum, queue submit, draw -- the runtime parity measurement.
SO THE FULL AMD VULKAN STACK NOW COMPILES ON illumos: C1 DRM -> C3-amdgpu kernel driver -> libdrm_amdgpu
(zero-phantom, Linux _IOC ABI) -> RADV+ACO userspace driver (zero-phantom) -> the ICD -> the Vulkan loader
-> GGML_VULKAN. The instant the GPU quota grants, gpu-bringup.sh launches a g4ad + runs the amdgpu bring-up
+ this RADV .so + the accelerated GGML_VULKAN parity proof vs Linux. Persisted src/drm-port/radv/ (scripts +
audits + ICD + RADV-STATUS.md; the 16MB .so is gitignored, on the node).

## C4-ANV COMPLETE (compile-phase) (2026-08-17): libvulkan_intel.so -- BOTH open Vulkan drivers on illumos
Intel's ANV Vulkan driver COMPILED for illumos x86_64 (a fast follow-on -- reused the whole RADV toolchain:
glslang 14.3.0/meson/ninja/libdrm/Mesa + the 5 Mesa-wide illumos fixes). libvulkan_intel.so: 22MB, 266 ANV
objects + 16 genxml headers + 5 glslang shaders, ANV ~13.6k LOC. i915 AND xe DRM ioctls ported (xe=modern
Arc/Xe, i915=legacy) -- ANV needs NO libdrm_intel, it issues i915/xe ioctls directly via intel_ioctl()->
ioctl(); encoding proven to match the C1 kernel (DRM_IOCTL_XE_GEM_CREATE=0xc0386441, GEM_CLOSE=0x40086409,
identical to Linux). 2 ANV-specific fixes on top of the 5 RADV ones: the Linux _IOC ioctl shim (same as
RADV) + a portable futex fallback (illumos has no futex(2) -> pthread mutex+condvar in src/util/futex.c,
UTIL_FUTEX_SUPPORTED for __sun). ZERO-PHANTOM: 6357 WEAK (intra-.so Vulkan dispatch) + 254 GLOB all real
(libc incl ioctl, libdrm, libz, libstdc++/libgcc_s C++ ABI verified, libm) -> truly-unresolved = 0. ICD
wired: intel_icd.x86_64.json (api 1.3.274) + all 3 vk_icd* loader entrypoints. Compile-complete: device/
queue/cmd_buffer/allocator/pipeline/blorp/isl/brw-compiler/genxml/per-gen(90-200). Hardware-gated: real
Vulkan on Intel Arc/xe hw. Deferred: intel-clc/RT (LLVM), video, hasvk.
=> BOTH major OPEN Vulkan drivers now compile zero-phantom on illumos: RADV (AMD) + ANV (Intel). The
Vulkan-compute-reaches-every-vendor vector -- one GGML_VULKAN runs on either vendor's GPU once a DRM node
runs. The parity target g4ad is AMD (RADV); Intel Arc/xe (ANV) is ready if that hardware appears. NVIDIA's
open path (NVK) is the same Mesa/C1 shape -- a future follow-on. gpu-bringup.sh fires on the quota grant.

## C3-KFD COMPLETE (compile-phase) (2026-08-17): /dev/kfd -- the ROCm/HIP COMPUTE surface on illumos
The DEEPEST AMD compute path (beyond graphics Vulkan) now compiles zero-phantom on illumos. This is the
ROCm/HIP entry point -- accelerated compute (rocBLAS/the ML runtime), the truest "as fast as Linux" target.
- /dev/kfd = a 2nd minor node (KFD_MINOR=64) on the SAME illumos char device the C1 DRM core owns +
  C3-amdgpu attaches to. drm_core.c cb_ioctl routes by minor to kfd_ioctl; the DRI minors (card0/renderD128)
  stay on DRM dispatch -- mirroring Linux's distinct /dev/kfd + /dev/dri/renderD* over one amdgpu device.
- Core compute ioctls (verbatim Linux ABI, base 'K'): GET_VERSION, CREATE/DESTROY_QUEUE, GET_CLOCK_COUNTERS,
  GET_PROCESS_APERTURES(+_NEW), ACQUIRE_VM, ALLOC/FREE_MEMORY_OF_GPU, MAP/UNMAP_MEMORY_TO_GPU,
  SET_SCRATCH_BACKING_VA, AVAILABLE_MEMORY. Deferred (events/SVM/CRIU/debugger/dmabuf) return ENOTTY with
  the ABI numbers+structs present so handlers slot in.
- Compute-queue/doorbell: kfd_queue_create registers ring/ptr VAs + allocates a doorbell dword in the
  process's BAR2 page + returns queue_id/doorbell_offset. BAR2 (doorbell BAR) is now MAPPED by the
  C3-amdgpu attach (was unmapped). Per-process context keyed by illumos pid_t (ddi_get_pid).
- 1770 LOC KFD (+121 test). Memory alloc uses the REAL C3-amdgpu TTM amdgpu_bo_create.
- ZERO-PHANTOM: the full drm-full module links ET_REL AMD64 with 131 undefs, ALL resolve (verify-syms.sh:
  "all 131 undefined symbols resolve to illumos KPI or virtio exports") -- ddi_copyin/out, kmem_*, mutex_*,
  avl_*/list_*, cmn_err, gethrtime + intra-module amdgpu_bo_create/kfd_*. Self-check (test_kfd) PASS: the
  ABI encoding is bit-for-bit Linux, doorbell offset math, page-bitmap alloc/free, gfx10 aperture order.
Compile-complete: char device + ioctl dispatch + version/topology/apertures + acquire_vm + memory alloc/
free/map accounting + queue create/destroy + doorbell slot + per-process lifecycle. Hardware-gated
(C3-amdgpu-d, powered V520 + firmware): the live MQD write + HWS/MES runlist, GPUVM PTE program, the
doorbell BAR2 mmap fault, events/SVM.
ROCm USERSPACE NEXT: libhsakmt (the HSA thunk -- its hsaKmt* wrappers map 1:1 onto these AMDKFD_IOC_*; one
solnix gap: its topology reader assumes Linux /sys) -> ROCr (HSA runtime) -> HIP. Compute is now unblocked
at the kernel/ABI level exactly as RADV unblocked graphics-Vulkan.
=> THE FULL AMD ACCELERATOR STACK COMPILES ON illumos: graphics (C1 DRM + C3-amdgpu + RADV+ACO + ICD) AND
compute (/dev/kfd + the ROCm ioctl surface). Plus Intel graphics (ANV). The north-star software is
comprehensive; runtime is g4ad-gated. gpu-bringup.sh fires on the quota grant.

## ROCm userspace: libhsakmt COMPILES (compile-phase) (2026-08-17) -- the HSA thunk on illumos
The ROCm-userspace entry above the C3-KFD kernel driver: libhsakmt (ROCT-Thunk-Interface) COMPILES
zero-phantom on illumos x86_64. libhsakmt.so.1 (~217KB, valid ELF64 AMD64), 88 hsaKmt* exports (the FULL
thunk API: OpenKFD/GetVersion/CreateQueue/AllocMemory/MapMemoryToGPU/AcquireSystemProperties/
GetNodeProperties/CreateEvent/WaitOnEvent). 13,503 LOC upstream C + only 240 LOC solnix adaptation (5 header
shims + build + audit) + a 3-LINE delta to 2 shipped headers (libdrm->shim include, __linux__->
__linux__||__sun typedef guard) -- NO .c logic rewritten (clean crib-and-adapt). illumos adaptations: the
_IOC shim (reused from RADV/ANV/KFD -- same ABI as the C3-KFD kernel), alloca<->alloca.h, MADV_* hints->0
no-ops, a libnuma stub (numa_available==-1 -- correct illumos degradation), a perf_event.h stub. ZERO-PHANTOM:
59 undefs, 0 phantom (audit-undef.sh: "zero-phantom OK") -- all real libc (incl get_nprocs)/pthread/libdl/
libdrm_amdgpu (amdgpu_device_*, drmOpenRender)/crt. Compile-complete: the whole .so + all ABI wrappers + the
_IOC equivalence to C3-KFD. Runtime-gated: the /sys topology read at hsaKmtOpenKFD (the ONE functional gap
-- Option A recommended: the C3-KFD driver populates a solnix sysfs-shim dir, 5 path-macro changes, parser
intact; documented), + the doorbell mmap/live HWS/GPUVM (already g4ad/C3-amdgpu-d gates). ROCr NEXT: ROCR-
Runtime (libhsa-runtime64) dlopen's libhsakmt + needs OpenKFD/GetVersion/AcquireSystemProperties+
GetNodeProperties(<-the topology shim)/AllocMemory/MapMemory/CreateQueue+doorbell/CreateEvent -- ALL present
+exported. Then HIP + rocBLAS. => THE ROCm COMPUTE STACK ON illumos: C3-KFD kernel (/dev/kfd + ioctls) ->
libhsakmt (88 hsaKmt* exports) -> [ROCr -> HIP -> rocBLAS] (next). The accelerated-compute path is built
kernel + thunk; ROCr/HIP + the g4ad runtime remain. Persisted src/drm-port/rocm/.

## C5-ROCr COMPLETE (compile-phase) (2026-08-17): libhsa-runtime64.so -- the HSA RUNTIME on illumos
The HSA runtime (the layer HIP/rocBLAS/the ML runtime sit on) compiles zero-phantom on illumos.
libhsa-runtime64.so.1 (~1.4MB ET_DYN AMD64), ROCR-Runtime rocm-4.2.0 matched to the ROCT-Thunk 1.9.0 the
solnix libhsakmt came from. 37-unit HSA-runtime core (~24,747 LOC upstream), g++ 14, links against the
solnix libhsakmt.so.1. 239 exports / 186 hsa_* (init/agent/queue/signal/memory-pool/AQL/code-object-load --
everything HIP consumes). KEY: comgr/LLVM NOT NEEDED for the core -- ROCr's code-object loader is
libamdhsacode (its OWN libelf-based ELF reader, no LLVM); comgr/LLVM only enters at HIP's runtime JIT
(hiprtc). ZERO-PHANTOM: 281 undefs, 0 phantom (35 hsaKmt*->libhsakmt, 145 C++ ABI->libstdc++/libgcc_s,
~20 elf*/gelf*->libelf, pthread/dl/mmap->libc, sendfile->libsendfile). illumos adaptation: 200 LOC shims
(CLOCK_HIGHRES/<alloca.h>/limits) + a 47-line #ifdef __sun delta across 3 .cpp (sysinfo->sysconf,
CLOCK_MONOTONIC_RAW->CLOCK_HIGHRES, r_debug RT_* unscoped enums, __NR_gettid->pthread_self) -- NO compute
logic rewritten.
=> THE HIP/rocBLAS NEXT STEP + THE LLVM-AVOIDANCE INSIGHT: ROCr exports the full hsa_*/hsa_amd_* surface HIP
needs. The heavy dep (comgr/LLVM) is at HIP's RUNTIME JIT (hiprtc), NOT ROCr. FASTEST PATH TO ACCELERATED
COMPUTE: AOT PRECOMPILED .hsaco kernels -- GGML/rocBLAS SHIP precompiled Tensile kernels -> needs only ROCr's
loader (present) + HIP dispatch, NO runtime LLVM. Full hiprtc = a large future LLVM-for-illumos port
(deferred). So an accelerated GGML/rocBLAS workload can run via AOT kernels + ROCr, avoiding the LLVM port.
Compile-complete: the whole ROCr core + loader + the hsa_* surface. Hardware-gated: hsa_init topology (the
libhsakmt /sys shim, Option A), live AQL dispatch (doorbell/HWS), memory-pool->GPUVM, code-object ISA load
-- all g4ad/C3-amdgpu-d.
=> THE FULL ROCm COMPUTE STACK ON illumos: C3-KFD (/dev/kfd) -> libhsakmt (thunk) -> ROCr (HSA runtime) ->
[HIP dispatch + AOT .hsaco -> rocBLAS/GGML] (the AOT path avoids LLVM). Graphics (RADV/ANV) + compute (ROCm)
both compile zero-phantom; runtime is the single g4ad gate.

## C6-HIP COMPLETE (compile-phase) (2026-08-17): libamdhip64.so -- the ROCm userspace stack is COMPLETE on illumos
The accelerated-compute dispatch layer -- HIP (the CUDA-like runtime rocBLAS/GGML_HIP dispatch through) --
compiles zero-phantom on illumos. libamdhip64.so.5 (~8.9MB ET_DYN AMD64), 68 units (~42,269 LOC upstream
rocm-4.2.0 HIP+ROCclr), g++ 14, on the solnix ROCr + libhsakmt. 248 public hip* exports incl the WHOLE AOT
path: hipInit, hipMalloc/hipMemcpyHtoD/DtoH, hipStreamCreate, hipModuleLoad/GetFunction/LaunchKernel/Unload.
HIPRTC/LLVM/COMGR SKIPPED (the AOT-path insight): no LLVM/clang/comgr built or linked -- comgr is only
function-pointer typedefs ROCclr dlopen's at runtime (amd_comgr.h header only; audit: "amd_comgr link: 0").
AOT-DISPATCH LINK PROOF: hip-aot-dispatch-proof.cpp (a hipModuleLoad(.hsaco) + hipModuleLaunchKernel
vector-add) COMPILES + LINKS (26KB exe) against libamdhip64+ROCr+libhsakmt; ldd resolves the full chain; the
path hipModuleLoad -> hsa_executable_load_agent_code_object -> hipModuleLaunchKernel -> hsa AQL is wired
end-to-end. ZERO-PHANTOM: nm -pD 384 undef, 0 phantom (70 hsa_*->ROCr, 194 C++ ABI + 20 cxa/Unwind/TLS->
libstdc++/libgcc_s, 15 pthread, libc/libm/librt; 0 comgr, 0 LLVM). ~316 solnix-adaptation + 47 source-delta,
no compute logic rewritten. Compile-complete: HIP core + AOT dispatch chain + the 248-entry API. Hardware-
gated: hipInit agent enum (the /sys topology shim + powered V520), live AQL dispatch, hipMalloc->GPUVM,
.hsaco ISA load.
=> THE COMPLETE ROCm STACK ON illumos (all compile-verified zero-phantom): C3-KFD (/dev/kfd + ioctls) ->
libhsakmt (thunk, 88 hsaKmt*) -> ROCr (HSA runtime, 186 hsa_*) -> HIP (248 hip*, AOT dispatch). rocBLAS ships
precompiled Tensile .hsaco + GGML_HIP dispatches via HIP -> accelerated compute is reachable via the AOT
path with NO LLVM (the ROCm equivalent of GGML_VULKAN). => solnix now has, ALL COMPILING zero-phantom: AMD
graphics (C1 DRM+C3-amdgpu+libdrm_amdgpu+RADV+ACO+ICD) + AMD compute (the full ROCm stack) + Intel graphics
(ANV). The north-star accelerator software is COMPREHENSIVE; runtime is the single g4ad gate. gpu-bringup.sh
fires on the quota grant -> GGML_VULKAN (graphics) OR GGML_HIP+AOT (compute) parity vs Linux.

## C6-GGML_HIP verdict (2026-08-17): GGML_HIP kernels need LLVM -> GGML_VULKAN is THE LLVM-free accelerated path
DECISIVE honest finding that CLARIFIES the accelerated-compute strategy (+ corrects the earlier optimistic
"AOT avoids LLVM for GGML" framing -- AOT works for rocBLAS's Tensile kernels but NOT for GGML):
- GGML_HIP HARD-REQUIRES hipcc/LLVM: ggml-hip/CMakeLists.txt enable_language(HIP) over 159 .cu files
  (~12,154 LOC), 127 <<<grid,block,shmem,stream>>> launch sites (a hipcc/clang language extension g++
  CANNOT parse). CRITICALLY: GGML has NO hipModuleLoad/.hsaco path -- it FUSES host+device in each .cu +
  compiles from source, so there is no offline .hsaco to precompile + no loader in GGML. The rocBLAS
  AOT-precompiled-Tensile template (C6, LLVM-free) DOES NOT APPLY to GGML's kernels.
- BUT the GGML_HIP HOST dispatch backend compiles with plain g++ (no hipcc/LLVM) + links the full solnix
  ROCm stack zero-phantom: libamdhip64.so.5 -> libhsa-runtime64.so.1 -> libhsakmt.so.1 -> libdrm. The
  ggml-hip-host-dispatch-proof.cpp walks GGML's exact per-op sequence (device->stream->hipMalloc->
  hipMemcpyAsync->hipLaunchKernel[what <<<>>> lowers to]->sync->free); 25 undef, 0 phantom; runs off-hw
  (hipRuntimeGetVersion=3275 OK, chain returns hipErrorNoDevice -- expected, no powered V520). The DISPATCH
  CHAIN IS WIRED; only the KERNEL COMPILE is the LLVM gate.
THE STRATEGIC CONCLUSION (aligns with the parity plan's Vulkan-compute-lead): GGML_VULKAN is THE LLVM-FREE
accelerated path today -- Vulkan shaders compile to SPIR-V via glslang (NO LLVM, already built for RADV);
RADV is compiled zero-phantom. So the "as fast as Linux" GPU-compute proof leads with GGML_VULKAN on RADV
(the V520 speaks Vulkan). GGML_HIP reaches the dispatch chain but its kernels wait on either (a) the ROCm
HIP/clang/LLVM toolchain ported to illumos (a large future effort), or (b) an upstream GGML AOT-kernel path
(doesn't exist). ROCm/rocBLAS (Tensile AOT .hsaco) remains LLVM-free + reachable for the rocBLAS workload
class; GGML specifically needs the HIP kernel compiler. => THE ACCELERATED-COMPUTE PARITY PLAN (updated):
1) LEAD: GGML_VULKAN on RADV (LLVM-free, compile-complete, glslang shaders) -- the g4ad V520 proof.
2) rocBLAS-class ROCm workloads: AOT .hsaco via HIP/ROCr (LLVM-free). 3) GGML_HIP: needs the HIP/LLVM port
(deferred; not the lead path). This is a scope CLARIFICATION -- GGML_VULKAN was always the lead vector; the
finding confirms it's also the LLVM-free one. The dispatch chain being wired (host backend zero-phantom)
means if the HIP kernel compiler is ever ported, GGML_HIP activates immediately.

## C5-NVK (2026-08-18): NVIDIA's open Vulkan driver -- C surface + ioctls ported; blocked ONLY on rust-NAK (a wiring gap)
NVK (NVIDIA's open Vulkan driver, Mesa src/nouveau/vulkan) -- the 3rd open-Vulkan vendor. Honest maturity
finding (NOT an illumos portability gap): libvulkan_nouveau.so did NOT compile, blocked by exactly ONE
thing -- NVK's shader compiler NAK (src/nouveau/compiler/nak, ~23k LOC) is written in RUST (needs
rustc>=1.73 + rust.bindgen -> libclang), the one structural difference from RADV (ACO=C++) + ANV (brw=C++)
which need no LLVM/Rust. meson resolves EVERY dep + dies at exactly meson.build:7 "Unknown compiler: rustc"
(no rustc/bindgen/libclang on the GPU node). What DID land (zero-phantom, real): libdrm_nouveau.so.2 (the
libdrm_amdgpu analogue, -Dnouveau=enabled, nvif/ headers) with the nouveau ioctl encoding PROVEN matching
the C1 kernel (NOUVEAU_GEM_NEW=0xc0306480, Linux _IOC via the shared shim); 34 undefs 0 phantom; the ICD
wired (nouveau_icd.x86_64.json, canonical vk_icd contract). The NVK C surface (~31k LOC: vulkan core/mme/
nil/winsys/nvidia_headers) configures clean + reuses the 5 shared fixes. libvulkan_nouveau.so =
link_whole(libnvk), libnvk deps idep_nak (Rust) -> blocked ONLY by the rust-1.73 toolchain, not any illumos
break.
=> THE WIRING PATH (NOT a wall): we HAVE x86 rust working (the OI rust seed 1.97.1 >> 1.73, wrapped as
rust-illumos-seed.nix; ripgrep/fd/cryptography built). NVK needs rustc + rust.bindgen (-> libclang) ON THE
GPU/MESA NODE. So NVK completes by: (1) put the x86 rust seed + bindgen/libclang on the mesa node, (2)
-Dvulkan-drivers=amd,intel,nouveau-experimental -> NAK compiles (Rust) -> libvulkan_nouveau.so links. This
is a bounded wiring step (rust already works on x86-illumos), not an illumos NVK port. TRIAD: RADV(AMD)+
ANV(Intel) compile zero-phantom no-LLVM; NVK(NVIDIA) = ioctls+libdrm_nouveau+ICD+C-surface done, waits on
rust+bindgen on the node (bindgen->libclang is the one new dep). NEXT: wire the x86 rust seed + bindgen onto
the mesa node -> finish NVK. The Vulkan-compute-every-vendor vector is 2/3 compiled + the 3rd is a rust-wire
away. Persisted src/drm-port/nvk/.

## C5-NVK COMPLETE (compile-phase) (2026-08-18): the OPEN-VULKAN TRIAD is COMPLETE on illumos
NVK (NVIDIA's open Vulkan driver) COMPILED + LINKED -- libvulkan_nouveau.so (17.6MB ELF64 AMD64, ~54,245
LOC = 31,133 C + 23,112 Rust NAK). The rust wiring was CLEAN (not a rabbit hole): the x86 rust seed 1.97.1
realized from cache (8daydacsqmkzi72zfa3dmi9pp98d6hmj...-rust-illumos-1.97.1); bindgen/libclang turned out ALREADY ON THE NODE
(/usr/clang/21/lib/libclang.so -- OI's clang-21 pkg, NO LLVM build needed); bindgen 0.69.4 built in 35s via
the seed cargo, emitted nak_bindings.rs; NAK's proc-macro deps (syn/quote/proc-macro2) pre-fetched offline.
NAK compiled (23,112 LOC Rust -> libnak.a via libclang-parsed bindings + a syn proc-macro). libvulkan_
nouveau.so linked (ninja 66/66, 0 FAILED). ZERO-PHANTOM: 2690 undefs all accounted (WEAK wsi_/vk_common_
loader trampolines identical to RADV/ANV, drm*->libdrm, C++->libstdc++/libgcc_s, libc/socket/nsl/m/z) ->
0 true phantoms; MACHINE-CHECKED: dlopen(RTLD_NOW) succeeded (every strong undef binds) + vk_icdGet
InstanceProcAddr exported. ICD wired (nouveau_icd.x86_64.json, api 1.1.274).
=> THE OPEN-VULKAN TRIAD IS COMPLETE ON illumos x86_64 (all compile-phase zero-phantom): RADV (AMD, ACO/
no-LLVM) + ANV (Intel, brw/no-LLVM) + NVK (NVIDIA, NAK/Rust+libclang). ONE llama.cpp GGML_VULKAN reaches
AMD, Intel, AND NVIDIA GPUs once a DRM render node runs -- the Vulkan-compute-every-vendor vector fully
realized in software. Real device enumeration/dispatch stays hardware-gated (a powered GPU + the C1/
amdgpu[or nouveau/i915] DRM node). => solnix's accelerator software is now COMPREHENSIVE: 3 open Vulkan
drivers (every vendor) + the full AMD ROCm compute stack (KFD->libhsakmt->ROCr->HIP) + the C1 DRM/C3-amdgpu
kernel drivers, ALL compile zero-phantom. The GGML_VULKAN parity proof (the LLVM-free lead path) runs on
ANY of the 3 vendors' hardware. gpu-bringup.sh fires on the quota grant (g4ad = AMD/RADV lead).

## C-PVR (2026-08-18): the FULL PowerVR driver stack compiles zero-phantom on illumos (for the Milk-V Jupiter)
The Milk-V Jupiter's Imagination PowerVR BXE-2-32 GPU driver -- BOTH halves now compile zero-phantom on
illumos (the answer to "we need PowerVR drivers"; the Native_SDK was NOT a driver -- this is the real open
Mesa+Linux-DRM driver, ported):
- C-PVR-a (USERSPACE, done): libvulkan_powervr_mesa.so (6.9MB) + libpowervr_rogue.so (9.5MB, the rogue NIR
  shader compiler -- NO LLVM/Rust), ~97k LOC, 14 pvr_drm ioctls, 2603 undefs->0 truly-unresolved,
  dlopen-verified, ICD wired.
- C-PVR-b (KERNEL DRM, done): the Linux drm/imagination driver ported onto the C1 DRM framework -- 2590 LOC
  (2272 .c + 318 .h), 15 ioctls, 12 ET_REL objects into drm-pvr. pvr_gem->C1 GEM(ddi_umem), pvr_vm->GPU MMU,
  pvr_ccb->FW command rings, pvr_context/queue/job->C1 drm_sched, pvr_sync->C1 dma-fence, pvr_fw_riscv->the
  firmware(9F) blob load + the BXE-2-32's RISC-V FW coprocessor + startstop. ZERO-PHANTOM: 59 undefs = 7
  C1-framework (dma_fence/drm_sched) + 52 real illumos KPI (ddi/kmem/avl/list/firmware/atomic), comm -23 = 0.
  ABI MATCHES C-PVR-a's pvr_drm.h BYTE-FOR-BYTE (all 14 DRM_IOCTL_PVR_* numbers + arg struct sizes;
  test_pvr_abi.c PASS -- like libdrm_amdgpu<->amdgpu).
=> THE FULL POWERVR STACK IS ON illumos (framework-complete): userspace Vulkan (rogue, no LLVM) + kernel DRM
(onto C1) + the RISC-V FW-load path, both zero-phantom + ABI-matched. REMAINING (Jupiter-hardware-gated, the
same class as every GPU): (1) the BXE-2-32 device table (Mesa 25.x + pco) + CORE_ID BVNC identity, (2) the
SpacemiT FW blob (from the K1 BSP, obtainable), (3) the register-touching runtime (MMU PT walk/cache flush,
RISC-V remap, FW doorbell+boot-poll+IRQ) -- all on the physical Jupiter. So: ACCELERATED COSMIC/LLMs on the
Jupiter are reachable via this driver (interim: llvmpipe SW render keeps the box usable). NEXT: wire pvr into
the shared drm_core.c (one call-site) + the Mesa-25.x bump for BXE-2-32 + on-HW bring-up when the box lands.
Persisted src/drm-port/powervr-drm/ + src/drm-port/powervr/.

## C-PVR-c (Mesa 25.3.6): the Jupiter's EXACT GPU (BXE-2-32) device table -- compile-proven on illumos
The Milk-V Jupiter's Imagination PowerVR is the BXE-2-32 -- Mesa 24.0.9 lacked it (only GX6250/AXE-1-16M/
BXS-4-64). FOUND: Mesa 25.3.6 (NOT 25.1.4) ships it.
- BXE-2-32 IS in Mesa 25.3.6 src/imagination: device_info/bxe-2-32.h -- public_name "BXE-2-32", B-Series,
  device_id 0x36052182, BVNC 36.29.52.182, a complete pvr_device_info_36_29_52_182 (56 feature bits +
  enhancements + quirks + ident), runtime-selected by CASE_PACKED_BVNC_DEVICE_INFO(36,29,52,182). (12 parts
  in 25.3.6 vs 3 in 24.0.9.)
- Compiler: 25.x defaults to `pco` (pure C/NIR, NO Rust, 15,794 LOC; the vulkan driver 63,119 LOC); rogue is
  legacy/unwired.
- COMPILE-PROVEN on illumos: the BXE-2-32-carrying source compiles clean -- pvr_device_info.c -> .o OK
  (T pvr_device_info_init, the runtime BVNC selector), 10/77 imagination objects built. The C-PVR-a illumos
  fixes (5 Mesa-wide + pvr_drm __sun guard + _BITULL shim) apply to 25.3.6 UNCHANGED -- no new source breaks.
- pvr_drm ABI: BYTE-IDENTICAL 24.0.9 <-> 25.3.6 (14 ioctls 0x00-0x0d, all struct layouts + flags) => the
  C-PVR-b KERNEL DRIVER NEEDS ZERO CHANGES. The whole PowerVR stack stays coherent across the Mesa bump.
- THE ONE GAP (not PowerVR/illumos-specific): the full 25.3.6 .so LINK needs the CLC toolchain (LLVM>=18-dev
  + SPIRV-Tools + SPIRV-LLVM-Translator + libclc) for pco's usclib (common/sync/tex.cl OpenCL-C helper
  shaders via mesa_clc). The node has only the clang-21 runtime (no llvm-config/headers/SPIRV-Tools/libclc).
  build-mesa-powervr25.sh with -Dmesa-clc=enabled -Dllvm=enabled links it once that toolchain is present.
  The runnable zero-phantom artifact TODAY stays the ABI-identical 24.0.9 .so (truly-unresolved=0); its only
  gap is the BXE table -- which 25.3.6 supplies + I proved compiles.
=> the Jupiter's EXACT-GPU userspace driver is compile-proven on illumos + ABI-coherent with the kernel
driver; the final .so link is gated on building the CLC/LLVM-18 toolchain on the node (a bounded build-dep
task, not a port). src/drm-port/powervr/powervr-mesa25/.

## CLC/LLVM toolchain (LLVM 20.1.8) -- unblocks the Mesa-25 PowerVR .so link AND GGML_HIP (one OI pkg)
The CLC toolchain that pco's usclib (mesa_clc) needs -- and that GGML_HIP's .cu kernels need -- is now
complete on illumos:
- LLVM 20.1.8 via OI pkg `developer/clang-20` (343MB, ~1min install -- NOT a multi-hour source build). ONE
  package delivered headers + llvm-config + clang + ALL THREE targets in one shot: X86 (mesa_clc) + SPIRV
  (mesa_clc) + AMDGPU/amdgcn (GGML_HIP). The lazy win.
- Built from source against it: SPIRV-Tools 2026.4.1 (spirv-as/val/opt + SPIRV-Tools.pc), SPIRV-LLVM-
  Translator (llvm_release_200 -> llvm-spirv + libLLVMSPIRVLib.a), libclc 0.2.0 (release/20.x ->
  spirv-mesa3d-.spv + spirv64-mesa3d-.spv [the mesa_clc inputs] + amdgcn bitcode + libclc.pc).
- PROVEN end-to-end: OpenCL-C -> clang -target spirv64 -> llvm-spirv -> spirv-val = SPIRV VALID (the exact
  mesa_clc chain).
- Satisfies Mesa 25.3.6 -Dmesa-clc=enabled -Dllvm=enabled (meson sees llvm-config 20.1.8 + libclc 0.2.0 +
  SPIRV-Tools). => the final PowerVR libvulkan_powervr_mesa.so (25.3.6, WITH BXE-2-32) is now LINKABLE (the
  one-command finish is in CLC-TOOLCHAIN-STATUS.md §6; the only logistics = co-locate the Mesa 25.3.6 tree +
  this toolchain on one node).
- GGML_HIP: the AMDGPU/amdgcn LLVM backend gap is CLOSED (already in OI clang-20). GGML_HIP's remaining need
  is the hipcc wrapper (not an LLVM-backend gap) -- the "as fast as Linux" LLM path advances.
- illumos runtime gotcha (baked into env.sh): LD_LIBRARY_PATH=/usr/clang/20/lib:/usr/gcc/14/lib/amd64
  (libLLVM.so.20.1 + gcc libstdc++; source binaries got no runpath).
src/drm-port/clc-toolchain/ (env.sh + CLC-TOOLCHAIN-STATUS.md).

## C-PVR-d (DONE): the PowerVR userspace Vulkan driver for the Jupiter's EXACT GPU is LINKED + zero-phantom
The final link -- the userspace PowerVR driver for the Milk-V Jupiter's BXE-2-32 is a real, dlopen-able,
zero-phantom shared object on illumos:
- libvulkan_powervr_mesa.so LINKED from Mesa 25.3.6 (ninja 585/585 rc=0), 16,010,152 bytes (16MB, pco
  statically folded in), the imagination tree ~79,610 C LOC. Built with the CLC toolchain (LLVM 20.1.8 +
  SPIRV-Tools + libclc), mesa_clc compiling pco's usclib .cl->.spv via the real LLVM chain.
- ZERO-PHANTOM (self-verified on the node): 343 UNDEF (336 GLOB), all GLOB resolve to the 7 NEEDED libs ->
  truly-unresolved GLOB = 0; the 2 leftovers are WEAK _ITM_*TMCloneTable GCC hooks (optional-by-design,
  never phantom).
- BXE-2-32 IN the .so (self-verified nm + strings): pvr_device_info_36_29_52_182 (OBJT 152B) +
  pvr_device_info_init (the runtime BVNC selector, FUNC 4436B); strings "BXE-2-32"/"B-Series". The Jupiter's
  exact BVNC 36.29.52.182 / device_id 0x36052182.
- dlopen(RTLD_NOW|RTLD_GLOBAL) OK -- every symbol bound; the 3 ICD loader entry points non-NULL. ICD wired:
  powervr_mesa_icd.x86_64.json (api_version 1.4.328).
- pvr_drm ABI re-confirmed identical to the C-PVR-b kernel driver (14 ioctls, SUBMIT_JOBS=0x8010644d via
  the illumos _IOC shim). No new Mesa-25 illumos link break -- the C-PVR-a fixes carried forward unchanged.
=> THE USERSPACE POWERVR DRIVER FOR THE JUPITER'S EXACT GPU IS DONE (compile+LINK-complete, zero-phantom,
ICD-wired, ABI-coherent with the kernel driver). The FULL PowerVR stack on illumos: userspace Vulkan (C-PVR-a
rogue + C-PVR-d BXE-2-32/pco, LINKED) + kernel DRM (C-PVR-b, onto C1) + FW-load (pvr_fw_riscv). REMAINING
(true hardware gates, unchanged): the physical Jupiter + the SpacemiT FW blob + the runtime register-touching
bring-up. src/drm-port/powervr/powervr-mesa25/ (the .so is gitignored [16MB]; audit outputs + link-powervr25.sh
+ POWERVR-STATUS.md committed).

## GGML_VULKAN (DONE, self-verified): the LLVM-free "as fast as Linux" LLM path builds + links + RUNS on illumos
The maintainer's NORTH-STAR beachhead -- local-LLM inference via GGML_VULKAN (SPIR-V shaders through glslang,
NO hipcc/LLVM kernel compile, unlike GGML_HIP) -- builds, links, and runs on x86_64-illumos:
- Vulkan deps: Vulkan-Headers (source, Khronos v1.3.280, header-only) + Vulkan-Loader (source ->
  libvulkan.so.1.3.280, a 727KB x86_64-illumos ELF, 4 illumos patches: __sun in COMMON_UNIX_PLATFORMS +
  /proc/self/path/a.out exe-path + __EXTENSIONS__) + glslang 14.3.0/spirv-headers/spirv-tools (OI pkg) + a
  written glslc wrapper (python shim -> glslangValidator; OI has no glslc/shaderc).
- GGML_VULKAN configured ("Including Vulkan backend", Vulkan 1.3.280). vulkan-shaders-gen built + RUNS on
  illumos (x86_64 ELF) -> 1653 .spv generated, 138 .comp.cpp blobs embedded, a 243KB shaders.hpp. SPIR-V gen
  works on illumos (the key thing -- glslang, no LLVM).
- libggml-vulkan.so built (43MB ELF, links libvulkan.so.1, SPIR-V embedded). llama-cli LINKED + RUNS
  (self-verified: a real AMD64 ELF, "version 0.1.2-dev ... built with GNU 14.3.0 for SunOS amd64").
  ZERO-PHANTOM (ldd -r = 0 symbol-not-found on both libggml-vulkan + llama-cli; the vk* refs resolve to
  libvulkan.so.1).
- llama-cli --list-devices RUNS: initializes the Vulkan backend, calls the loader, enumerates -> reports
  (none) [no GPU + no RADV ICD on the headless node -- the EXPECTED headless result]. Real device binding via
  RADV is GPU-hardware-gated, exactly like the RADV/ANV/NVK/PowerVR compile-proofs.
- illumos fixes (crib-and-adapt): llama.cpp RLIMIT_MEMLOCK/<sys/syslimits.h>/"Unknown architecture" guards;
  miniaudio _Alignas C++ gate; glslc->glslangValidator wrapper + feature-test hardening (coopmat2/NV skipped);
  -lsocket -lnsl link fix.
=> the LLVM-free local-LLM inference engine BUILDS + LINKS + RUNS on illumos (SPIR-V via glslang). The only
gate to actual token-generation is a real GPU + a loaded RADV ICD (hardware). This is the concrete
"as fast as Linux" LLM lead path proven buildable on solnix -- on RADV (AMD), and the same GGML_VULKAN binary
targets ANY Vulkan ICD (ANV/NVK/PowerVR). src/drm-port/ggml-vulkan/ (the 43MB .so + 727KB loader gitignored;
GGML-VULKAN-STATUS.md + the glslc wrapper + patch scripts committed).

## STANDING DIRECTIVE: GPU parity validation on real hardware (when a GPU instance is available)
The north star is "as fast as Linux" for BOTH graphics AND LLMs. When GPU hardware is available:
1. LINUX BASELINE FIRST (the target, always runnable): on the SAME GPU, run the SAME stack on Linux --
   vkmark/glmark2 (graphics FPS) + GGML_VULKAN llama-bench (LLM tok/s, GPU vs CPU) via Mesa RADV. This is
   the concrete number solnix must match on that exact silicon.
2. SOLNIX RUNTIME PROBE: the illumos GPU runtime needs a live kernel with the DRM driver bound to the GPU.
   EC2 doesn't boot solnix + we never modload experimental DRM into a live host kernel -> the honest path to
   a solnix GPU number is GPU PASSTHROUGH to an illumos/solnix guest (vfio-pci) OR a metal instance / local
   hardware (the Milk-V Jupiter for PowerVR, a local AMD box for RADV). Probe how far the hardware allows;
   document the exact gap; NEVER claim parity without a real solnix number.
3. VERDICT: report Linux numbers + how close solnix gets + what closes the last gap. Both graphics
   (a real app rendering on the GPU) AND LLM (real tok/s) must be validated, per vendor (AMD/RADV first).
Current chiuso GPU quota: 8 G/VT vCPU (us-east-2) = one g4ad.2xlarge (AMD V520/RADV) or g4dn (NVIDIA/NVK).

## C2-SW-VULKAN RUNTIME-PROVEN (2026-10-12): lavapipe is a REAL working CPU Vulkan device on solnix
The software Vulkan substrate is no longer just compile-complete -- it RUNS and is negative-controlled on
x86_64-illumos. This is the honest, non-hardware C2 win the north star's "Vulkan-compute FIRST" vector needs:
one API that reaches every vendor once a DRM render node lands, proven working in SOFTWARE today.

MEASURED (clean build-host AMI ami-0aa1f6ac952e3408d, a fresh c7i instance, 2026-10-12):
- Mesa 25.1.4 lavapipe (`-Dvulkan-drivers=swrast -Dgallium-drivers=llvmpipe -Dllvm=enabled`) BUILT on
  illumos with gcc-14 + LLVM 20.1.8 -> `libvulkan_lvp.so` (15.6MB, Vulkan 1.4.311 ICD) + `lvp_icd.x86_64.json`.
- ENUMERATION (lvp-direct-proof): a dlopen of the ICD + vkCreateInstance + vkEnumeratePhysicalDevices reports
  ONE device: **"llvmpipe (LLVM 20.1.8, 256 bits)", apiVersion 1.4.311** -> LAVAPIPE_ENUMERATED_PASS.
  NEGATIVE CONTROL: pointing the harness at libc/libz (non-ICD) finds no vk_icdGetInstanceProcAddr and NO
  device -> the enumeration is lavapipe-specific, not a false pass.
- COMPUTE (lvp-compute-proof): a real Vulkan compute shader (out[i]=in[i]*2, SPIR-V from glslang, dispatched
  via the full pipeline/descriptor/queue chain) runs on lavapipe and VERIFIES over 1024 elements ->
  COMPUTE_VERIFY_PASS. NEGATIVE CONTROLS: a wrong expected multiplier makes the checker report
  COMPUTE_VERIFY_FAIL (it CAN fail -> the PASS means something); a non-ICD lib yields no device (no silent pass).
- Survives the AMI bake: a FRESH instance from ami-0aa1f6ac952e3408d re-runs both proofs PASS.
=> SOFTWARE VULKAN WORKS ON SOLNIX NOW. HONEST SCOPE: this is lavapipe (CPU/LLVM-JIT), NOT hardware
acceleration -- no /dev/dri, no GPU. It is the exact API substrate COSMIC (wgpu-GL) and llama.cpp GGML_VULKAN
consume; the SAME ICD mechanism binds a real GPU once a hardware DRM render node exists (the C1 keystone +
RADV/ANV/NVK). This neither claims nor approaches hardware Vulkan (which graphics-claims-audit.md REFUTED).

REPRODUCIBLE DERIVATION (the C2 recipe, no longer prose): scripts/build-mesa-lavapipe-illumos.sh builds it;
pkgs/mesa-lavapipe-illumos.nix (in solnix-pkgs, eval-checked) wraps the staged tree; recipes.tsv rows
(mesa-lavapipe + mesa-lavapipe-illumos). Mesa+LLVM don't build through the nixpkgs fork, so it is a
host-build-then-bank derivation (same pattern as the from-source Rust toolchain). illumos cuts for Mesa 25.1.4
(beyond the softpipe 24.0.9 set): remove 'sunos' from system_has_kms_drm (no libdrm on the SW path);
renderdoc_app.h RENDERDOC_CC empty on __sun; -DHAVE_STRUCT_TIMESPEC/-DHAVE_SECURE_GETENV; the int8_t-vs-
signed-char -Wno-error (same as RADV); -Dgallium-rusticl=false (drops the Rust requirement). Build-tool note:
meson/ninja drive the build; the scratch-2026 cmake binary SIGSYS's on the 2025 kernel for dependency
scanning (so the Vulkan-Loader + llama.cpp GGML_VULKAN runtime measurement, both cmake, are a follow-up on a
pkg-update'd 2026-kernel node OR via the already-published vulkan-loader-1.3.280 store path).

LLM VULKAN-COMPUTE PATH (tok/s) -- STATUS: HARNESS READY, MEASUREMENT PENDING (honest).
scripts/llama-vulkan-lavapipe-bench.sh wires the proven lavapipe ICD under llama.cpp GGML_VULKAN
(--list-devices should now show the llvmpipe device, not the "(none)" the prior build reported for lack of a
loaded ICD) and measures tok/s (ngl=99 Vulkan vs ngl=0 CPU, vs the ~70 tok/s C0 CPU baseline). It was NOT run
this session: it needs the Vulkan loader (libvulkan.so.1) + a llama.cpp GGML_VULKAN build, both blocked on the
clean node by the 2026-cmake/2025-kernel SIGSYS. HONEST EXPECTATION (do not assume): software Vulkan JITs on
the CPU, so lavapipe may be SLOWER than llama.cpp's tuned AVX2 CPU backend -- the point is that the
Vulkan-compute PATH runs end-to-end in software NOW, so the SAME binary uses a real GPU when hardware DRM
lands. The number must be MEASURED and reported honestly (faster or slower) on a loader-capable node.

THE CLEAN X86 BUILD-HOST (substrate fix, this session): the former build-host AMI ami-0e344991f2f44b11d does
NOT network (no ENA attach, "Hostname: unknown", stale baked device identity -- it was create-image'd from a
running mutated instance). Replaced by **ami-0aa1f6ac952e3408d** (solnix-buildhost-x86-clean-20261012):
R2-networking-good base (restored x86_64-20260911, ena/DHCP cold-boot fix) + the full toolchain, SCRUBBED
(ssh host keys/nodename/dhcp leases/logs) and imaged from the STOPPED instance. Boot-verified: a fresh launch
gets a DHCP lease (172.31.x), SSHes, has internet, and re-runs the lavapipe proofs PASS. This replaces ami-0e34
for every x86 stream (also unblocks priority #1 boot-verify).
