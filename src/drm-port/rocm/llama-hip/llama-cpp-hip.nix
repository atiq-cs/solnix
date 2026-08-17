# llama-cpp-hip.nix -- solnix C6 recipe: llama.cpp GGML_HIP backend on illumos
# x86_64, the ROCm accelerated-compute path. The ROCm sibling of the C4
# GGML_VULKAN recipe (artifacts/gpu-c4-llama-vulkan/llama-cpp-vulkan.nix).
#
# ============================================================================
# THE CRUX (read LLAMA-HIP-STATUS.md): does GGML_HIP need hipcc/LLVM for its
# kernels, or can they be AOT-precompiled?  ->  IT HARD-REQUIRES hipcc/LLVM.
# ============================================================================
# llama.cpp's GGML_HIP backend = ggml/src/ggml-cuda/*.cu (159 files, ~12k LOC of
# kernels) compiled with LANGUAGE HIP. The kernels are launched with the CUDA/HIP
# triple-chevron `kernel<<<grid,block,shmem,stream>>>(args)` syntax (127 launch
# sites, 3 in the main host TU ggml-cuda.cu itself). `<<<>>>` is a hipcc/clang
# LANGUAGE EXTENSION -- plain g++ cannot parse it. And unlike rocBLAS (which
# ships PRECOMPILED Tensile .hsaco kernels loaded via hipModuleLoad), GGML fuses
# host + device in each .cu and compiles them from source at build time -- there
# is NO precompiled-.hsaco / hipModuleLoad path in the GGML_HIP backend to reach.
# So GGML_HIP's KERNELS are the LLVM boundary; they are NOT AOT-precompilable.
#
# ggml-hip/CMakeLists.txt confirms it: `enable_language(HIP)` +
# `set_source_files_properties(${GGML_SOURCES_ROCM} PROPERTIES LANGUAGE HIP)` +
# `find_package(hip/hipblas/rocblas REQUIRED)`. Building this attr therefore
# needs the ROCm HIP clang toolchain (hipcc + the amdgpu LLVM backend) -- which
# solnix has NOT ported (the C5/C6 AOT insight deliberately skipped LLVM/comgr).
#
# WHAT IS COMPILE-REACHABLE ON ILLUMOS TODAY (this recipe's deliverable):
#   - the GGML_HIP HOST dispatch chain, linking the solnix libamdhip64.so.5.
#     Proven by ggml-hip-host-dispatch-proof.cpp: plain g++, NO hipcc, walks the
#     exact HIP runtime-API sequence GGML does per op (hipSetDevice ->
#     hipStreamCreate -> hipMalloc -> hipMemcpyAsync -> hipLaunchKernel [what
#     <<<>>> lowers to] -> hipEvent sync -> hipFree), and every hip* symbol
#     resolves into libamdhip64 -> libhsa-runtime64 -> libhsakmt (25 undef, 15
#     into libamdhip64, ZERO phantom; ldd chain intact; runs off-hardware to the
#     expected hipErrorNoDevice). The llama.cpp -> HIP -> ROCr -> KFD dispatch
#     chain is wired.
#
# WHAT NEEDS hipcc/LLVM (the boundary, NOT built here):
#   - the 159 ggml-cuda/*.cu device kernels (the <<<>>> compute). This is the one
#     piece the AOT insight cannot dodge for GGML the way it did for rocBLAS.
#     Closing it means porting the ROCm HIP clang/LLVM amdgpu backend (huge) OR
#     upstreaming a precompiled-.hsaco + hipModuleLoad kernel path into GGML_HIP
#     (does not exist upstream).
#   - hipblas/rocblas (find_package REQUIRED). rocBLAS IS the AOT template
#     (precompiled Tensile .hsaco, no runtime LLVM) -- portable via the C6 AOT
#     path -- but it is a separate port not yet built on the node; hipBLAS is a
#     thin host wrapper over rocBLAS.
#
# VERDICT: accelerated llama.cpp on ROCm is HOST-side compile-reachable on
# illumos (the dispatch chain links libamdhip64 zero-phantom), but the GGML_HIP
# KERNEL compile is gated on hipcc/LLVM -- a HARDER gate than GGML_VULKAN, whose
# shaders compile to SPIR-V via glslang (no LLVM). GGML_VULKAN remains the
# LLVM-free accelerated path on solnix; GGML_HIP reaches the runtime dispatch
# chain but its kernels need the LLVM port (or an upstream AOT-kernel path).
#
# This attr is a DOCUMENTED STUB: it builds the host-dispatch proof (the
# reachable half) and records the hipcc gap. A real GGML_HIP=ON build is added
# once the ROCm HIP clang/LLVM toolchain is ported (out of scope: no LLVM).
{ system ? "x86_64-solaris" }:
throw ''
  llama-cpp-hip (GGML_HIP=ON) is NOT buildable on solnix without the ROCm HIP
  clang/LLVM toolchain: the ggml-cuda/*.cu kernels use the <<<>>> hipcc language
  extension (127 launch sites) and cannot be compiled by g++ nor AOT-precompiled
  to .hsaco. The reachable half -- the HOST dispatch chain linking the solnix
  libamdhip64.so.5 -- is built + audited by build-ggml-hip-proof.sh
  (ggml-hip-host-dispatch-proof.cpp; 25 undef, 0 phantom). See LLAMA-HIP-STATUS.md.
  For an LLVM-free accelerated llama.cpp on solnix, use the GGML_VULKAN recipe
  (artifacts/gpu-c4-llama-vulkan/), whose shaders compile to SPIR-V via glslang.
''
