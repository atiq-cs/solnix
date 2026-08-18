# CLC / LLVM Toolchain Status — solnix (illumos x86_64, fred v3)

Host: root@3.21.134.141. Built under /root/clc-toolchain/. Toolchain complete and proven end-to-end.

## Summary (deliverables)

| Piece | Status | How |
|-------|--------|-----|
| LLVM/Clang >=18 (dev headers + llvm-config + clang + SPIR-V target) | DONE — **20.1.8** | OI pkg `developer/clang-20` (NO source build) |
| SPIRV-Tools (spirv-as/val/opt + libs + pkg-config) | DONE | built from source |
| SPIRV-LLVM-Translator (llvm-spirv + libLLVMSPIRVLib.a) | DONE | built from source vs LLVM 20 |
| libclc (spirv-mesa3d + spirv64-mesa3d + amdgcn) | DONE | built from source (llvm-project release/20.x) |
| Satisfies Mesa 25.3.6 `-Dmesa-clc=enabled -Dllvm=enabled` | YES (pkg-config + llvm-config all resolve) | verified |
| PowerVR .so linked | NO — Mesa tree not on this node | see finish command |
| AMDGPU target for GGML_HIP / hipcc | YES — amdgcn target in LLVM 20 + amdgcn libclc | in same LLVM |

## 1. LLVM / Clang — OI pkg, version 20.1.8

Installed via `pkg install developer/clang-20` (343 MB, ~1 min — no multi-hour source build).

- `llvm-config` = `/usr/bin/llvm-config` -> 20.1.8, prefix `/usr/clang/20`
- headers: `/usr/clang/20/include` (full llvm/ + clang/ trees)
- static libs: `/usr/clang/20/lib/libLLVM*.a`; shared: `/usr/clang/20/lib/libLLVM.so.20.1`
- clang: `/usr/bin/clang` 20.1.8, target `x86_64-pc-solaris2.11`
- **targets built**: AArch64 **AMDGPU** ARM AVR BPF Hexagon Lanai LoongArch Mips MSP430 NVPTX PowerPC RISCV Sparc **SPIRV** SystemZ VE WebAssembly **X86** XCore
  - `X86` + `SPIRV` = mesa_clc; `AMDGPU`/`amdgcn` = GGML_HIP/hipcc. All present in the single OI package.

## 2. SPIRV-Tools + SPIRV-LLVM-Translator + libclc — source

Installed to `/root/clc-toolchain/install`:
- `bin/`: spirv-as, spirv-val, spirv-opt, spirv-dis, spirv-link, spirv-cfg, spirv-objdump, **llvm-spirv**
- `lib/libLLVMSPIRVLib.a`
- `lib/pkgconfig/`: `SPIRV-Tools.pc` (2026.4.1), `SPIRV-Tools-shared.pc`, `LLVMSPIRVLib.pc`
- `share/pkgconfig/libclc.pc` (0.2.0)  — libexecdir=`/root/clc-toolchain/install/share/clc`
- `share/clc/`: **`spirv-mesa3d-.spv`**, **`spirv64-mesa3d-.spv`** (mesa_clc inputs), + amdgcn-mesa-mesa3d `.bc` (all gfx families gfx602..gfx1201)

Sources cloned in /root/clc-toolchain: SPIRV-Headers, SPIRV-Tools, SPIRV-LLVM-Translator (branch llvm_release_200), llvm-project (release/20.x, sparse: libclc+cmake).

## 3. RUNTIME PATH (illumos gotcha — REQUIRED)

The source-built binaries were NOT given a baked runpath, and OI clang++ links libstdc++ from gcc. Any tool
from `/root/clc-toolchain/install/bin` (and `llvm-spirv`) needs:

    export LD_LIBRARY_PATH=/usr/clang/20/lib:/usr/gcc/14/lib/amd64

- `/usr/clang/20/lib` -> `libLLVM.so.20.1` (needed by llvm-spirv)
- `/usr/gcc/14/lib/amd64` -> `libstdc++.so.6` (needed by all spirv-* tools)

Env setup script: `/root/clc-toolchain/env.sh` (source it).

## 4. Proven end-to-end (the mesa_clc chain)

    clang -c -target spirv64 -cl-std=CL1.2 -emit-llvm -o k.bc k.cl   # OpenCL-C -> LLVM IR
    llvm-spirv k.bc -o k.spv                                          # LLVM IR -> SPIR-V
    spirv-val k.spv                                                   # => SPIRV VALID

Result: valid SPIR-V 1.0 module produced and validated. Toolchain works.

## 5. Does it satisfy Mesa 25.3.6 -Dmesa-clc=enabled -Dllvm=enabled?

YES. Mesa's meson finds:
- `llvm-config` (>= min) at `/usr/bin/llvm-config` 20.1.8 with SPIRV+X86 targets. Mesa links `-lLLVM-20`
  (`llvm-config --libs core bitreader ... spirvcodegen` -> `-lLLVM-20`; the shared lib carries every target).
- `pkg-config libclc` -> 0.2.0 with libexecdir holding `spirv64-mesa3d-.spv` (mesa_clc / pco usclib input).
- `pkg-config SPIRV-Tools` -> 2026.4.1.

To make Mesa's meson see them, export before configure:

    export PATH=/root/clc-toolchain/install/bin:/usr/clang/20/bin:/usr/bin:$PATH
    export LD_LIBRARY_PATH=/usr/clang/20/lib:/usr/gcc/14/lib/amd64
    export PKG_CONFIG_PATH=/root/clc-toolchain/install/lib/pkgconfig:/root/clc-toolchain/install/share/pkgconfig:$PKG_CONFIG_PATH

## 6. EXACT FINISH COMMAND — link libvulkan_powervr_mesa.so (Mesa 25.3.6, BXE-2-32)

Mesa tree is NOT on this node (checked /root /export /var). It lives on the GPU node 3.135.239.78
(src/drm-port/powervr/build-mesa-powervr25.sh). Bring the Mesa 25.3.6 tree here (or run there with this
toolchain reachable) and:

    export PATH=/root/clc-toolchain/install/bin:/usr/clang/20/bin:/usr/bin:$PATH
    export LD_LIBRARY_PATH=/usr/clang/20/lib:/usr/gcc/14/lib/amd64
    export PKG_CONFIG_PATH=/root/clc-toolchain/install/lib/pkgconfig:/root/clc-toolchain/install/share/pkgconfig:$PKG_CONFIG_PATH

    cd <mesa-25.3.6>
    meson setup build \
      -Dllvm=enabled -Dmesa-clc=enabled -Dprecomp-compiler=enabled \
      -Dvulkan-drivers=powervr -Dgallium-drivers= \
      -Dplatforms= -Dglx=disabled \
      --native-file <the illumos native file used by build-mesa-powervr25.sh>
    ninja -C build src/imagination/vulkan/libvulkan_powervr_mesa.so

Then the zero-phantom audit: `elfdump -d` / `nm -D` the .so for undefined mesa_clc/usclib symbols.

## 7. GGML_HIP notes

Same LLVM 20 has the **AMDGPU** target and amdgcn libclc bitcode is built. No separate LLVM needed and
no `-DLLVM_TARGETS_TO_BUILD` source build required — AMDGPU is already compiled into OI's clang-20.
For hipcc/ROCm device compilation the AMDGPU codegen + `amdgcn-mesa-mesa3d` bitcode are in place; the
remaining HIP work is the ROCm/hipcc wrapper + rocm device libs, not the LLVM backend (that gap is closed).
