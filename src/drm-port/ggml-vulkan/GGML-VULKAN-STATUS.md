# GGML_VULKAN on illumos (x86_64) -- COMPILE + LINK + SHADER-GEN PROOF

The LLVM-free "as fast as Linux" local-LLM lead path: llama.cpp's GGML_VULKAN
backend built on illumos. SPIR-V compute shaders generated at build time via
glslang, dispatched through the Vulkan loader; NO hipcc, NO LLVM kernel compile.

Node: fred v3 (44.248.55.168), OpenIndiana/illumos 5.11, gcc 14.3.0, 16 cores, 64GB.
Tree: /root/ggml-vulkan/  (src/, prefix/)

## Vulkan build deps -- how obtained

| Dep                | Source            | Detail                                                     |
|--------------------|-------------------|------------------------------------------------------------|
| cmake 4.4.2        | OI pkg            | developer/build/cmake                                      |
| ninja 1.13.2       | OI pkg            | developer/build/ninja                                      |
| glslang 14.3.0     | OI pkg            | x11/library/glslang -> glslangValidator + libglslang.so.14 |
| spirv-headers      | OI pkg            | x11/library/spirv-headers 1.3.280                          |
| spirv-tools        | OI pkg            | x11/library/spirv-tools 2024.2                             |
| Vulkan-Headers     | BUILT from source | KhronosGroup v1.3.280, header-only cmake -> prefix         |
| Vulkan-Loader      | BUILT from source | KhronosGroup v1.3.280 -> libvulkan.so.1.3.280 (3 patches)  |
| glslc              | WRAPPER (written) | prefix/bin/glslc = python shim over glslangValidator       |

No Vulkan-Headers / Vulkan-Loader package exists in OI, so both were built from
source. OI ships glslangValidator, not glslc/shaderc, so a small glslc-compatible
wrapper translates GGML's glslc invocations to glslangValidator flags.

## Status

| Item                                              | Result |
|---------------------------------------------------|--------|
| Vulkan-Headers installed                          | YES (built, v1.3.280) |
| Vulkan-Loader libvulkan.so.1 built                | YES (x86_64-illumos ELF, 727KB) |
| glslc available (via wrapper)                     | YES (glslangValidator shim) |
| GGML_VULKAN configured                            | YES ("Including Vulkan backend", Vulkan 1.3.280) |
| vulkan-shaders-gen built + runs on illumos        | YES (x86_64 ELF, drives wrapper) |
| SPIR-V shader-gen ran (SPIR-V embedded)           | YES (1653 .spv generated, 138 .comp.cpp embedded, 243KB shaders.hpp) |
| libggml-vulkan.so backend built                   | YES (43MB, ELF, embeds SPIR-V blobs) |
| llama-cli linked                                  | YES (x86_64-illumos ELF) |
| llama-cli --version runs                          | YES (version 0.1.2-dev, "for SunOS amd64") |
| llama-cli --list-devices runs                     | YES -> "(none)" = expected headless result |
| zero-phantom (libggml-vulkan)                     | YES (ldd -r: 0 symbol-not-found) |
| zero-phantom (llama-cli)                           | YES (ldd -r: 0 symbol-not-found) |
| vulkan symbols resolve to libvulkan               | YES (NEEDED libvulkan.so.1; 4 boot vk* refs, all resolve) |

## COMPILE+LINK-COMPLETE vs GPU-HARDWARE-GATED

COMPILE+LINK+SHADER-GEN+BINARY-RUNS -- ALL COMPLETE:
- Vulkan-Headers + Vulkan-Loader (libvulkan.so.1) built from source on illumos.
- glslang compiles GGML's .comp compute shaders to SPIR-V at build time (1653 .spv).
- vulkan-shaders-gen (host tool) built + runs, drives the glslc wrapper -> glslang.
- libggml-vulkan.so links libvulkan.so.1, embeds the SPIR-V, zero-phantom.
- llama-cli links the full ggml/vulkan/cpu chain, runs --version and --list-devices.

GPU-HARDWARE-GATED (expected, not attempted):
- Actual device enumeration returns "(none)": no GPU + no RADV ICD loaded on this
  headless node. At runtime the loader reads VK_ICD_FILENAMES -> RADV
  (libvulkan_radeon.so, built separately on the GPU node) to bind a real device.
  Inference needs real GPU hardware; the loader correctly reports no-device here.

## illumos porting patches (crib-and-adapt)

Vulkan-Loader (src/Vulkan-Loader/):
1. CMakeLists.txt: added SunOS platform branch (was "Unsupported Platform!"),
   headless -- all WSI (XCB/Xlib/Wayland/DirectFB) OFF.
2. loader/vk_loader_platform.h: added __sun to COMMON_UNIX_PLATFORMS (dlfcn,
   pthread, libgen, alloca, DIRECTORY_SYMBOL, dl_handle all follow).
3. loader/vk_loader_platform.h: added __sun loader_platform_executable_path via
   readlink("/proc/self/path/a.out") (illumos exe symlink).
4. loader/CMakeLists.txt: added __EXTENSIONS__ for SunOS (exposes strtok_r /
   secure_getenv / full POSIX+SVR4 symbol set).

llama.cpp (src/llama.cpp/):
5. src/llama-mmap.cpp: added __sun to the RLIMIT_MEMLOCK skip guard (illumos has
   no RLIMIT_MEMLOCK; matches upstream AIX/Haiku handling).
6. common/arg.cpp + common/download.cpp: added __sun -> <limits.h> branch
   (illumos has no <sys/syslimits.h>; PATH_MAX lives in <limits.h>).
7. common/common.cpp: added __sun to both fs_get_cache_directory /
   fs_get_config_directory XDG gates (was "#error Unknown architecture").
8. vendor/miniaudio/miniaudio.h: MA_ATOMIC gate -- added !defined(__cplusplus)
   so C++ TUs use __attribute__((aligned)) not the C11 _Alignas keyword
   (mtmd links into llama-cli; audio path unused for text inference).

ggml-vulkan feature detection (src/llama.cpp/ggml/src/ggml-vulkan/CMakeLists.txt):
9. test_shader_extension_support hardened: also treat nonzero glslc exit as
   "unsupported" (glslangValidator 14.3.0 supports coopmat KHR but NOT
   cooperative_matrix2/NV, integer_dot, bf16, e2m1, e4m3 -- those variants are
   now correctly skipped at shader-gen).

Link fix: -lsocket -lnsl added to EXE/SHARED linker flags (illumos socket funcs
live in libsocket/libnsl, not libc).

## Reproduce

    export PATH=/root/ggml-vulkan/prefix/bin:$PATH
    export LD_LIBRARY_PATH=/root/ggml-vulkan/prefix/lib:/root/ggml-vulkan/src/llama.cpp/build/bin:$LD_LIBRARY_PATH
    /root/ggml-vulkan/src/llama.cpp/build/bin/llama-cli --version
    /root/ggml-vulkan/src/llama.cpp/build/bin/llama-cli --list-devices   # -> (none), headless

## Verdict

GGML_VULKAN -- the LLVM-free "as fast as Linux" local-LLM path -- BUILDS on
illumos: Vulkan loader from source, glslang SPIR-V shader-gen working, the
vulkan backend + llama-cli compiled, linked (zero-phantom), and running. Only
real-GPU device binding (via RADV) is hardware-gated, exactly like the prior
RADV/ANV/NVK compile-proofs.
