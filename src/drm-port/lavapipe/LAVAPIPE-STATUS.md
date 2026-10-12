# solnix lavapipe — STATUS (C2 software Vulkan, RUNTIME-PROVEN)

## What this is

Mesa **lavapipe** (software Vulkan, `libvulkan_lvp.so`) + **llvmpipe** (software GL,
LLVM JIT) built and **proven running** on x86_64-illumos. This is the honest C2
"software Vulkan" milestone: a real CPU Vulkan 1.4 device on solnix, NOT hardware
acceleration (no `/dev/dri`, no GPU — `docs/graphics-claims-audit.md` REFUTED hardware
RADV/Vulkan; this does not reclaim it). It is the cross-vendor API substrate COSMIC
(wgpu-GL) and llama.cpp GGML_VULKAN consume; the same ICD mechanism binds a real GPU
once a hardware DRM render node (the C1 keystone + RADV/ANV/NVK) exists.

## Proven (2026-10-12, on the clean build-host AMI `ami-0aa1f6ac952e3408d`)

| Item | Result |
|---|---|
| Mesa 25.1.4 lavapipe builds on illumos | **YES** — gcc-14 + LLVM 20.1.8 → `libvulkan_lvp.so` 15.6MB, Vulkan **1.4.311** ICD + `lvp_icd.x86_64.json` |
| lavapipe ENUMERATES a Vulkan device | **YES** — `device[0] = "llvmpipe (LLVM 20.1.8, 256 bits)"` → `LAVAPIPE_ENUMERATED_PASS` (`lvp-direct-proof.c`) |
| negative control (enumeration) | **HOLDS** — a non-ICD lib (libc/libz) finds no `vk_icdGetInstanceProcAddr`, no device |
| a Vulkan COMPUTE shader runs + verifies | **YES** — `out[i]=in[i]*2` over 1024 elems → `COMPUTE_VERIFY_PASS` (`lvp-compute-proof.c`, SPIR-V from glslang) |
| negative control A (compute) | **HOLDS** — wrong expected multiplier → `COMPUTE_VERIFY_FAIL` (the checker CAN fail) |
| negative control B (compute) | **HOLDS** — non-ICD lib → no device (no silent pass) |
| survives the AMI bake | **YES** — a fresh instance from `ami-0aa1f6ac952e3408d` re-runs both proofs PASS |

## The reproducible derivation

- `scripts/build-mesa-lavapipe-illumos.sh` — the deterministic host build.
- `pkgs/mesa-lavapipe-illumos.nix` (solnix-pkgs) — staged-path wrapper (eval-checked).
- `docs/registry/recipes.tsv` — `mesa-lavapipe` (hostbuild-stage) + `mesa-lavapipe-illumos`
  (staged-wrap) rows.
- Mesa+LLVM don't build through the nixpkgs fork, so this is a host-build-then-bank
  derivation — the same pattern as the from-source Rust toolchain
  (`docs/rust-illumos-bootstrap.md`).

## illumos portability cuts for Mesa 25.1.4 (beyond the softpipe 24.0.9 set)

1. `src/util/u_atomic.h` — gate the `__sun` Solaris-atomic backend on `!__GNUC__` (use
   gcc `__atomic` intrinsics). *(reuse from softpipe)*
2. `src/util/u_thread.c` — `!__sun` on the `pthread_getcpuclockid` guard. *(reuse)*
3. `meson.build:133` — remove `'sunos'` from `system_has_kms_drm` (the software path has
   no libdrm/`/dev/dri`; otherwise Mesa hard-requires libdrm). **NEW, upstreamable.**
4. `include/renderdoc_app.h` — `RENDERDOC_CC` empty on `__sun` (was `#error "Unknown
   platform"`). **NEW, upstreamable.**
5. build args: `-DHAVE_STRUCT_TIMESPEC=1 -DHAVE_SECURE_GETENV=1` (illumos has both with
   `__EXTENSIONS__`; meson's probe missed them) + `-Wno-error=incompatible-pointer-types
   -Wno-error=pointer-sign` (int8_t vs signed char, same as the RADV build) +
   `-Dgallium-rusticl=false` (drops the Rust requirement — lavapipe/llvmpipe need no Rust).

## Build-tool wrapper insight (load-bearing)

meson/cmake **sanitize the subprocess env** when they spawn compilers/tools, so a scratch
pkg-image binary that needs `LD_LIBRARY_PATH` for its own libs (gcc's libs, bison's
`libtextstyle`, etc.) gets an empty-output or SIGKILL in the probe even though it runs by
hand. Fix: thin wrappers (`/root/ccwrap/{gcc,g++,bison,flex}`) that set `LD_LIBRARY_PATH`
and `exec` the real binary; point the meson native-file + PATH at the wrappers.

## The direct-ICD proof harnesses (committed)

`lvp-direct-proof.c` and `lvp-compute-proof.c` dlopen `libvulkan_lvp.so` and drive Vulkan
via the ICD's `vk_icdGetInstanceProcAddr` → `vkGetDeviceProcAddr` chain — proving the
device + compute WITHOUT needing the Khronos loader built (which was blocked on this base
by the scratch-2026 cmake SIGSYS'ing on the 2025 kernel). `double.comp` is the compute
shader (glslang → SPIR-V). These are the exact harnesses that ran PASS.

## Follow-up (honest, not done this session)

- **llama.cpp GGML_VULKAN tok/s** (`scripts/llama-vulkan-lavapipe-bench.sh`): wire the
  proven lavapipe ICD under llama.cpp Vulkan, measure tok/s vs the ~70 tok/s C0 CPU
  baseline. Needs the Vulkan loader (`libvulkan.so.1`) + a GGML_VULKAN build — both cmake,
  both blocked on this base by the 2026-cmake/2025-kernel SIGSYS. Do it on a
  `pkg update`'d (2026-kernel) node, OR pull the already-published `vulkan-loader-1.3.280`
  store path. HONEST EXPECTATION: software Vulkan JITs on the CPU, so it may be *slower*
  than llama.cpp's tuned AVX2 CPU path — the point is the Vulkan-compute PATH runs
  end-to-end in software; MEASURE and report the real number.
- `nix-store --add` the staged lavapipe tree + fill the `recipes.tsv` `out`/`sha256`
  columns (needs nix on the build node).
