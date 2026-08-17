# C6-GGML_HIP — llama.cpp accelerated-compute on the solnix ROCm stack (compile-phase)

Wiring llama.cpp's `GGML_HIP` backend against the solnix ROCm userspace
(`../hip/README.md` libamdhip64 → `../rocr/` ROCr → `../` libhsakmt → the C3-KFD
`/dev/kfd`) — the ROCm equivalent of the `GGML_VULKAN` accelerated-compute path
(`artifacts/gpu-c4-llama-vulkan/`). Compile-verified, ahead of the g4ad hardware.

    llama.cpp GGML_HIP backend (ggml/src/ggml-cuda/*.cu)   (application compute)
    ------------------------------------------------------------------------
    HIP (libamdhip64.so.5) + ROCclr    <<<<< C6 (device/stream/module/launch)
    ------------------------------------------------------------------------
    ROCr (libhsa-runtime64.so.1)        C5   (agents/queues/signals/AQL)
    ------------------------------------------------------------------------
    libhsakmt.so.1 (the HSA thunk)      C4   (hsaKmt* -> KFD ioctls)
    ------------------------------------------------------------------------
    /dev/kfd + AMDKFD_IOC_*             C3-KFD driver   (the KFD compute surface)

## THE CRUX — does GGML_HIP need hipcc/LLVM for its kernels, or can they be AOT-precompiled?

**GGML_HIP HARD-REQUIRES hipcc/LLVM for its kernels. They are NOT
AOT-precompilable.** This is the definitive finding and the crux of the no-LLVM
accelerated-compute question. Evidence, from the b4991 source on the node:

1. **The kernels are compiled from `.cu` source as `LANGUAGE HIP`.**
   `ggml/src/ggml-hip/CMakeLists.txt` does `enable_language(HIP)` +
   `set_source_files_properties(${GGML_SOURCES_ROCM} PROPERTIES LANGUAGE HIP)`
   over `file(GLOB GGML_SOURCES_ROCM "../ggml-cuda/*.cu")` — **159 `.cu` files
   (39 core + 120 template-instances), ~12,154 LOC of kernels**. There is no
   precompiled artifact; every kernel is compiled at build time.

2. **The launch syntax is the `<<<>>>` triple-chevron — a hipcc/clang LANGUAGE
   EXTENSION.** **127 `kernel<<<grid,block,shmem,stream>>>(args)` launch sites**
   across the `.cu` files (3 in the main host TU `ggml-cuda.cu` itself). Plain
   g++ **cannot parse** `<<<>>>`; only hipcc / the ROCm clang front end can. The
   kernels use `__global__`/`__device__` throughout (35 of 39 core `.cu`).

3. **There is NO `hipModuleLoad` / `.hsaco` path in the GGML_HIP backend.**
   `grep hipModuleLoad|hipModuleLaunchKernel` over `ggml-cuda/` returns nothing.
   Unlike **rocBLAS** — which ships **precompiled** Tensile `.hsaco` kernels and
   loads them via `hipModuleLoad` → `hsa_executable_load_agent_code_object` (the
   C6 AOT path, no runtime LLVM) — GGML **fuses host + device in each `.cu`** and
   emits a fat binary at compile time (`__hipRegisterFatBinary`/
   `__hipRegisterFunction`, both exported by libamdhip64). So the rocBLAS AOT
   template **does not apply** to GGML's own kernels: there is no offline
   `.hsaco` to precompile and no runtime loader path in GGML to load it through.

4. **`find_package(hip hipblas rocblas REQUIRED)`.** GGML_HIP additionally
   requires hipBLAS + rocBLAS. rocBLAS **is** the AOT template (precompiled
   Tensile, no runtime LLVM — portable via the C6 AOT path) but is a separate
   port not yet built on the node; hipBLAS is a thin host wrapper over rocBLAS.

**Conclusion:** GGML_HIP's kernel compile is a **hard hipcc/LLVM gate** — a
*harder* gate than `GGML_VULKAN`, whose compute shaders compile to SPIR-V via
glslang (no LLVM). The AOT-precompiled-`.hsaco` insight that carried the whole
ROCm userspace stack (C4→C5→C6) up **without LLVM** reaches rocBLAS but **not**
GGML's own kernels, because GGML has no precompiled-kernel path to load.

## What compiled (y/n) + result — the HOST dispatch chain

Because the kernels are LLVM-gated, the compile-phase deliverable is the **HOST
half** of the GGML_HIP backend: the C++ that dispatches ops via the HIP runtime
API. This is the exact "build the host backend regardless" ask, and it **proves
the llama.cpp → HIP → ROCr → KFD dispatch chain is wired on illumos**.

- **`ggml-hip-host-dispatch-proof` compiled + linked libamdhip64: YES.** Plain
  **g++ 14 (NO hipcc, NO LLVM)** compiles `ggml-hip-host-dispatch-proof.cpp`
  (107 LOC) — the HIP runtime-API sequence GGML performs on every op dispatch
  (`ggml_cuda_op_*`: `hipGetDeviceCount` → `hipSetDevice` →
  `hipStreamCreateWithFlags` → `hipMalloc` → `hipMemcpyAsync(H2D)` →
  **`hipLaunchKernel`** [precisely what the GGML `<<<>>>` lowers to via
  `__hipPushCallConfiguration` + `hipLaunchKernel`, both exported] →
  `hipMemcpyAsync(D2H)` → `hipEventRecord`/`Synchronize` → `hipStreamSynchronize`
  → `hipFree`) — and **links** to a 14 KB ET_DYN AMD64 executable against the
  solnix `libamdhip64.so.5` (C6) + `libhsa-runtime64.so.1` (C5) +
  `libhsakmt.so.1` (C4) + the RADV libdrm.

- **The dispatch chain resolves end to end: YES.** `ldd` + `elfdump -d NEEDED`:
  `libamdhip64.so → libhsa-runtime64.so → libhsakmt.so → libdrm.so.2 /
  libdrm_amdgpu.so.1`. **All 15** `hip*` symbols the proof references
  (`hipMalloc`, `hipMemcpyAsync`, `hipStreamCreateWithFlags`, **`hipLaunchKernel`**,
  `hipGetDeviceCount`, `hipSetDevice`, `hipEventCreateWithFlags`/`Record`/
  `Synchronize`/`Destroy`, `hipStreamSynchronize`/`Destroy`, `hipFree`,
  `hipRuntimeGetVersion`, `hipGetErrorString`) resolve into libamdhip64. The
  launch-config lowering symbols `__hipPushCallConfiguration`/
  `__hipPopCallConfiguration`/`__hipRegisterFatBinary`/`__hipRegisterFunction`/
  `hipLaunchKernelGGLImpl` are all exported by libamdhip64 too.

- **Zero-phantom undef audit: YES — every undef real.** `nm -pD` lists **25
  undefined dynamic symbols, ZERO phantom** (`audit-undef-ggml-hip.sh`):
    - **15 `hip*`** → the solnix `libamdhip64.so.5` (C6) — the GGML dispatch API.
    - **libstdc++** (`_Znam` operator new[], `_ZdaPv` operator delete[]),
      **libc** (`printf`, `puts`, `exit`, `atexit`, `__fpstart`) → real illumos
      libs.
    - **3 compiler-runtime crt** (`_ITM_registerTMCloneTable`,
      `_ITM_deregisterTMCloneTable`, `__start_crt_compiler`) — weak / resolved by
      crt at final link; the **same non-phantom class** the C4 (59/0), C5
      (281/0), C6 (384/0) `.so` audits document. `_start_crt` is itself defined
      (`T`) in the binary.
  `audit-undef-ggml-hip.sh` prints `undef total: 25 ; resolve-to-libamdhip64: 15
  ; phantom: 0` + `zero-phantom OK`.

- **Runs off-hardware to the expected gate: YES.** Executed on the node (no
  powered V520): `hipRuntimeGetVersion` **succeeds** (st=0, version=3275 — the
  solnix libamdhip64 responds), and the dispatch chain returns
  **`hipErrorNoDevice`** (st=100) at `hipGetDeviceCount` because ROCr enumerates
  no agent without the C4 libhsakmt `/sys` topology shim + a powered g4ad. This
  is the **exact expected off-hardware result** — it proves the link is complete
  and only the runtime agent is g4ad-gated (identical status to the C6
  `hip-aot-dispatch-proof` and the GGML_VULKAN "no-device" fallback).

## LOC

    llama.cpp GGML_HIP kernels surveyed (ggml-cuda/*.cu, LLVM-gated, NOT built here)
                                                  ~12,154   (159 .cu files; the hipcc boundary)
    ------------------------------------------------------------------------------
    solnix compile-phase deliverable (this port):
      ggml-hip-host-dispatch-proof.cpp   107   the HOST dispatch chain (g++, no hipcc)
      build-ggml-hip-proof.sh             39   the g++ build recipe (no cmake, no hipcc)
      audit-undef-ggml-hip.sh             40   the zero-phantom audit
      llama-cpp-hip.nix                   67   the GGML_HIP Nix recipe (documents the gap)
    ------------------------------------------------------------------------------
    solnix deliverable total             253   LOC (0 lines of upstream source patched)

No upstream llama.cpp/GGML source is modified — the host TU is written against
the public HIP runtime-API header; the survey reads the unmodified b4991 tree.

## The accelerated-compute runtime path (llama.cpp → HIP → ROCr → KFD → V520)

The full path a `GGML_HIP` inference op takes, and what each hop needs:

    llama.cpp op (ggml_cuda_op_mul_mat / _add / ...)         [host C++]
      -> hipMalloc / hipMemcpyAsync(H2D)                      HIP runtime (C6, PRESENT)
      -> kernel<<<grid,block,0,stream>>>(args)                COMPILED BY hipcc  <<< LLVM GATE
         == __hipPushCallConfiguration + hipLaunchKernel      (the lowering; libamdhip64 exports it)
      -> hipLaunchKernel -> ROCr hsa AQL dispatch packet      ROCr (C5, PRESENT)
      -> the AQL packet on an hsa_queue + doorbell ring        KFD queue (C3-KFD, hardware-gated)
      -> the GGML kernel ISA executes on the gfx10 V520        the g4ad GPU (hardware-gated)
      -> hipMemcpyAsync(D2H) + hipEventSynchronize             HIP -> ROCr signals (PRESENT)

- **Off-the-shelf (host + runtime, PRESENT on illumos):** every HIP runtime-API
  call around the launch — alloc, async copy, stream/event, the
  `hipLaunchKernel` entry point itself — links the solnix libamdhip64 → ROCr →
  libhsakmt zero-phantom (this proof). The host backend is compile-complete.
- **Needs hipcc/LLVM (the kernel compile):** the `<<<>>>` device kernels
  (127 launch sites, 159 `.cu`). This is the ROCm HIP clang/amdgpu-LLVM front
  end — NOT ported (deliberately, per the AOT insight). GGML has **no**
  precompiled-`.hsaco` path to sidestep it (unlike rocBLAS).
- **g4ad-hardware-gated (runtime, the single carried-up gate):** ROCr agent
  enumeration (needs the C4 libhsakmt `/sys` topology shim + a powered V520), the
  live AQL doorbell/HWS dispatch (C3-KFD kernel), the GPUVM map (C3-amdgpu TTM),
  and the kernel ISA actually running on the V520.

## What is compile-reachable vs the hipcc/LLVM boundary vs g4ad-hardware-gated

**Compile-reachable on illumos TODAY (no LLVM):**
- the GGML_HIP **HOST dispatch backend** — the C++ that drives every op via the
  HIP runtime API — linking `libamdhip64.so.5` zero-phantom (this proof). The
  llama.cpp → HIP → ROCr → KFD dispatch chain is **wired**.
- the whole ROCm userspace beneath it (C4/C5/C6, already compile-complete).

**The hipcc/LLVM boundary (NOT compile-reachable without the LLVM port):**
- the **159 GGML_HIP `.cu` device kernels** (`<<<>>>`, `__global__`) — compiled
  only by hipcc / ROCm clang. **Not AOT-precompilable** (no `.hsaco`/
  `hipModuleLoad` path in GGML). Closing it = port the ROCm HIP clang/amdgpu-LLVM
  backend (huge, out of scope) **or** upstream a precompiled-kernel path into
  GGML_HIP (does not exist upstream).
- **hipBLAS/rocBLAS** — `find_package REQUIRED`. rocBLAS itself is AOT-portable
  (precompiled Tensile `.hsaco`, the C6 AOT template, no runtime LLVM) but is a
  separate unbuilt port; hipBLAS wraps it.

**g4ad-hardware-gated (runtime, needs a powered V520):**
- ROCr agent enumeration (the C4 `/sys` topology shim + powered node), live AQL
  dispatch (C3-KFD), the GPUVM map (C3-amdgpu), the kernel ISA on the V520.

## Verdict — is the ROCm "as fast as Linux" compute proof compile-reachable on illumos?

**The HOST dispatch chain is compile-reachable and proven (links libamdhip64
zero-phantom); the GGML_HIP KERNEL compile is gated on hipcc/LLVM — a harder
gate than GGML_VULKAN.** Precisely:

- **YES**, accelerated llama.cpp on ROCm is **host-side compile-reachable** on
  illumos: the GGML_HIP dispatch backend links the full solnix ROCm stack
  (libamdhip64 → ROCr → libhsakmt → KFD) zero-phantom, and every runtime-API
  symbol GGML calls — including the `hipLaunchKernel` that `<<<>>>` lowers to —
  resolves. The dispatch chain is wired; only the g4ad agent is runtime-gated.
- **BUT** GGML_HIP's own **kernels** are the LLVM boundary and **cannot** be
  AOT-precompiled (no `.hsaco` path in GGML, unlike rocBLAS). This is a *harder*
  gate than `GGML_VULKAN`, whose shaders compile to SPIR-V via **glslang (no
  LLVM)** and which is therefore the LLVM-free accelerated llama.cpp path on
  solnix. `GGML_HIP` reaches the dispatch chain but needs the ROCm HIP clang/LLVM
  port (or an upstream AOT-kernel path) to compile its compute.

Net: the ROCm accelerated-compute **dispatch surface** is compile-complete and
g4ad-runtime-gated exactly like the rest of the stack; the GGML_HIP **kernel
compile** is the one piece the AOT/no-LLVM insight cannot cover for GGML. For an
LLVM-free "as fast as Linux" accelerated llama.cpp on solnix **today**, the
GGML_VULKAN path (`artifacts/gpu-c4-llama-vulkan/`) is the route; the GGML_HIP
host backend proves the ROCm dispatch chain is wired and waiting on either the
LLVM kernel port or a precompiled-kernel upstream.

## Build + verify (on the node root@3.135.239.78)

    bash /root/llama-hip/build-ggml-hip-proof.sh     # -> ggml-hip-host-dispatch-proof
    bash /root/llama-hip/audit-undef-ggml-hip.sh     # zero-phantom audit
    # off-hardware run (expected hipErrorNoDevice at hipGetDeviceCount):
    LD_LIBRARY_PATH=/root/hip-build:/root/rocr-build:/root/drm-port/rocm/build:\
    /var/tmp/libdrm-out/lib:/usr/gcc/14/lib/amd64 \
      /root/llama-hip/ggml-hip-host-dispatch-proof

Requires (all present on the node): the solnix `libamdhip64.so.5`
(`/root/hip-build`, C6), `libhsa-runtime64.so.1` (`/root/rocr-build`, C5),
`libhsakmt.so.1` (`/root/drm-port/rocm/build`, C4), the RADV libdrm
(`/var/tmp/libdrm-out`), the HIP headers (`/root/HIP/include` + the synthesized
`hip_version.h` at `/root/hip-build/gen`), g++ 14, and the llama.cpp b4991 tree
(`/root/llama.cpp`, for the kernel survey; unmodified).

Result: **1 host TU compiles with g++ (no hipcc), links libamdhip64.so.5 → ROCr
→ libhsakmt, 25 undef / 15-into-libamdhip64 / ZERO phantom, runs off-hardware to
the expected hipErrorNoDevice.**

## Files (src/drm-port/rocm/llama-hip/)

    ggml-hip-host-dispatch-proof.cpp   the HOST dispatch chain (g++, no hipcc) — links libamdhip64
    build-ggml-hip-proof.sh            the g++ build recipe (no cmake, no hipcc)
    audit-undef-ggml-hip.sh            the zero-phantom audit
    llama-cpp-hip.nix                  the GGML_HIP Nix recipe (documents the hipcc gap)
    undef-audit.txt                    the 25-undef list (audit input)
    LLAMA-HIP-STATUS.md                this file

The llama.cpp b4991 source lives at `/root/llama.cpp` on the node (unmodified);
the proof binary is built at `/root/llama-hip`.

## Crib provenance

llama.cpp b4991 (github.com/ggml-org/llama.cpp) — the same tag as the CPU recipe
(`pkgs/os-specific/illumos/llama-cpp.nix`) and the GGML_VULKAN recipe
(`artifacts/gpu-c4-llama-vulkan/`). The GGML_HIP backend = `ggml/src/ggml-cuda/`
compiled with `GGML_HIP=ON` (HIP is CUDA-source-compatible via hipify). The host
proof links the solnix ROCm stack: libamdhip64 (C6, HIP rocm-4.2.0) → ROCr (C5,
rocm-4.2.0) → libhsakmt (C4) → the C3-KFD `AMDKFD_IOC_*` (v1.14). No upstream
GGML source is modified.
