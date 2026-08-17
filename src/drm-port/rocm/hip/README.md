# C6-HIP — libamdhip64 (the HIP runtime) on illumos, the AOT dispatch path (compile-phase)

The **final userspace layer** of the ROCm compute stack on illumos: HIP (the
CUDA-like C++ runtime, `libamdhip64`, github.com/ROCm/HIP + the ROCclr backend),
built for illumos x86_64 on the solnix ROCr (`../rocr/README.md`). This is the
layer an accelerated-ML workload (GGML's HIP backend, rocBLAS) actually calls.

    GGML-HIP / rocBLAS / the accelerated-ML workload   (application compute)
    ----------------------------------------------------------------------
    HIP (libamdhip64) + ROCclr   <<<<<  THIS layer (C6)   (device/stream/module/launch)
    ----------------------------------------------------------------------
    ROCr (libhsa-runtime64)                              (C5, agents/queues/signals/AQL)
    ----------------------------------------------------------------------
    libhsakmt (the HSA kernel-mode thunk)                (C4, hsaKmt* -> ioctls)
    ----------------------------------------------------------------------
    /dev/kfd + AMDKFD_IOC_*  (the C3-KFD driver)         (the KFD compute surface)

**The AOT insight (carried up from ROCr).** HIP has two kernel paths:
(1) the **AOT** path — load a **precompiled** `.hsaco` code object via ROCr's
loader + dispatch it through an hsa AQL queue, needing **no LLVM**; and
(2) **hiprtc** — the runtime JIT that compiles kernel source via
amd_comgr → LLVM/clang. This port builds path (1) and **defers path (2)** — the
whole point of the AOT path is that GGML/rocBLAS ship precompiled Tensile
`.hsaco` kernels, so the accelerated-compute path is reachable without porting
the multi-thousand-file LLVM.

## What compiled (y/n) + result

- **libamdhip64.so compiled for illumos x86_64: YES.** All **68** core units
  (~42,269 LOC of ROCclr + HIP `rocclr/`, the cmake `oclruntime_src` +
  `device/rocm/*` + the HIP AOT runtime) compile with g++ 14 and link to
  `libamdhip64.so.5` (~8.9 MB, ET_DYN AMD64) against the solnix
  `libhsa-runtime64.so.1` (C5) + `libhsakmt.so.1` (C4). Reproducible via
  `build-hip-solnix.sh` (direct g++, no cmake — same approach as
  `build-rocr-solnix.sh`). **248** public `hip*` C API entry points are
  exported, including the complete AOT dispatch path: `hipInit`,
  `hipGetDeviceCount`/`hipSetDevice`, `hipCtx*`, `hipStreamCreate`,
  `hipMalloc`/`hipMemcpyHtoD`/`hipMemcpyDtoH`, and the module/kernel path
  `hipModuleLoad`/`hipModuleLoadData`/`hipModuleGetFunction`/
  `hipModuleLaunchKernel`/`hipModuleUnload`.

- **hiprtc / LLVM / comgr SKIPPED (deferred): YES.** No LLVM, no clang, no
  amd_comgr library is built or linked. `hip_rtc.cpp` (the runtime JIT) is
  excluded from the build. comgr is only referenced through ~90
  function-pointer typedefs (`device/comgrctx.hpp`) whose library
  (`libamd_comgr.so.2`) ROCclr **dlopen's at runtime**
  (`device/comgrctx.cpp:36`) — never at link time. The audit asserts
  `amd_comgr link: 0`. Only `amd_comgr.h` (a header) is needed to compile the
  shared `device::Program` base; see `inc/amd_comgr.h.NOTE.md`.

- **Zero-phantom undef audit: YES — every undef real.** `nm -pD
  libamdhip64.so.5` lists **384 undefined dynamic symbols, ZERO phantom**.
  `audit-undef-hip.sh` classifies every one against a real illumos library or
  the solnix ROCm layers:
    - **70 `hsa_*`** → the solnix ROCr `libhsa-runtime64.so.1` (C5): the AOT
      loader (`hsa_executable_create_alt`,
      `hsa_code_object_reader_create_from_memory`,
      `hsa_executable_load_agent_code_object`, `hsa_executable_freeze`,
      `hsa_executable_get_symbol_by_name`,
      `hsa_executable_symbol_get_info`), the AQL queue path
      (`hsa_queue_create`, `hsa_queue_load_write_index_*`,
      `hsa_signal_*`), memory (`hsa_amd_memory_pool_allocate`,
      `hsa_amd_memory_async_copy`, `hsa_amd_agents_allow_access`), and agent
      enumeration (`hsa_iterate_agents`, `hsa_agent_get_info`).
    - **194 C++ ABI** (`_Z*`, std::string/stream/vector/mutex members) →
      `libstdc++.so.6`; **20 cxa/gxx/Unwind/ITM/tls** →
      `libstdc++`/`libgcc_s`/libc; the `_ZTH*` entries are GCC per-TLS
      `__tls_init` thunks for HIP's own thread-locals (`hip::g_lastError`/
      `hip::g_device`), emitted WEAK-undefined and bound internally — the same
      class as `__tls_get_addr`, not a phantom.
    - **15 `pthread_*`** → libpthread; **3 `dl*`** → libc/libdl; the rest
      (libc stdio/string/mem/`mmap`/`sysconf`/`getenv`/`getpid`, libm
      `pow`/`copysign`, librt `shm_open`, libc `sem_*`/`thr_stksegment`/
      `getexecname`/`environ`) → libc/libm/librt.
    - **0 `amd_comgr_*`, 0 LLVM** — the AOT-path proof: no JIT dependency.

  `audit-undef-hip.sh` prints `zero-phantom OK: all undef resolve to real
  illumos libs / ROCr / libhsakmt; no comgr/LLVM link dep`. Same doctrine as
  the C5 ROCr (281/0) and C4 libhsakmt (59/0).

## The AOT-dispatch link proof

`hip-aot-dispatch-proof.cpp` is a tiny HIP program that walks the whole
precompiled-kernel path — `hipModuleLoad(.hsaco)` → `hipModuleGetFunction` →
`hipMalloc`/`hipMemcpyHtoD` → `hipModuleLaunchKernel` (a vector-add). It
**cannot RUN off-hardware** (`hipInit` enumerates no GPU agent without a
powered V520), but it **compiles + LINKS** against `libamdhip64.so.5` +
`libhsa-runtime64.so.1` + `libhsakmt.so.1`, and every AOT symbol resolves:

    hipModuleLoad      -> hsa_code_object_reader_create_from_memory
                          + hsa_executable_load_agent_code_object   (rocprogram.cpp)
    hipModuleGetFunction -> hsa_executable_get_symbol_by_name
                          + HSA_EXECUTABLE_SYMBOL_INFO_KERNEL_OBJECT (rockernel.cpp)
    hipModuleLaunchKernel -> the hsa AQL dispatch packet on an hsa_queue
                          + doorbell + hsa_signal                    (rocvirtual.cpp)

`ldd hip-aot-dispatch-proof` resolves `libamdhip64.so → libhsa-runtime64.so →
libhsakmt.so`. **The precompiled-kernel → HIP → ROCr → KFD → GPU dispatch path
is compile-complete end to end** — the accelerated-compute path that avoids the
LLVM port.

## LOC

    HIP core compiled (68 units: ROCclr oclruntime_src + device/rocm + HIP rocclr)
                                                  ~42,269   (upstream rocm-4.2.0, all but 47 lines unmodified)
    ---------------------------------------------------------------------------
    solnix adaptation (this port):
      solnix-hip-compat.h        79   CLOCK_HIGHRES, <alloca.h>, cpu_set_t/affinity no-ops,
                                      pthread_getattr_np via thr_stksegment, environ, REG_RIP/basename includes
      shim/sys/prctl.h            9   PR_SET_NAME no-op (cosmetic thread naming)
      inc/hip_version.h          13   synthesized hip_version.h (cmake-generated upstream)
      build-hip-solnix.sh        87   the g++ build recipe (no cmake)
      audit-undef-hip.sh         56   the zero-phantom audit
      hip-aot-dispatch-proof.cpp 72   the AOT link proof
    ---------------------------------------------------------------------------
    solnix adaptation total       316   LOC
    + 47 lines of source delta (source-patches/): 33 across 11 ROCclr files,
      14 across 2 HIP files -- all #ifdef __sun / guard-widening / one profiler-off
      knob, no compute logic rewritten.

## The illumos adaptations (what the port touched)

HIP/ROCclr are portable C++; the illumos work is one force-included compat
header + a `sys/prctl.h` shim + a 47-line source delta, none of it on the
compute path:

1. **The POSIX/Linux guard widening (`#if defined(__linux__)` →
   `... || defined(__sun)`).** ROCclr's `os.hpp`/`thread.hpp`/`semaphore.hpp`/
   `context.cpp`/`elf.cpp`/`options.*`/`macros.hpp` gate the POSIX branch on
   `__linux__`; illumos (`__sun`) hit the Windows `#else`. Widened the guards so
   `__sun` follows the Linux/POSIX branch (`sem_t`, the TLS `currentThread`, the
   affinity mask, `LP64_SWITCH`). This is the exact doctrine the C4 libhsakmt
   used for its one `__linux__` typedef guard.

2. **`os/os_posix.cpp` (the OS backend), 3 `#ifdef __sun` edits.**
   (a) `getPhysicalMemSize()` — glibc `struct sysinfo`/`sysinfo()` collide with
   the unrelated illumos `<sys/sysinfo.h>`; replaced with
   `sysconf(_SC_PHYS_PAGES) * sysconf(_SC_PAGESIZE)` (same substitution ROCr's
   `os_linux.cpp` uses). (b) `getAppPathAndFileName()` — no `/proc/self/exe` on
   illumos; use `getexecname()`. Both behavior-preserving.

3. **`solnix-hip-compat.h` (force-included).** Supplies the Linux spellings
   illumos lacks: `CLOCK_MONOTONIC_RAW` → `CLOCK_HIGHRES` (the same monotonic
   high-res map ROCr used); `<alloca.h>` (illumos puts `alloca` there);
   `<libgen.h>`/`<sys/regset.h>`/`<ucontext.h>` (basename / `REG_RIP` /
   `getcontext` — `REG_RIP` needs `-m64`); `extern "C" char **environ`; and the
   **cpu-affinity no-op shim** — `cpu_set_t`/`CPU_*`/`pthread_*_setaffinity_np`
   have no illumos equivalent and are used only to pin worker threads across all
   CPUs (a locality hint, not compute); they degrade to a dummy mask + success
   returns (illumos schedules across all CPUs by default). `pthread_getattr_np`
   (glibc, used only to guess a thread's stack extent for a div-by-zero signal
   walk — diagnostic) maps to illumos `thr_stksegment()`. Same doctrine as the
   C4 libhsakmt's libnuma no-op.

4. **`shim/sys/prctl.h`.** `os_posix.cpp` uses `prctl(PR_SET_NAME, name)` only
   for cosmetic thread naming; illumos has no `prctl`, so the shim defines
   `PR_SET_NAME` + a no-op `prctl` (thread names are a debugging nicety).

5. **The profiler-off knob (`platform/activity.hpp` + 2 HIP headers).** ROCclr
   hardcodes `#define USE_PROF_API 1` (the ROCprofiler tracing layer). Made it
   `#ifndef`-overridable and set `-DUSE_PROF_API=0` — the tracing layer is not
   on the AOT compute path and is telemetry-off by house doctrine. With it off,
   `HIP_INIT_API`'s `HIP_CB_SPAWNER_OBJECT` becomes a no-op, so the runtime does
   not depend on the cmake-generated per-API-id `hip_prof_str.h`. Two HIP
   headers needed matching guards: `hip_formatting.hpp` (the `hip_api_id_t`
   stream operators) and `hip_prof_api.h` (the disabled-path stub class gains
   no-op `is_enabled()`/`set_enabled()` + a stub `hip_api_name`, so the
   profiler-registration API surface still compiles).

6. **Synthesized/copied generated headers** (`inc/hip_version.h`,
   `gen/hip/amd_detail/hip_prof_str.h`, `inc/amd_comgr.h`, the
   `gen/amdocl/cl_gl_amd.hpp` symlink) — the pieces cmake would generate;
   `amd_comgr.h` is header-only (comgr is runtime-dlopen, see NOTE).

## What is compile-complete vs HARDWARE-GATED

**Compile-complete (builds + links + exports the full AOT API, off-hardware):**
- the whole HIP core (device/context/stream/event/memory + the module/kernel
  AOT path) on ROCclr's HSA backend (`device/rocm/*`),
- the AOT dispatch chain end to end (the link proof): `hipModuleLoad` →
  ROCr's `hsa_executable_load_agent_code_object` → `hipModuleLaunchKernel` →
  the hsa AQL packet,
- the 248-entry public `hip*` C API export table,
- the zero-phantom link (no LLVM/comgr dependency).

**HARDWARE-GATED (needs a powered V520 / g4ad + the C3/C4/C5 runtime pieces):**
- **`hipInit`/`hipGetDeviceCount`** — enumerates ROCr agents, which need the
  C5 `hsa_init` → C4 libhsakmt **/sys topology shim** (`../ROCM-STATUS.md`
  Option A) to see the gfx10 node. Off-hardware there is no agent, so the AOT
  proof links but does not run.
- **live AQL dispatch** — the queue doorbell mmap + HWS/MES submit are gated at
  the C3-KFD kernel layer.
- **`hipMalloc` → GPUVM map** — the C3-amdgpu TTM/GART path.
- **the actual `.hsaco` ISA load into VRAM** — parses off-hardware, loads gated.
- **hiprtc / texture / graph / cooperative-groups APIs** — deferred (hiprtc
  needs LLVM; texture/graph are separable, not the AOT compute core).

## The rocBLAS / GGML-HIP next step (the "as fast as Linux" compute proof)

With `libamdhip64` compiling zero-phantom on ROCr, an accelerated GGML/rocBLAS
workload is **compile-reachable via the AOT path, no LLVM**:

- **rocBLAS** ships **precompiled** GPU kernels (Tensile-generated `.co`/
  `.hsaco`). rocBLAS-on-HIP loads them through `hipModuleLoad` →
  `hsa_executable_load_agent_code_object` (present) and dispatches via
  `hipModuleLaunchKernel` → hsa AQL (present). No runtime LLVM: rocBLAS's own
  C++ builds like ROCclr did, and its kernels are already `.hsaco`.
- **GGML's HIP backend (`GGML_HIP`/`GGML_HIPBLAS`)** dispatches its kernels via
  HIP + rocBLAS. This is the ROCm equivalent of the `GGML_VULKAN` path solnix
  already builds — the accelerated-inference "as fast as Linux" proof. Its HIP
  kernels are precompiled to `.hsaco` off-node (or on a Linux build host) by
  `hipcc`/`clang`, so the runtime needs only ROCr's loader + HIP dispatch — the
  compile-complete AOT path here.

The single runtime prerequisite carried up the whole stack is the libhsakmt
**/sys topology shim** (`../ROCM-STATUS.md` Option A), so `hsaKmtOpenKFD` →
`hsa_init` → `hipInit` enumerate the gfx10 V520 on a powered g4ad. Then the
precompiled-kernel path (rocBLAS/GGML-HIP → HIP → ROCr → KFD → GPU) runs. Do
NOT port LLVM/comgr — the AOT path avoids it; that is the entire point.

## Build + verify (on the node)

    bash /root/hip-build/build-hip-solnix.sh     # -> libamdhip64.so.5
    bash /root/hip-build/audit-undef-hip.sh      # zero-phantom audit
    # AOT link proof:
    g++ -m64 -std=c++14 -D__HIP_PLATFORM_AMD__ -D__HIP_PLATFORM_HCC__ \
      -I/root/HIP/include -I/root/HIP/include/hip -I/root/hip-build/gen \
      hip-aot-dispatch-proof.cpp -o hip-aot-dispatch-proof \
      -L/root/hip-build -lamdhip64 -L/root/rocr-build -lhsa-runtime64 \
      -L/root/drm-port/rocm/build -lhsakmt \
      -L/var/tmp/libdrm-out/lib -ldrm -ldrm_amdgpu -lsendfile -lelf -lpthread -ldl -lrt

Requires: the solnix ROCr (`/root/rocr-build/libhsa-runtime64.so.1`, C5),
libhsakmt (`/root/drm-port/rocm/build/libhsakmt.so.1`, C4), the RADV libdrm
(`/var/tmp/libdrm-out`), libelf, g++ 14, and the HIP + ROCclr source at
`/root/HIP` (rocm-4.2.0 `37cb3a3`) + `/root/ROCclr` (rocm-4.2.0 `f343e8f`) with
the `source-patches/` deltas + the shims applied, plus the generated headers
under `/root/hip-build/{inc,gen}` (see `build-hip-solnix.sh` header + NOTEs).

Result: **68 units compile, libamdhip64.so.5 (~8.9 MB) links, 384 undef, ZERO
phantom, 0 comgr/LLVM link dep, 248 public `hip*` exports, the AOT-dispatch
proof links.**

## Files (src/drm-port/rocm/hip/)

    solnix-hip-compat.h              CLOCK_HIGHRES / alloca / affinity-noop / thr_stksegment shim
    shim/sys/prctl.h                 PR_SET_NAME no-op
    inc/hip_version.h                synthesized hip_version.h (rocm-4.2.0)
    inc/amd_comgr.h.NOTE.md          how to obtain the header-only comgr crib
    build-hip-solnix.sh              the g++ build recipe (no cmake)
    audit-undef-hip.sh               the zero-phantom audit
    hip-aot-dispatch-proof.cpp       the AOT (.hsaco load + launch) link proof
    undef-audit.txt                  the 384-undef list (audit input)
    source-patches/
      rocclr-hip-solnix.patch        the 33-line #ifdef __sun / guard delta (11 ROCclr files)
      hip-rocclr-solnix.patch        the 14-line profiler-off guard delta (2 HIP files)
    git-revs.txt                     HIP / ROCclr / comgr upstream revs
    README.md                        this file

The HIP + ROCclr source lives at `/root/HIP` + `/root/ROCclr` on the node, with
only the `source-patches/` deltas applied; every other `.cpp` is
upstream-unmodified. libamdhip64.so.5 is built at `/root/hip-build`.

## Crib provenance

HIP is ROCm's github.com/ROCm/HIP (tag rocm-4.2.0, rev `37cb3a3`) + ROCclr
(github.com/ROCm/ROCclr, tag rocm-4.2.0, rev `f343e8f`) — the version matched
to the ROCr rocm-4.2.0 (`337e3e5`) this stack builds on. `amd_comgr.h` is the
header-only crib from ROCm-CompilerSupport rocm-4.2.0 (`f3e8145`); the comgr
*library* is never linked (runtime dlopen only). No compute `.cpp` logic is
rewritten — the port is the compat shims plus a 47-line `#ifdef __sun` / guard /
profiler-off delta. It links the C5 ROCr `libhsa-runtime64`, whose `hsa_*` map
onto the C4 libhsakmt `hsaKmt*`, which map 1:1 onto the C3-KFD `AMDKFD_IOC_*`
(v1.14). The AOT dispatch path uses only ROCr's libelf code-object loader — no
LLVM, no comgr — exactly as the ROCr README's AOT insight predicted.
