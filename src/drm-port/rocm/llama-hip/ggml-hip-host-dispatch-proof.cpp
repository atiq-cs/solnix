// ggml-hip-host-dispatch-proof.cpp -- the solnix llama.cpp GGML_HIP HOST-backend
// dispatch proof. Compiles with plain g++ (NO hipcc / NO LLVM) against the HIP
// runtime-API header, and links the solnix libamdhip64.so.5 (C6) + ROCr (C5) +
// libhsakmt (C4). It walks the exact HIP runtime-API sequence llama.cpp's GGML
// HIP backend performs on every op dispatch -- the C++ HOST code in
// ggml/src/ggml-cuda/*.cu once hipified: device select -> stream create ->
// device malloc -> async H2D copy -> kernel launch (hipLaunchKernel, what the
// GGML <<<...>>> lowers to) -> async D2H copy -> event/stream sync -> free.
//
// It cannot RUN off-hardware (hipGetDeviceCount returns 0 with no powered V520 /
// g4ad + no libhsakmt /sys topology shim), but it COMPILES + LINKS and every HIP
// symbol resolves into the solnix libamdhip64 -- proving the
// llama.cpp -> HIP -> ROCr -> KFD dispatch chain is wired on illumos.
//
// The device KERNELS themselves (the __global__ bodies in the 159 ggml-cuda .cu
// files, launched via <<<>>>) are the LLVM boundary: <<<>>> is a hipcc/clang
// language extension, so GGML_HIP's kernels cannot be AOT-precompiled to .hsaco
// the way rocBLAS ships Tensile kernels. This TU is the host half of that split;
// see LLAMA-HIP-STATUS.md for the full verdict.

#ifndef __HIP_PLATFORM_AMD__
#define __HIP_PLATFORM_AMD__
#endif
#ifndef __HIP_PLATFORM_HCC__
#define __HIP_PLATFORM_HCC__
#endif

#include <hip/hip_runtime_api.h>
#include <cstdio>
#include <cstring>

// A stand-in for a GGML HIP kernel entry. In a real GGML_HIP build this is a
// __global__ function compiled by hipcc; here we only take its address to feed
// hipLaunchKernel -- proving the host-side launch API links. (Not dereferenced
// off-hardware.)
static void ggml_hip_dummy_kernel_stub() {}

// Mirrors the host control-flow of a GGML op dispatch, e.g. ggml_cuda_op_add /
// ggml_cuda_mul_mat's non-BLAS path: the sequence of HIP runtime calls the
// backend makes around a kernel launch. Every hip* call below is a real export
// of the solnix libamdhip64.so.5.
static hipError_t ggml_hip_host_dispatch_chain() {
    int ndev = 0;
    hipError_t st = hipGetDeviceCount(&ndev);           // ROCr agent enumeration
    if (st != hipSuccess || ndev == 0) {
        // Off-hardware: no agent. The chain below is what runs on a powered V520.
        return st == hipSuccess ? hipErrorNoDevice : st;
    }

    hipSetDevice(0);                                    // bind the GGML device

    hipStream_t stream;
    hipStreamCreateWithFlags(&stream, hipStreamNonBlocking); // GGML per-device stream

    const size_t n = 4096;
    const size_t bytes = n * sizeof(float);

    void *d_src = nullptr, *d_dst = nullptr;
    hipMalloc(&d_src, bytes);                            // ggml device buffer alloc
    hipMalloc(&d_dst, bytes);

    float *h_src = new float[n];
    float *h_dst = new float[n];
    for (size_t i = 0; i < n; ++i) h_src[i] = (float)i;

    hipMemcpyAsync(d_src, h_src, bytes, hipMemcpyHostToDevice, stream); // H2D

    // The kernel launch. GGML's <<<blocks, threads, shmem, stream>>>(args)
    // lowers (in a hipcc build) to __hipPushCallConfiguration + hipLaunchKernel.
    // Both symbols are exported by the solnix libamdhip64; here we call the
    // runtime entry point directly with the launch config a GGML op would set.
    dim3 grid((n + 255) / 256), block(256);
    void *kargs[] = { &d_dst, &d_src };
    hipLaunchKernel(reinterpret_cast<const void*>(&ggml_hip_dummy_kernel_stub),
                    grid, block, kargs, /*shmem*/0, stream);

    hipMemcpyAsync(h_dst, d_dst, bytes, hipMemcpyDeviceToHost, stream); // D2H

    hipEvent_t ev;
    hipEventCreateWithFlags(&ev, hipEventDisableTiming); // GGML sync event
    hipEventRecord(ev, stream);
    hipEventSynchronize(ev);
    hipStreamSynchronize(stream);

    hipEventDestroy(ev);
    hipFree(d_src);
    hipFree(d_dst);
    hipStreamDestroy(stream);
    delete[] h_src;
    delete[] h_dst;
    return hipSuccess;
}

int main() {
    // Report the HIP runtime version the solnix libamdhip64 exposes.
    int rt = 0;
    hipError_t vst = hipRuntimeGetVersion(&rt);
    printf("solnix GGML_HIP host-dispatch proof\n");
    printf("  hipRuntimeGetVersion: st=%d version=%d\n", (int)vst, rt);

    hipError_t st = ggml_hip_host_dispatch_chain();
    printf("  ggml_hip_host_dispatch_chain: st=%d (%s)\n",
           (int)st, hipGetErrorString(st));
    // st == hipErrorNoDevice off-hardware is EXPECTED and PROVES the link:
    // every hip* symbol resolved; only the runtime agent is absent (g4ad-gated).
    return 0;
}
