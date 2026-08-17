# C5-ROCr — libhsa-runtime64 (the HSA runtime) on illumos (compile-phase)

The HSA **runtime** layer directly above libhsakmt: ROCr (ROCR-Runtime,
`libhsa-runtime64`, github.com/ROCm/ROCR-Runtime) — the C++ HSA runtime that
turns the raw `hsaKmt*` thunk calls into the HSA API (agents, queues, signals,
memory pools, the AQL dispatch path) that HIP / rocBLAS / an ML runtime sit on.
Built for illumos x86_64 against the solnix libhsakmt (`../ROCM-STATUS.md`).

    HIP / rocBLAS / the accelerated-ML runtime   (application compute)
    ------------------------------------------------------------------
    ROCr (libhsa-runtime64)   <<<<<  THIS layer (C5)   (agents/queues/signals/AQL)
    ------------------------------------------------------------------
    libhsakmt (the HSA kernel-mode thunk)              (C4, hsaKmt* -> ioctls)
    ------------------------------------------------------------------
    /dev/kfd + AMDKFD_IOC_*  (the C3-KFD driver)       (the KFD compute surface)

## What compiled (y/n) + result

- **libhsa-runtime64.so compiled for illumos x86_64: YES.** All **37** core
  runtime `.cpp` (the cmake `SRCS` list, ~24,747 LOC) compile with gcc/g++ 14
  and link to `libhsa-runtime64.so.1` (~1.4 MB, ET_DYN AMD64) against the
  solnix `libhsakmt.so.1`. Reproducible via `build-rocr-solnix.sh` (direct
  g++, no cmake — same approach as `build-libhsakmt-solnix.sh`). **239**
  exported entry points, **186** of them the `hsa_*` HSA API HIP consumes
  (`hsa_init`, `hsa_agent_get_info`, `hsa_queue_create`, `hsa_signal_create`/
  `hsa_signal_wait_scacquire`, `hsa_memory_allocate`,
  `hsa_amd_memory_pool_allocate`, `hsa_amd_agents_allow_access`,
  `hsa_executable_create_alt`/`hsa_executable_load_agent_code_object`,
  `hsa_amd_signal_create`, `hsa_amd_memory_async_copy`, the `hsa_ext_image_*`
  dispatch).

- **Zero-phantom undef audit: YES — every undef real.** `nm -pD
  libhsa-runtime64.so.1` lists **281 undefined dynamic symbols, ZERO
  phantom.** `audit-undef-rocr.sh` classifies every one against a real illumos
  library:
    - **35 `hsaKmt*`** → the solnix `libhsakmt.so.1` (the C4 thunk):
      `hsaKmtOpenKFD`, `hsaKmtGetVersion`, `hsaKmtAcquireSystemProperties`,
      `hsaKmtGetNodeProperties`/`...Memory`/`...IoLink`/`...Cache`,
      `hsaKmtAllocMemory`/`hsaKmtMapMemoryToGPU`/`hsaKmtMapMemoryToGPUNodes`/
      `hsaKmtFreeMemory`, `hsaKmtCreateQueue`/`DestroyQueue`/`UpdateQueue`,
      `hsaKmtCreateEvent`/`WaitOnEvent`/`WaitOnMultipleEvents`/`SetEvent`,
      the SVM/IPC/register-memory + CU-mask + trap-handler entry points.
    - **145 C++ ABI** (`_Z*`, `__cxa_*`, `__gxx_*`, `_Unwind_*`) →
      `libstdc++.so.6` / `libgcc_s.so.1` (the g++ 14 runtime); `__cxa_atexit`/
      `__cxa_finalize` live in illumos **libc**.
    - **~20 `elf_*`/`gelf_*`** → `/lib/64/libelf.so.1` (the code-object ELF
      reader — libamdhsacode).
    - **17 `pthread_*`** → libpthread; **`dl*`** (`dlopen`/`dlsym`/`dladdr`/
      `dlinfo`/`dl_iterate_phdr`) → libc/libdl; **`sendfile`** →
      `/lib/64/libsendfile.so.1`; the rest (`mmap`/`open`/`read`/`sysconf`/
      `clock_gettime`/`shm_open`/`posix_fallocate`/`posix_memalign`/stdio/
      string) → libc.
    - **3 crt/TLS hooks** (`_ITM_registerTMCloneTable`/`_deregister`,
      `__tls_get_addr`) — the compiler-runtime/TLS symbols bound at the final
      process image (same as libhsakmt / RADV / ANV).

  `audit-undef-rocr.sh` prints `zero-phantom OK: all undef resolve to real
  illumos libs`. Same doctrine as the C4 libhsakmt (59-undef/zero-phantom) and
  the RADV/ANV `.so` audits.

## The comgr / LLVM situation: NOT NEEDED for the rocm-4.2.0 core

The anti-wedge worry (comgr/LLVM as a heavy code-object dependency) **does not
apply** to the rocm-4.2.0 ROCr core. The code-object loader here is
`libamdhsacode` — ROCr's **own libelf-based ELF reader** (`amd_elf_image.cpp`/
`amd_hsa_code.cpp` + `loader/executable.cpp`), NOT amd_comgr/LLVM. `grep -ril
"comgr|amd_comgr|LLVM"` over the whole `src/` tree returns **nothing**. So the
core HSA runtime + the code-object loader both build with just `libelf` — no
LLVM, no comgr, no `-DBUILD_COMGR=OFF` needed. (comgr/LLVM only enters the
picture higher up, at HIP's **runtime kernel JIT** — see the HIP next step.)
The optional `image/` addrlib (texture/image support) was **not** built this
pass; the `hsa_ext_image_*` interface dispatch table is present (stub-linked
via `hsa_ext_interface.cpp`), and image support is a separable
hardware/texture concern, not a core-compute gate.

## LOC

    ROCr core compiled (37 .cpp, cmake SRCS list)   ~24,747   (upstream rocm-4.2.0, all but 47 lines unmodified)
    ---------------------------------------------------------------------------
    solnix adaptation (this port):
      solnix-rocr-compat.h        49   CLOCK_MONOTONIC_RAW->CLOCK_HIGHRES, <alloca.h>, the linux/limits note
      linux/limits.h               2   <linux/limits.h> -> <limits.h> shim
      build-rocr-solnix.sh       107   the g++ build recipe (no cmake)
      audit-undef-rocr.sh         42   the zero-phantom audit
    ---------------------------------------------------------------------------
    solnix adaptation total        200   LOC
    + 47 lines of #ifdef __sun deltas across 3 upstream .cpp (source-patches/)

## The illumos adaptations (what the port touched)

The HSA runtime is portable C++; the illumos work is the compat shims plus a
**47-line `#ifdef __sun` delta across 3 source files** (`source-patches/
rocr-cpp-solnix.patch`), no compute logic rewritten:

1. **`core/util/lnx/os_linux.cpp` (the OS backend).** Three portability
   spellings: (a) `struct sysinfo{totalram,mem_unit}` is glibc-only and
   collides with illumos's own unrelated `<sys/sysinfo.h>` struct — replaced
   `GetUsablePhysicalHostMemorySize()` with the portable
   `sysconf(_SC_PHYS_PAGES) * sysconf(_SC_PAGESIZE)`; (b) `CLOCK_MONOTONIC_RAW`
   is Linux-only — mapped to illumos `CLOCK_HIGHRES` (the equivalent
   high-resolution monotonic clock) in the compat header; (c) bare `utsname`
   → `struct utsname` (illumos requires the struct tag). Behavior-preserving:
   the clock/memory queries return the same physical facts.

2. **`loader/executable.cpp` (the GDB debug-map).** The code-object loader
   maintains a GDB rendezvous symbol (`_amdgpu_r_debug`) using glibc's
   `r_debug::RT_*` scoped-enum spelling. illumos `<sys/link.h>` declares
   `RT_CONSISTENT`/`RT_ADD`/`RT_DELETE` as **unscoped** `r_state_e`
   enumerators, so the `r_debug::` scope qualifier is dropped under `__sun`
   (the 5-field `r_debug` initializer + `r_map`(`Link_map*`)/`l_next`/`l_prev`/
   `l_name` link-map fields all match illumos's layout). This is a
   GDB-debug-only bookkeeping symbol, not a compute path.

3. **`core/runtime/amd_aql_queue.cpp` (the queue-full workaround).**
   `__NR_gettid` (a Linux syscall number, no illumos equivalent) is used only
   to name a per-thread shm segment in the `queue_full_workaround_` path —
   which is the **APU / HSA_PROFILE_FULL** path a discrete dGPU (the V520) never
   takes. Under `__sun` the unique id comes from `pthread_self()`. The
   companion `__NR_memfd_create` is dead (guarded by `HAVE_MEMFD_CREATE`, which
   is not defined; it falls to `shm_open`).

4. **`solnix-rocr-compat.h` (force-included).** Supplies `CLOCK_MONOTONIC_RAW`
   → `CLOCK_HIGHRES` and pulls in `<alloca.h>` (illumos puts `alloca` there,
   not in `<stdlib.h>` — the same fix the C4 libhsakmt used; several ROCr
   sources call `alloca` relying on the glibc convenience).

5. **`linux/limits.h` shim.** `amd_hsa_loader.cpp` includes `<linux/limits.h>`
   (the Linux spelling); the 2-line shim on the include path forwards to
   `<limits.h>` (PATH_MAX/NAME_MAX), the only thing used.

## What is compile-complete vs HARDWARE-GATED

**Compile-complete (builds + links + exports the full HSA API, off-hardware):**
- the whole ROCr **core** (37 units): the agent model (`amd_cpu_agent`/
  `amd_gpu_agent`), the topology reader (`amd_topology.cpp` — built on the
  libhsakmt `hsaKmtAcquireSystemProperties`/`GetNodeProperties`), the memory
  regions/pools (`amd_memory_region`), the AQL queue + doorbell path
  (`amd_aql_queue`/`host_queue`/`queue`), signals (`default_signal`/
  `interrupt_signal`/`ipc_signal`), the blit copy paths (`amd_blit_kernel`/
  `amd_blit_sdma`), the HSA API surface (`hsa.cpp`/`hsa_ext_amd.cpp`/
  `hsa_api_trace`), and the libelf code-object loader
  (`loader/`+`libamdhsacode/`).
- the full `hsa_*` + `hsa_amd_*` + `hsa_ext_*` export table (239 entry points).

**HARDWARE-GATED (needs a powered V520 / g4ad + the C3/C4 runtime pieces):**
- **`hsa_init` topology enumeration** — `amd_topology.cpp` calls
  `hsaKmtAcquireSystemProperties`/`hsaKmtGetNodeProperties`, which on illumos
  need the libhsakmt **/sys topology shim** (`../ROCM-STATUS.md` Option A) to
  return real gfx10 node data at `hsaKmtOpenKFD`. This is the one runtime
  prerequisite carried up from C4; without it `hsa_init` finds no GPU agent.
- **live AQL dispatch** — the queue doorbell mmap + HWS/MES submit are
  hardware-gated at the C3-KFD kernel layer (`../../amdkfd/KFD-STATUS.md`).
- **memory-pool alloc → GPUVM map** — `hsa_amd_memory_pool_allocate` →
  `hsaKmtAllocMemory`/`MapMemoryToGPU` → the C3-amdgpu TTM/GART path,
  hardware-gated.
- **code-object load onto an agent** — `hsa_executable_load_agent_code_object`
  compiles + parses ELF off-hardware; the actual ISA load into VRAM is gated.
- **`hsa_ext_image_*`** — the image/addrlib support was not built; the
  interface is stub-linked. Texture/image is a separable hardware concern.

## The HIP / rocBLAS next step (what sits on ROCr)

With ROCr compiling zero-phantom, the next layer is **HIP** (the CUDA-like C++
runtime, github.com/ROCm/HIP + the clr/ROCclr backend) and then **rocBLAS**
(the accelerated BLAS — the ML/compute workload). What HIP needs from ROCr
(all present + exported here):

1. **The `hsa_*` HSA core** — `hsa_init`, agent enumeration
   (`hsa_iterate_agents`/`hsa_agent_get_info`), `hsa_queue_create` + the AQL
   ring, `hsa_signal_*` (HIP streams/events map onto HSA signals),
   `hsa_memory_*`/`hsa_amd_memory_pool_*` (the HIP device allocator). ✓ all
   exported.
2. **`hsa_amd_*` extensions** — `hsa_amd_memory_async_copy` (HIP
   `hipMemcpyAsync`), `hsa_amd_agents_allow_access` (peer/host access),
   `hsa_amd_signal_create`, `hsa_amd_profiling_*`. ✓ exported.
3. **The code-object loader** — `hsa_executable_create_alt` +
   `hsa_executable_load_agent_code_object` load a compiled AMDGPU code object
   (the `.hsaco` a HIP kernel becomes). ✓ compiled (libelf loader).

**The one HIP-layer heavy dependency is comgr/LLVM — at HIP's RUNTIME KERNEL
JIT, not at ROCr.** HIP's `hiprtc` (runtime compilation) and the code-object
manager compile GPU kernels at runtime via **amd_comgr → LLVM/clang → the
AMDGPU backend**. That is where the LLVM wall the task warned about actually
sits. Two ways past it (both a future pass, LLVM is not built this pass):
  - **AOT (ahead-of-time) only first:** a GGML/ML workload whose kernels are
    **precompiled** to `.hsaco` off-node (or on a Linux build host) needs only
    ROCr's code-object loader (present) + HIP's dispatch — **no runtime LLVM**.
    This is the fastest path to a first accelerated kernel on illumos.
  - **Full hiprtc:** build amd_comgr + LLVM/clang with the AMDGPU target for
    illumos — a large port (LLVM's own illumos support is decent, but it is a
    multi-thousand-file build). Defer until AOT dispatch works on hardware.

rocBLAS ships **precompiled** GPU kernels (Tensile-generated `.co`), so
rocBLAS-on-HIP-on-ROCr with AOT kernels is a compute path that needs **no
runtime LLVM** — the natural "as fast as Linux" first target once the topology
shim + a powered V520 make `hsa_init` enumerate the GPU. Do NOT attempt HIP/
LLVM this pass (runtime is g4ad-gated; LLVM is huge). ROCr compiling
zero-phantom on libhsakmt is the HSA-runtime milestone, exactly as the C4
libhsakmt unblocked this layer.

## Build + verify (on the node)

    bash /root/rocr-build/build-rocr-solnix.sh    # -> libhsa-runtime64.so.1
    bash /root/rocr-build/audit-undef-rocr.sh     # zero-phantom audit

Requires: the solnix `libhsakmt.so.1` at `/root/drm-port/rocm/build`, the
patched ROCT-Thunk headers at `/root/ROCT-Thunk-Interface/include/hsakmt`, the
RADV libdrm build at `/var/tmp/libdrm-out`, libelf on the node, and the ROCr
source at `/root/ROCR-Runtime` (rocm-4.2.0, `337e3e5`) with the 47-line
`source-patches/rocr-cpp-solnix.patch` + the `solnix-rocr-compat.h`/`linux/
limits.h` shims applied.

Result: **37 units compile, libhsa-runtime64.so.1 (~1.4 MB) links, 281 undef,
ZERO phantom, 239 exports (186 `hsa_*`).**

## Files (src/drm-port/rocm/rocr/)

    solnix-rocr-compat.h            CLOCK_HIGHRES / alloca force-include shim
    linux/limits.h                  <linux/limits.h> -> <limits.h> shim
    build-rocr-solnix.sh            the g++ build recipe (no cmake)
    audit-undef-rocr.sh             the zero-phantom audit
    undef-audit.txt                 the 281-undef list (audit input)
    source-patches/
      rocr-cpp-solnix.patch         the 47-line #ifdef __sun delta (3 .cpp)
    rocr-git-rev.txt                ROCR-Runtime rev (rocm-4.2.0 337e3e5)
    README.md                       this file

## Crib provenance

ROCr is ROCm's ROCR-Runtime (github.com/ROCm/ROCR-Runtime, tag rocm-4.2.0, rev
`337e3e5`) — the version matched to the ROCT-Thunk 1.9.0/`06a9b94` libhsakmt was
cribbed from, sharing the KFD ABI. No compute `.c/.cpp` logic is rewritten —
the port is the two force-included shims plus a 47-line `#ifdef __sun` delta
across 3 files (os backend clock/memory spelling, the GDB debug-map enum scope,
the APU-only gettid). The code-object loader is `libamdhsacode` (libelf), **not**
comgr/LLVM, so the core builds with no LLVM dependency. It dlopen's/links the C4
libhsakmt, whose `hsaKmt*` map 1:1 onto the C3-KFD `AMDKFD_IOC_*` (v1.14).
