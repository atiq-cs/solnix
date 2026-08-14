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
