# solnix C3 — real-GPU driver options mapped to the C1 DRM framework

Phase **C3** of `docs/design-gpu-compute-parity.md`: the path from the C1 DRM
framework (compiles: core + GEM + virtio-gpu 2D + dma-fence/resv/scheduler +
dma-buf/PRIME — see `src/drm-port/{DESIGN.md,STATUS.md}`) and C2 Mesa (software
GL via softpipe/OSMesa proven; software Vulkan via lavapipe proven on the prior
node) to **real-GPU accelerated compute at Linux parity** on the open stacks.

This is a **design + first-concrete-steps** document, not a full driver port. It
maps each candidate real-GPU driver onto the C1 framework in tractability order,
names the compute-runtime layer that must sit above each, and records the one
bounded build that can start now with no GPU hardware: Mesa's **virgl** Gallium
driver + **Venus** Vulkan driver (the virtio-gpu guest-side drivers — see §C3a).

Open-stack focus is deliberate and unchanged from the north star: **AMD ROCm,
Intel oneAPI, Vulkan on all vendors, and NVK for NVIDIA**. Proprietary CUDA's
kernel module is Linux-only and out of reach; it is documented-not-promised.

---

## 0. What C1/C2 already give C3 (the substrate)

C3 does not start from zero. The C1 framework already compiles the load-bearing
surface every real-GPU driver reuses, against real illumos KPI:

- **drm core + char device** — `dev_ops`/`cb_ops`, `/dev/dri/card0`+`renderD128`
  minor nodes, the DRM ioctl dispatch, the preserved Linux DRM UAPI (`drm.h`).
  Any new driver plugs a `struct drm_driver` identity + its ioctl subset into
  this dispatch; it does **not** re-invent the node/ioctl plumbing.
- **GEM** — buffer-object create/map/destroy/close over `ddi_umem_alloc` +
  `cb_devmap`/`devmap_umem_setup`. Shared by every driver (system-RAM buffers).
- **dma-fence / dma-resv / ww_mutex / scheduler** — GPU synchronization + a
  single-queue FIFO scheduler with per-job finished fences. Every driver's
  command submission signals a fence here; Mesa/Vulkan waits on it.
- **dma-buf / PRIME + sync_file** — cross-process/cross-driver buffer sharing
  over `falloc` + a spec-vnode (the DESIGN.md D.1 mechanism). This is what
  GBM/Mesa render-nodes need; it is driver-agnostic.
- **TTM is NOT yet built** — C1 deliberately skipped it (virtio-gpu has no VRAM).
  It is the first real-GPU-specific gap for any discrete-VRAM card (amdgpu/xe/
  nouveau); virtio-gpu 3D does **not** need it. See §C3b.

C2 gives the userspace: Mesa builds and runs on illumos (softpipe GL proven;
lavapipe SW-Vulkan proven), with the two upstreamable illumos portability
patches (`u_atomic.h` gate `__sun` on `!__GNUC__`; `u_thread.c` `!__sun` on
`pthread_getcpuclockid`) and the standalone-shell + `nix-store --add` build
pattern established. C3 adds real Gallium/Vulkan drivers on top of that same
build.

---

## 1. Driver options, in tractability order

The ordering is by **engineering cost against the C1 framework**, cheapest
first. The recommendation is unambiguous: **virtio-gpu 3D (virgl/Venus) first**
— it is the only option that reaches accelerated GPU with **no new kernel
hardware driver**, works on any cloud/host that has a GPU, and reuses the C1
virtio-gpu path already built for 2D.

### Tractability summary

| Rank | Driver | New kernel work vs. C1 | VRAM/TTM? | Userspace (GL / Vulkan) | Accelerated by | Horizon |
|---|---|---|---|---|---|---|
| **1** | **virtio-gpu 3D / Venus** | EXECBUFFER + 3 ioctls + virgl/venus wire cmds on the **existing** C1 virtio-gpu transport | **No** | **virgl** (GL) / **Venus** (Vulkan) | the **host's** GPU (any vendor) | **quarters** — the C3 first target |
| 2 | **amdgpu** | the biggest: KMS + GEM/**TTM** (VRAM) + rings/IB + KFD (ROCm) | **Yes** | radeonsi (GL) / **RADV** (Vulkan) / ROCm | real AMD GPU | 1–2 years |
| 3 | **i915 / xe** | KMS + GEM (+ stolen/LMEM for dGPU) + rings/IB | i915 no / xe dGPU yes | iris (GL) / **ANV** (Vulkan) / Level-Zero | real Intel GPU | 1–2 years (rides amdgpu's shim work) |
| 4 | **nouveau / NVK** | KMS + GEM/TTM + channels + GSP-firmware handshake | **Yes** | nouveau (GL) / **NVK** (Vulkan) | real NVIDIA GPU | 2+ years (GSP is the wall) |

Everything below rank 1 needs a **real per-GPU kernel driver** — the ~1–2 year
LinuxKPI-shim wall from `docs/gpu-parity-survey.md`. Rank 1 sidesteps that wall
entirely by making the **host** the GPU driver and the guest a protocol client.

---

### 1a. virtio-gpu 3D / Venus — the recommended C3 first target

**Why it is cheapest.** The C1 virtio-gpu path already compiles the transport
(`virtio_gpu_transport_attach` over the illumos `virtio` framework), the GEM
backing, and the 2D `SET_SCANOUT` command chain. "3D" (virgl/Venus) is the
**same transport carrying more command types** — it does not need a new bus, a
new memory model, VRAM, or TTM. virtio-gpu buffers stay host-shared system
pages (the C1 `ddi_umem` + `RESOURCE_ATTACH_BACKING` guest-physical-cookie
path). The acceleration happens **host-side**: QEMU's `virtio-gpu-gl` device
feeds the guest's virgl/venus command streams to the host's real Mesa on the
host's real GPU.

**The topology.**

```
  solnix GUEST                                    QEMU HOST (has a real GPU)
  ------------                                    -------------------------
  app (GL / Vulkan / llama.cpp Vulkan backend)
      |  Mesa virgl Gallium driver (GL)                virglrenderer
      |  Mesa Venus Vulkan driver  (Vulkan)   ===>       -> host Mesa
      v                                                     -> host DRM (amdgpu/
  C1 virtio-gpu DRM  (/dev/dri/renderD128)     virtio        i915/nvidia)
      - GEM (ddi_umem)                           ring          -> host GPU
      - EXECBUFFER -> virtio_gpu_exec -> host                   (real accel)
      - dma-fence signalled on host completion
```

So on **any cloud instance or workstation whose host has a GPU** and runs QEMU
with `-device virtio-gpu-gl` (or `virtio-vga-gl`), solnix in the guest gets
**real hardware-accelerated GL and Vulkan** — including llama.cpp's Vulkan
compute backend (C4) — with **zero solnix kernel hardware-driver work** beyond
extending the C1 virtio-gpu path from 2D to 3D.

**What C1 must gain for 3D (the concrete kernel gaps, beyond C1b 2D).** The C1
2D path did `RESOURCE_CREATE_2D -> ATTACH_BACKING -> SET_SCANOUT ->
TRANSFER_TO_HOST_2D -> RESOURCE_FLUSH`. 3D adds a small, well-defined ioctl +
command surface on the **same** `virtio_gpu_exec` chain and the **same** GEM
buffers. The virtio-gpu **guest-driver UAPI** is `virtgpu_drm.h` (Linux, BSD-
licensed for non-Linux guests — the same provenance rule as the C1
`virtio_gpu_hw.h` wire header):

| UAPI ioctl (`virtgpu_drm.h`) | What it does | C1 gap (kernel side) |
|---|---|---|
| `DRM_IOCTL_VIRTGPU_GET_CAPS` | fetch host capset (virgl caps / venus caps) so Mesa knows what the host supports | new: a `GET_CAPABILITY` (capset) command over `virtio_gpu_exec`; store + return |
| `DRM_IOCTL_VIRTGPU_CONTEXT_INIT` | create a 3D context (selects virgl vs. venus capset) | new: `CTX_CREATE` command + per-`drm_file` context id |
| `DRM_IOCTL_VIRTGPU_RESOURCE_CREATE` | create a 3D resource (not just a 2D scanout surface) | extend the C1 `RESOURCE_CREATE_2D` path to `RESOURCE_CREATE_3D` (adds target/format/bind/depth/array params) |
| `DRM_IOCTL_VIRTGPU_RESOURCE_INFO` | query a resource's host handle/stride | new: bookkeeping on the GEM object (host res id) |
| `DRM_IOCTL_VIRTGPU_MAP` | get an mmap offset for a resource | **reuse C1b** `cb_devmap`/`devmap_umem_setup` (the exact 2D mmap path) |
| `DRM_IOCTL_VIRTGPU_TRANSFER_FROM_HOST` / `TO_HOST` | copy between guest pages and host resource | extend the C1 `TRANSFER_TO_HOST_2D` to the 3D box form |
| **`DRM_IOCTL_VIRTGPU_EXECBUFFER`** | **submit a command buffer** (a virgl or venus command stream) to the host, optionally with in/out fences | **the load-bearing new path**: a `SUBMIT_3D` command carrying the guest command-buffer bytes + bo list over `virtio_gpu_exec`; on host ack, signal the C1 dma-fence; wire the C1 **scheduler** `run_job` -> this submit (the "wiring run_job to virtio_gpu_exec" step STATUS.md already names) |
| `DRM_IOCTL_VIRTGPU_WAIT` | wait on a resource's fence | **reuse C1c** dma-fence wait + the PRIME/sync_file fd |

The delta is roughly: one new command family (`CTX_CREATE`, `GET_CAPABILITY`,
`RESOURCE_CREATE_3D`, `SUBMIT_3D`, `TRANSFER_*_3D`, box form) added to
`virtio_gpu.c` on the **already-built** `virtio_gpu_exec` transport, plus the
`virtgpu_drm.h` ioctl dispatch entries in `drm_core.c`, plus honoring
`context_init`/fence params. It reuses C1's GEM, dma-fence, scheduler, and
`cb_devmap` **unchanged**. This is bounded C1-follow-on work (call it **C1d /
virtio-gpu-3D**), not a new driver.

**How it uses the C1 dma-buf/fence.** `EXECBUFFER` takes optional in-fence
(wait before submit) and produces an out-fence (signalled when the host
completes the command buffer). These map directly to the C1c dma-fence +
sync_file: the out-fence is a C1 `dma_fence` the scheduler's per-job finished
fence wraps; a `sync_file` fd (the C1 `falloc`+spec-vnode mechanism) exports it
to userspace so Mesa's Vulkan/GL submit-then-wait works exactly as on Linux. BO
sharing across the render node uses the C1 PRIME path unchanged.

**Which Mesa driver.** GL = **virgl** (`-Dgallium-drivers=virgl`, Gallium driver
`src/gallium/drivers/virgl` + the DRM winsys `src/gallium/winsys/virgl/drm`).
Vulkan = **Venus** (`-Dvulkan-drivers=virtio`, `src/virtio/vulkan`). Both are
thin protocol encoders — they translate GL/Vulkan calls into the virgl/venus
command streams that `EXECBUFFER` ships to the host. They need **no LLVM** and
**no local GPU** to build (they don't rasterize; the host does). Their only
kernel touch-point is the `virtgpu_drm.h` UAPI on `/dev/dri/renderD*` — the C1
node. This is the **C3a build** (§below), buildable now.

**Runtime proof needs a metal QEMU host.** Same constraint as C1b/C1c: this
build node is non-metal (TCG-only, no `/dev/kvm`), and a real accelerated proof
needs `-device virtio-gpu-gl` which itself needs a host GPU + KVM. The build
(compile the .so) is host-free and can be proven now; the end-to-end
"accelerated triangle / accelerated llama.cpp-Vulkan in the guest" proof is a
metal-instance milestone.

---

### 1b. amdgpu — real AMD hardware, the fully-open ROCm target

The most valuable **real-hardware** target because AMD's stack is fully open,
kernel to userspace: amdgpu (DRM) + RADV/radeonsi (Mesa) + ROCm (HIP/rocBLAS)
are all buildable. It is also the **biggest kernel surface** in C3.

**Crib source.** NetBSD `external/bsd/drm2` has amdgpu (already the C1 crib
reference tree, pinned in `netbsd-ref/`); FreeBSD `drm-kmod` tracks a newer
Linux (6.12, gfx11/RDNA3) and is the more current donor per
`docs/gpu-parity-survey.md`. The C1 approach holds: **do not lift the ~500k-LOC
Linux amdgpu .c**; adapt the linux-KPI shim boundary + re-express the glue
against illumos DDI, keeping the Linux DRM UAPI so RADV/ROCm are unchanged.

**Phases against the C1 framework** (each gated on the prior):

| Phase | Deliverable | New vs. C1 |
|---|---|---|
| **A3-a** | PCI attach + BAR/MSI for a **non-virtio** device | C1 leaned on the illumos `virtio` framework for PCI/BAR/MSI; amdgpu needs raw `ddi_regs_map_setup` + `ddi_intr_*` (the `linux_pci.c` surface the survey flagged as C3) |
| **A3-b** | **TTM** — VRAM manager + GTT/GART + eviction | the big new memory subsystem C1 skipped: `ddi_regs_map_setup` on the VRAM BAR + `devmap_devmem_setup` for mmap; `ddi_dma_*` for GART scatter-gather; a bespoke LRU/eviction (illumos VM has no direct analogue). See §C3b. |
| **A3-c** | KMS modeset (DC/DCN display) on real connectors | atomic modeset helpers on top of the C1 KMS ioctls; EDID/HPD |
| **A3-d** | GFX ring + IB submission + GPU scheduler multi-ring | the C1 single-FIFO scheduler generalizes to the amdgpu rings; per-ring fences; GPU reset/timeout (C1 deferred this as "C3-era, a real multi-ring GPU") |
| **A3-e** | firmware (ucode) load + PSP/SMU bringup | firmware-blob redistribution terms checked separately (survey §crux caveat c) |
| **A3-f** | **KFD** compute ioctls (ROCm) | the `/dev/kfd` char device + the KFD UAPI (queue create, memory, doorbells) — a **second** ioctl surface beside DRM, the ROCm-specific gap |

Ordering note: A3-a..d gets **GL/Vulkan on AMD** (radeonsi + RADV) — the graphics
+ Vulkan-compute win — **without** KFD. A3-f (KFD) is only needed for the ROCm
HIP/rocBLAS path, which is redundant with Vulkan-compute for LLM (see §2). So
even amdgpu's value front-loads into A3-a..d; KFD is optional and last.

---

### 1c. i915 / xe — Intel, the open oneAPI target

Structurally the same as amdgpu but generally smaller: **i915** (older iGPU) has
no discrete VRAM (uses stolen system memory), so it can **skip TTM** on the
integrated path — closer to virtio-gpu's memory model and a lighter first real
driver than amdgpu. **xe** (Arc/Xe dGPU) reintroduces device-local memory
(LMEM), so it needs the TTM-equivalent (A3-b above).

Crib: NetBSD drm2 has i915; FreeBSD drm-kmod has both i915 and xe. Phases mirror
amdgpu's A3-a..d minus TTM for integrated i915. Userspace: **iris** (GL) + **ANV**
(Vulkan) + Intel **Level-Zero / oneAPI** for compute. Because it rides the same
PCI/BAR/ring shim work amdgpu establishes (A3-a, A3-d), i915 is "1–2 years but
rides amdgpu's shim" — do whichever real driver first, the second is cheaper.

---

### 1d. nouveau / NVK — NVIDIA, the only open NVIDIA route

The **only** NVIDIA path that does not require NVIDIA's proprietary,
Linux-only-glue kernel module + closed userland. nouveau (DRM) + **NVK** (Mesa's
open NVIDIA Vulkan, `-Dvulkan-drivers=nouveau`). Kernel surface = KMS + GEM/TTM
(NVIDIA dGPUs have VRAM) + channel/pushbuffer submission + — the wall — the
**GSP firmware handshake** that Turing+ GPUs require (the RM/GSP command
protocol). NVK is ready in userspace; the nouveau kernel port + GSP bringup is a
2+ year effort and the least tractable of the real drivers. Crib: NetBSD drm2 +
FreeBSD drm-kmod both carry nouveau. Documented-not-promised beyond scoping.

**CUDA remains out of reach** (proprietary, Linux-only kernel module, closed
userland). NVK gives open Vulkan-compute on NVIDIA *if* the nouveau kernel port
ever lands; it does not give CUDA. This matches the north star's honest framing.

---

## 2. The compute-runtime layer above each driver

Every driver above only produces a `/dev/dri/renderD*` node speaking the DRM
UAPI. The **compute** value comes from the userspace runtime stack on top. Per
driver, the layers (all portable C/C++, buildable once the node exists):

| Driver | GL (Gallium) | Vulkan | Vendor compute | LLM plug-in (C4) |
|---|---|---|---|---|
| **virtio-gpu 3D** | **virgl** | **Venus** | (host's — whatever the host GPU is) | **llama.cpp Vulkan** backend via Venus -> host GPU |
| **amdgpu** | radeonsi | **RADV** | **ROCm** (HIP / rocBLAS / ROCr) via KFD | **llama.cpp Vulkan** (RADV) *or* **HIP** backend (ROCm) |
| **i915 / xe** | iris | **ANV** | **oneAPI / Level-Zero** (oneMKL) | **llama.cpp Vulkan** (ANV) *or* SYCL backend (oneAPI) |
| **nouveau** | nouveau-gallium | **NVK** | (none open; CUDA is closed) | **llama.cpp Vulkan** (NVK) |

**The strategic through-line: Vulkan-compute is the CUDA-free, ROCm-free GPU-LLM
path.** llama.cpp's `GGML_VULKAN` backend needs only a Vulkan ICD. Mesa gives one
for every vendor: Venus (virtio-gpu), RADV (AMD), ANV (Intel), NVK (NVIDIA). So
the **same** llama.cpp Vulkan build reaches every GPU family solnix ever gets a
DRM node for — no per-vendor compute runtime required. That is why the C3
ordering leads with virtio-gpu 3D (Venus) and why RADV/ANV/NVK are all "rebuild
once the DRM node exists."

**The vendor compute stacks are the heavier, optional tier:**
- **ROCm (AMD)** — HIP (CUDA-like C++ runtime, MIT) + rocBLAS + ROCr (NCSA). All
  permissive userspace, but hard-requires the amdgpu **KFD** ioctls (`/dev/kfd`,
  A3-f above). Gives the HIP llama.cpp backend + PyTorch-ROCm. Redundant with
  Vulkan-compute for pure LLM inference; matters for the broader ROCm ML
  ecosystem (rocBLAS-accelerated numerics, PyTorch). Build only after A3-f.
- **oneAPI / Level-Zero (Intel)** — Level-Zero runtime + oneMKL + DPC++/SYCL.
  Needs the i915/xe DRM node + Level-Zero's kernel ioctls. Drives llama.cpp's
  SYCL backend. Same "optional heavy tier" as ROCm.
- **Vulkan (all vendors)** — the light, universal tier: Mesa's Vulkan drivers +
  llama.cpp `GGML_VULKAN`. Lead with this.

**How llama.cpp plugs in (C4 preview).** `-DGGML_VULKAN=ON` links the Vulkan
backend against the Vulkan loader; at runtime it picks whichever ICD is
installed (Venus / RADV / ANV / NVK). `-DGGML_HIP=ON` links the ROCm HIP backend
(needs ROCm + KFD). The C4 phase builds these once the corresponding C3 driver
node exists; C3a (virgl/Venus) is what makes the **Vulkan** backend reachable on
accelerated hardware first.

---

## 3. C3a — the concrete first step (buildable NOW, no GPU): virgl + Venus Mesa

**Deliverable.** Build Mesa's **virgl** Gallium driver (`-Dgallium-drivers=virgl`)
+ **Venus** Vulkan driver (`-Dvulkan-drivers=virtio`) for x86_64-solaris,
host-free, proving the `.so`s compile with no GPU and no LLVM. These are the
virtio-gpu guest-side drivers: they encode GL/Vulkan into the virtio-gpu
protocol; the acceleration is host-side. Pairing them with the C1 virtio-gpu DRM
(once §1a's `EXECBUFFER`/3D path lands) yields accelerated GPU on any GPU-having
host.

**Why it compiles without a GPU.** virgl and Venus are protocol encoders, not
rasterizers — they need no LLVM and no local device. Their only kernel
touch-point is the `virtgpu_drm.h` UAPI, and **Mesa bundles that UAPI itself**
(`include/drm-uapi/{drm.h,virtgpu_drm.h}` — the same C1-preserved Linux DRM
UAPI). The only external dependency is a `libdrm` that resolves `xf86drm.h` +
`<drm.h>` and `-ldrm` (host has `xf86drm.h` + `libdrm.so.2` but **no** `drm.h`).

**The build (same C2 standalone pattern + a libdrm shim).** Recipe:
`artifacts/gpu-mesa-c2/build-mesa-virgl-venus.sh`. It reuses the C2 softpipe
recipe (host gcc-14 + venv meson + samurai, the two illumos `u_atomic.h`/
`u_thread.c` patches, `nix-store --add` freeze, RUNPATH edit) and adds:

- a **shim libdrm include dir**: `drm/drm.h` copied from Mesa's own bundled
  `include/drm-uapi/drm.h` (so `xf86drm.h`'s `#include <drm.h>` resolves) + a
  `libdrm.pc` pointing headers at the shim and libs at the host `libdrm.so.2`,
  so `dep_libdrm.found()` is true (the C2 build had to *hide* libdrm because of
  the missing `drm.h`; C3a *supplies* the missing header instead);
- `-Dgallium-drivers=swrast,virgl -Dvulkan-drivers=swrast,virtio` (swrast/
  softpipe kept so the shared gallium aux + Vulkan WSI base build; `virtio` ==
  Venus; the rest of the config matches C2: no LLVM, no GBM/EGL/GLX/X11).

**Build status: virgl + Venus COMPILE host-free on illumos — YES.**
`/nix/store/jm2jc2mmav6i6njhybcv45kv7a9jmh2q-mesa-virgl-venus-24.0.9`, frozen with
`nix-store --add` + gcroot `/root/c2-gcroots/mesa-virgl-venus` (durable in-store;
CDN publish is an orchestrator step — this build node has no signing key / AWS
creds); recipe `artifacts/gpu-mesa-c2/build-mesa-virgl-venus.sh`, paths
`artifacts/gpu-mesa-c2/mesa-virgl-venus-paths.txt`.
- **Venus (`-Dvulkan-drivers=virtio`) — fully built + host-free loadable ICD:**
  `lib/libvulkan_virtio.so` (5.0 MB, EM_AMD64) + `share/vulkan/icd.d/`
  `virtio_icd.x86_64.json` (Vulkan ICD manifest, api 1.3.274). `ldd` with no
  `LD_LIBRARY_PATH` resolves every dependency (store RUNPATH + system libs + the
  host `libdrm.so.2`), zero "not found".
- **virgl (`-Dgallium-drivers=virgl`) — compiled to static libs:** `libvirgl.a`
  (12 objects, the Gallium driver) + `libvirgldrm.a` (the `/dev/dri` DRM winsys);
  `HAVE_VIRGL` defined throughout. The loadable `virtio_gpu_dri.so` is emitted by
  `libgallium_dri`, which needs `-Ddri3`/GBM + a runtime `/dev/dri` device — the
  same GBM-on-metal boundary as C2, so the compile is proven here and the loadable
  driver `.so` is a metal-instance packaging step.
- **The 9 illumos portability findings (all upstreamable, in the recipe):** the
  two C2 patches (`u_atomic.h`, `u_thread.c`) plus — (3) the virgl vtest socket +
  (7) the Venus vtest renderer need `_XPG4_2`+`__EXTENSIONS__` for the `msghdr`
  ancillary-data (`msg_control`/`CMSG_*`, SCM_RIGHTS fd-passing); (4) `virgl_video.c`
  wants `MIN()` from `<sys/param.h>` (BSD/Linux) — illumos keeps it in
  `<sys/sysmacros.h>`; (5) `virgl_context.c`'s `#include <libsync.h>` picks up the
  host header — point it at Mesa's own `util/libsync.h`; (6) `util/libsync.h`'s
  `SYNC_IOC_*` uses `_IOWR`, which on illumos needs `<sys/ioccom.h>`+`<sys/types.h>`;
  (8) Venus `vn_gettid()` uses `syscall(SYS_gettid)` (Linux-only) — use
  `pthread_self()` on `__sun`; (9) Venus `meson.build` omitted `idep_nir`+`idep_vtn`
  — on illumos the static-archive link does not pull NIR/`spirv_to_nir`
  transitively from `idep_vulkan_runtime` the way the GNU-ld link group does on
  Linux, so add both to `vn_deps`.
- **Key libdrm difference from C2 (inverted):** C2 softpipe *hid* libdrm (missing
  `drm.h`); C3a *supplies* the missing `drm/drm.h` from Mesa's own bundled
  `include/drm-uapi/drm.h` so `dep_libdrm.found()` is true (virgl + Venus both
  `#include <xf86drm.h>`). Mesa bundles `drm-uapi/virtgpu_drm.h`, so the virgl/venus
  ioctl UAPI is self-contained (the same C1-preserved Linux DRM UAPI).

**Runtime proof (deferred to metal).** Compiling the `.so`s is the C3a
deliverable and is host-free. An accelerated run needs a QEMU host with
`-device virtio-gpu-gl` (a real host GPU + KVM) driving virglrenderer; this build
node is non-metal (TCG-only), the same constraint as the C1b/C1c scanout proof.
The end-to-end accelerated proof (a virgl GL triangle or a Venus `vulkaninfo` /
llama.cpp-Vulkan run inside a solnix guest, accelerated by the host GPU) is a
metal-instance milestone that also needs §1a's C1 3D `EXECBUFFER` path.

---

## 3b. TTM — the first real-hardware kernel gap (C1 deferred it)

C1 skipped TTM because virtio-gpu (and virtio-gpu 3D, and integrated i915) have
no device-local VRAM. Every discrete GPU (amdgpu, xe dGPU, nouveau) needs it. It
is the single biggest new kernel subsystem for the real-hardware drivers, so it
is scoped here as the C3b design spike (do it alongside the first real driver,
not before — YAGNI until a VRAM GPU is actually targeted):

| TTM concept | illumos mapping (from DESIGN.md §C) |
|---|---|
| system-memory pool | `kmem` / `ddi_umem` pages (reuse C1 GEM backing) |
| VRAM manager (BAR-mapped device memory) | `ddi_regs_map_setup` on the GPU VRAM BAR + `devmap_devmem_setup` for mmap |
| GART / scatter-gather DMA (`ttm_bus_dma`) | `ddi_dma_alloc_handle` / `ddi_dma_addr_bind_handle` / cookies |
| eviction / LRU migration | no direct illumos analogue — bespoke, driven by the ddi_dma + regs layers |

---

## 4. TPU / NPU — far-horizon note

Accelerators like Google **Coral EdgeTPU**, Hailo, and other NPUs are, from the
kernel's view, **PCIe or USB devices with a vendor userspace runtime** — not DRM
GPUs. The framework per device is small and standard:

- **kernel:** a plain illumos **char driver** (`dev_ops`/`cb_ops`) that binds the
  PCIe/USB device, maps its BARs (`ddi_regs_map_setup`), wires interrupts
  (`ddi_intr_*`), and exposes an ioctl/mmap surface — the vendor's UAPI. No DRM,
  no GEM/TTM. (USB EdgeTPU rides the illumos USB framework instead.)
- **userspace:** the vendor runtime (e.g. Coral's `libedgetpu` + the TFLite
  delegate), rebuilt against illumos.

Each is a **per-device port, case by case**, and **far-horizon** relative to the
GPU work — there is no shared shim like DRM to amortize across devices. Noted for
completeness; not on the C3 critical path. Revisit only on concrete demand for a
specific accelerator, and treat each as its own small char-driver + userspace
rebuild.

---

## 5. Summary — the C3 plan

- **Recommended ordering:** **virtio-gpu 3D / Venus first** (§1a) — the only path
  to accelerated GPU with no new kernel hardware driver, on any GPU-having host,
  reusing the C1 virtio-gpu transport + GEM + dma-fence + scheduler + PRIME. The
  C1 gap is a bounded command/ioctl extension (`EXECBUFFER` + `CTX_CREATE` +
  `RESOURCE_CREATE_3D` + `GET_CAPS` + `TRANSFER_*_3D` on the existing
  `virtio_gpu_exec`), call it **C1d**. Then amdgpu (§1b, the fully-open ROCm
  hardware target, biggest surface: PCI + TTM + KMS + rings + KFD), then i915/xe
  (§1c, rides amdgpu's shim), then nouveau/NVK (§1d, GSP is the wall). CUDA is
  out of reach and documented-not-promised.
- **Compute-runtime layer (§2):** lead with **Vulkan-compute** (Venus / RADV /
  ANV / NVK + llama.cpp `GGML_VULKAN`) — one llama.cpp build reaches every vendor
  the moment a DRM node exists, CUDA-free and ROCm-free. ROCm (HIP/rocBLAS, needs
  amdgpu KFD) and oneAPI/Level-Zero (Intel) are the heavier optional tier.
- **Concrete first step (§3, C3a):** build Mesa **virgl + Venus**
  (`-Dgallium-drivers=virgl -Dvulkan-drivers=virtio`) for x86_64-solaris,
  host-free — the same C2 Mesa build plus a libdrm shim (supply the missing
  `drm.h` from Mesa's bundled UAPI). Compiles with no GPU and no LLVM (they are
  protocol encoders; the host renders). Recipe:
  `artifacts/gpu-mesa-c2/build-mesa-virgl-venus.sh`.
- **First real-hardware kernel gap (§3b):** **TTM** (VRAM), which C1 deferred —
  needed by every discrete GPU, scoped to `ddi_regs_map_setup` /
  `devmap_devmem_setup` / `ddi_dma_*` + a bespoke LRU.
- **TPU/NPU (§4):** per-device char-driver + vendor userspace, far-horizon, no
  shared shim; revisit on concrete demand.
- **Metal-instance dependency:** all accelerated *runtime* proofs (C1b/C1c
  scanout, C3a virgl/Venus acceleration) need a QEMU host with a real GPU + KVM;
  this build node is non-metal. The **compile/ABI** milestones (C1 framework,
  C3a virgl/Venus `.so`) are host-free and are what this phase delivers.
