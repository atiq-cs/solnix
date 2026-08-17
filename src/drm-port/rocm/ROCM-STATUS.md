# C4-ROCm — libhsakmt (the HSA/KFD thunk) userspace on illumos (compile-phase)

The ROCm/HIP **accelerated-compute userspace entry point** on illumos:
**libhsakmt** — the HSA kernel-mode thunk (ROCT-Thunk-Interface) — built for
illumos x86_64 against the solnix KFD UAPI. This is the layer directly above
the C3-KFD kernel driver (`/dev/kfd` + `AMDKFD_IOC_*`, see
`../amdkfd/KFD-STATUS.md`): the `hsaKmt*` functions map **1:1** onto the KFD
ioctls the C3-KFD driver dispatches, because the ABI (`kfd_ioctl.h`) is the
same v1.14 crib on both sides. ROCr (the HSA runtime) dlopen's this library;
HIP/rocBLAS sit above ROCr.

    HIP / rocBLAS / the accelerated-ML runtime   (application compute)
    ------------------------------------------------------------------
    ROCr (libhsa-runtime64)                       (queues, signals, memory)
    ------------------------------------------------------------------
    libhsakmt (the HSA kernel-mode thunk)  <<<<<  THIS layer (C4)
    ------------------------------------------------------------------
    /dev/kfd + AMDKFD_IOC_*  (the C3-KFD driver)  (the KFD compute surface)
    ------------------------------------------------------------------
    C3-amdgpu device (BARs / TTM / rings / BAR2 doorbell)  +  C1 DRM

## What compiled (y/n) + result

- **libhsakmt.so compiled for illumos x86_64: YES.** All 17 thunk source
  files (`src/*.c`, ~13,503 LOC) compile with gcc 14 and link to
  `libhsakmt.so.1` (~217 KB, ET_DYN AMD64). Clean rebuild is reproducible via
  `build-libhsakmt-solnix.sh`. The **full** `hsaKmt*` API surface is present
  and exported: **88** `hsaKmt*` entry points, including every one the KFD
  path needs — `hsaKmtOpenKFD`, `hsaKmtGetVersion`, `hsaKmtCreateQueue`,
  `hsaKmtAllocMemory`/`hsaKmtAllocMemoryAlign`, `hsaKmtMapMemoryToGPU`/
  `hsaKmtMapMemoryToGPUNodes`, `hsaKmtAcquireSystemProperties`,
  `hsaKmtGetNodeProperties`.

- **Zero-phantom undef audit: YES — every undef real.** `nm -p -D
  libhsakmt.so.1` lists **59 undefined dynamic symbols, ZERO phantom**. Every
  one resolves to a real illumos library (libc / libpthread / libdl —
  ioctl/mmap/pthread/dlsym/stdio/string) or the DRM userspace
  (libdrm/libdrm_amdgpu, from the RADV libdrm build:
  `amdgpu_device_initialize`/`amdgpu_device_deinitialize`/`amdgpu_query_gpu_info`/
  `amdgpu_get_marketing_name`/`drmOpenRender`/`drmClose`), or the
  compiler-runtime crt (`_ITM_*`/`__cxa_finalize`, resolved at the consumer's
  final link). `audit-undef.sh` prints
  `zero-phantom OK: all undef resolve to real illumos libs`.

- **The /sys topology reader: COMPILES (string-literal paths); runtime port
  DOCUMENTED, not yet built (hardware-gated).** `topology.c` compiles cleanly —
  the `/sys/devices/virtual/kfd/...` paths are string literals that only matter
  when `hsaKmtOpenKFD` runs. The runtime sysfs surface is a solnix gap (illumos
  has no `/sys`); the shim design is specified below. Runtime is g4ad-gated, so
  this compile-phase pass documents the port rather than building the live shim.

## LOC

    ROCT thunk C compiled (src/*.c, 17 files)     ~13,503   (upstream, unmodified .c)
    ---------------------------------------------------------------------------
    solnix adaptation (this port):
      solnix-compat.h          39   alloca<->stdlib, MADV_* Linux hints -> 0, force-included
      numa.h                   33   libnuma stub (numa_available()==-1 -> binding no-ops)
      numaif.h                 27   mbind()/MPOL_* stub (never reached at runtime)
      linux/perf_event.h       24   just PERF_EVENT_IOC_* for perfctr.c
      linux-ioctl-compat.h     36   the Linux _IOC encoding (shared with RADV/ANV)
      build-libhsakmt-solnix.sh 44  the build recipe (gcc, no cmake)
      audit-undef.sh           37   the zero-phantom audit
    ---------------------------------------------------------------------------
    solnix adaptation total                          240   LOC

Plus a **3-line delta** to two shipped thunk headers (the entire source-code
change to the upstream thunk):

    include/hsakmt/linux/kfd_ioctl.h:
      -#include <libdrm/drm.h>          +#include "solnix-ioctl-compat.h"
      -#include <linux/ioctl.h>         (removed; the _IOC macros come from the shim)
    include/hsakmt/hsakmttypes.h:
      -#elif defined(__linux__)         +#elif defined(__linux__) || defined(__sun)

The `_IOC` shim (`solnix-ioctl-compat.h`, a copy of `linux-ioctl-compat.h`)
supplies both the `__u32`/`__s32` types and the Linux `_IO*` encoding macros
the thunk header formerly pulled from `<libdrm/drm.h>` + `<linux/ioctl.h>`.
Because it re-expresses the **same** Linux `_IOC` bit layout the C3-KFD
kernel's `kfd_ioctl.h` uses (base `'K'`), the `AMDKFD_IOC_*` command numbers
this library emits match the numbers the kernel switches on — the same
ABI-preservation payoff RADV/ANV get from the C1 `drm.h`.

## The illumos adaptations (what the port actually touched)

The KFD ABI is already ours, so this was a **bounded** port — the entire
illumos work is header shims + one typedef guard, no `.c` logic rewritten:

1. **The `_IOC` encoding.** The thunk header included `<libdrm/drm.h>` and
   `<linux/ioctl.h>` only for the `_IO*` macros + `__u32` types. Swapped for
   the existing `linux-ioctl-compat.h` shim (RADV/ANV/C1 use the same one).
   `kmtIoctl()` (`libhsakmt.c`) is `ioctl(fd, request, arg)` verbatim —
   portable to illumos; the request numbers come from the shim.

2. **The `__linux__` typedef guard.** `hsakmttypes.h` gates the `HSAuint*`
   typedefs on `__linux__ || _WIN*`; illumos (`__sun`) hit neither. Widened the
   guard to `__linux__ || __sun` (the branch just aliases `uint*_t`). This was
   the **only** `__linux__` in the entire codebase.

3. **`alloca` + Linux `madvise` hints (`solnix-compat.h`, force-included).**
   `alloca` lives in `<alloca.h>` on illumos (not `<stdlib.h>`).
   `MADV_DONTFORK`/`MADV_HUGEPAGE`/`MADV_DONTDUMP` are Linux-only madvise hints
   (fork-COW / THP / coredump); illumos madvise has no equivalent, so they map
   to `0` (a no-op advice value). These are fork/coredump/THP-behavior corners,
   **not** compute-correctness ones — the queue/memory still map to the GPU.

4. **libnuma stub (`numa.h`/`numaif.h`).** `fmm.c`'s `bind_mem_to_numa()` uses
   libnuma only to pin a host allocation to the NUMA node nearest a GPU — a
   locality optimization. illumos has no libnuma/`mbind` userspace API, so the
   stub reports `numa_available()==-1`; `bind_mem_to_numa()` then returns early
   without binding, the correct degradation (memory is still allocated + mapped,
   just not NUMA-pinned). The illumos analogue if wanted later is
   `lgroup(3LGRP)`, a host perf knob outside the KFD ABI.

5. **`linux/perf_event.h` stub.** `perfctr.c` (the `hsaKmtPmc*` HW
   performance-counter path) includes it only for the two
   `PERF_EVENT_IOC_ENABLE/DISABLE` ioctl numbers — it does **not** call
   `perf_event_open()` nor use `struct perf_event_attr`. The stub supplies just
   those constants. The counters themselves are hardware-gated.

6. **libdrm headers.** `topology.c`/`fmm.c` include `<amdgpu.h>`/
   `<amdgpu_drm.h>`/`xf86drm.h` for the DRM render-node open + `amdgpu_device_*`
   BO sharing. Satisfied from the RADV libdrm build already on the node
   (`/var/tmp/libdrm-out/include/libdrm`), and those undefs resolve to that
   build's `libdrm_amdgpu.so` at link/load.

## The zero-phantom undef audit (all 59 undefs, every one real)

`nm -p -D libhsakmt.so.1` (`U` = undefined), each classified by `audit-undef.sh`:

- **libc (POSIX/stdio/string/mem/dir):** `atoi calloc close closedir errno
  fclose fgets fopen fprintf fputc fread free fscanf fwrite get_nprocs getenv
  getpid ioctl madvise malloc memcmp memcpy memset mmap munmap open opendir
  read readdir realloc snprintf sprintf sscanf strchr strcmp strerror strlen
  strncmp strncpy strtok strtol sysconf __assert_c99 __iob` — all in
  `/lib/64/libc.so.1` (`get_nprocs` is a real illumos libc symbol, declared in
  `<unistd.h>`; `__iob`/`__assert_c99` are the illumos stdio/assert internals).
- **libpthread:** `pthread_atfork pthread_mutex_init pthread_mutex_lock
  pthread_mutex_unlock`.
- **libdl:** `dlsym dlerror`.
- **libdrm / libdrm_amdgpu (the RADV libdrm build):** `drmOpenRender drmClose
  amdgpu_device_initialize amdgpu_device_deinitialize amdgpu_query_gpu_info
  amdgpu_get_marketing_name`.
- **compiler-runtime crt (resolved into any consumer at final link):**
  `__cxa_finalize _ITM_registerTMCloneTable _ITM_deregisterTMCloneTable`.

**Result: 59 undef, 0 phantom.** Same doctrine as the C3-KFD kernel module's
131-undef/zero-phantom link and the RADV/ANV `.so` audits.

## The /sys topology port (the one runtime gap) — DESIGN

`topology.c` reads the KFD topology from Linux sysfs
(`/sys/devices/virtual/kfd/kfd/topology/{system_properties,generation_id,
nodes/<n>/{gpu_id,properties,mem_banks/*,caches/*,io_links/*}}`) via
`fopen`+`fscanf` of simple `key value` text files. `hsaKmtOpenKFD` →
`topology_sysfs_get_system_props` → returns `HSAKMT_STATUS_ERROR` on illumos
because those paths don't exist. This is the single functional runtime gap; the
compile is complete. Two ways to close it (both runtime, hardware-gated):

**Option A — a sysfs-shim directory the C3-KFD driver populates (least code in
the thunk).** Have the C3-KFD kernel driver (or a small userspace helper that
issues `GET_PROCESS_APERTURES` + `GET_VERSION` + reports the gfx10 V520 node)
write the same `key value` text files under a solnix path (e.g.
`/system/kfd/topology/...` or `/var/run/kfd/topology/...`), then change the
five `KFD_SYSFS_PATH_*` `#define`s in `topology.c` to that root. The thunk's
parser is unchanged. This mirrors Linux most faithfully and is the smallest
thunk delta.

**Option B — a KFD `GET_TOPOLOGY` ioctl the thunk calls instead of `fopen`.**
Add a KFD ioctl that returns the node/mem-bank/cache/io-link records as a
struct array (the same data the kernel already computes for
`GET_PROCESS_APERTURES` plus static gfx10 CU/SIMD counts), and replace
`topology_sysfs_get_system_props`/`_get_node_props`/`_get_iolink_props` bodies
with `kmtIoctl` calls. More thunk code, but no filesystem surface and the
topology comes straight from the driver that already knows the device.

**Recommendation: Option A** — it keeps the thunk parser intact (change only 5
path macros), reuses the KFD ioctl data the C3-KFD driver already produces, and
matches the Linux layout so an upstream thunk bump stays a 5-line re-point. The
node/mem-bank/cache/io-link fields for the single gfx10 V520 node are exactly
what `../amdkfd/kfd_device.c` already computes for the apertures ioctl.

## What is compile-complete vs HARDWARE-GATED

**Compile-complete (builds + links + exports the full ABI, off-hardware):**
- the whole `libhsakmt.so` (all 17 units, 88 `hsaKmt*` exports),
- the `/dev/kfd` open + `GET_VERSION` gate (`openclose.c`/`version.c`) — the
  version negotiation matches the C3-KFD 1.14 report,
- `hsaKmtCreateQueue`/`DestroyQueue` (`queues.c`), the memory manager
  (`fmm.c`/`memory.c` — alloc/map/unmap ioctl wrappers), events (`events.c`),
  SVM (`svm.c`), the doorbell/ring bookkeeping, the topology **parser**,
- the `_IOC` encoding equivalence (the `AMDKFD_IOC_*` numbers this `.so` emits
  == the numbers the C3-KFD kernel switches on, both from the same v1.14 crib).

**HARDWARE-GATED (needs firmware + a powered V520 / g4ad, the C3-amdgpu-d gate),
or a runtime shim:**
- the **/sys topology read at `hsaKmtOpenKFD`** — needs the sysfs shim (Option
  A) or a `GET_TOPOLOGY` ioctl (Option B) above; without it `hsaKmtOpenKFD`
  fails at the topology step.
- the **doorbell mmap + live HWS/MES dispatch** for a created queue — already
  hardware-gated at the C3-KFD kernel layer (`../amdkfd/KFD-STATUS.md`).
- the **GPUVM PTE program** behind `MAP_MEMORY_TO_GPU` — the C3-amdgpu-d gart
  path, hardware-gated.
- the **HW performance counters** (`perfctr.c`) — need the amdgpu PMU + powered
  GPU; the enable/disable ioctls compile, the counters are hardware-gated.
- **libnuma binding** — degraded to a no-op on illumos (correct; not a compute
  gate).

## The ROCr / HIP next step (what sits on libhsakmt)

With libhsakmt compiling zero-phantom, the next userspace layer is **ROCr**
(ROCR-Runtime, `libhsa-runtime64`, github.com/ROCm/ROCR-Runtime) — the HSA
runtime that **dlopen's libhsakmt** and turns the raw `hsaKmt*` thunk into the
HSA API (queues, signals, memory pools, agents) that HIP consumes. What ROCr
needs from this library (all present + exported here):

1. **`hsaKmtOpenKFD` / `hsaKmtGetVersion`** — ROCr opens the KFD and gates on
   the 1.14 ABI. ✓ (needs the topology shim to return success at runtime).
2. **`hsaKmtAcquireSystemProperties` + `hsaKmtGetNodeProperties` +
   `hsaKmtGetNodeMemoryProperties`/`...IoLinkProperties`** — ROCr builds its
   agent/memory-pool/topology model from these. ✓ compile; **the topology shim
   (Option A) is the prerequisite** for these to return real gfx10 data.
3. **`hsaKmtAllocMemory` / `hsaKmtMapMemoryToGPU` / `hsaKmtFreeMemory`** — ROCr
   memory pools + the HIP allocator. ✓ compile (backed by C3-amdgpu TTM).
4. **`hsaKmtCreateQueue` / `hsaKmtDestroyQueue` + the doorbell** — ROCr's HSA
   queues (AQL dispatch). ✓ compile; the doorbell mmap + live dispatch are
   hardware-gated.
5. **`hsaKmtCreateEvent` / `hsaKmtWaitOnEvent`** — ROCr signals. ✓ compile.

Then **HIP** (github.com/ROCm/HIP + clr) on ROCr, then **rocBLAS** — the
accelerated-ML runtime. ROCr is the immediate next port target; the topology
shim (Option A) is the one runtime piece to build alongside it so
`hsaKmtOpenKFD` succeeds on a powered node. Do NOT attempt ROCr/HIP this pass
(runtime is g4ad-gated); libhsakmt compiling zero-phantom is the ROCm-userspace
milestone, exactly as the C3-KFD kernel port unblocked this layer.

## Build + verify (on the node)

    /root/drm-port/rocm/build-libhsakmt-solnix.sh   # -> build/libhsakmt.so.1
    /root/drm-port/rocm/audit-undef.sh              # zero-phantom audit

Requires the RADV libdrm build present at `/var/tmp/libdrm-out` (headers + the
libdrm/libdrm_amdgpu `.so`) and the patched ROCT-Thunk-Interface at
`/root/ROCT-Thunk-Interface` (the 3-line header delta above).

Result: **17 units compile, libhsakmt.so.1 (~217 KB) links, 59 undef, ZERO
phantom, 88 hsaKmt* exports.**

## Files (src/drm-port/rocm/)

    solnix-compat.h              alloca/MADV_* force-include shim
    numa.h                       libnuma stub (binding no-ops)
    numaif.h                     mbind/MPOL_* stub
    linux/perf_event.h           PERF_EVENT_IOC_* stub for perfctr.c
    linux/solnix-ioctl-compat.h  the _IOC shim (for the perf stub's include)
    linux-ioctl-compat.h         the Linux _IOC encoding (copy of RADV/ANV's)
    build-libhsakmt-solnix.sh    the gcc build recipe (no cmake)
    audit-undef.sh               the zero-phantom audit
    thunk-header-patches/        the 3-line delta reference + thunk git rev
    ROCM-STATUS.md               this file

The thunk source itself lives at `/root/ROCT-Thunk-Interface` on the node
(github.com/ROCm/ROCT-Thunk-Interface @ 06a9b94), with only the 3-line header
delta applied; every `.c` is upstream-unmodified.

## Crib provenance

libhsakmt is ROCm's ROCT-Thunk-Interface (github.com/ROCm/ROCT-Thunk-Interface,
rev 06a9b94). No `.c` logic is rewritten — the port is the header shims above
plus a 3-line delta to two shipped headers. The KFD ABI it drives is the
verbatim v1.14 crib shared with the C3-KFD kernel (`../amdkfd/uapi/kfd_ioctl.h`),
so the thunk's `AMDKFD_IOC_*` numbers match the kernel's dispatch keys. The
`_IOC` shim + libdrm dependency reuse the C1/RADV/ANV port infrastructure.
