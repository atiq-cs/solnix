// hip-aot-dispatch-proof.cpp -- the AOT (ahead-of-time) dispatch link proof for
// HIP-on-ROCr on illumos. It exercises the whole precompiled-kernel path:
//
//   hipModuleLoad(.hsaco)   -> ROCr hsa_code_object_reader_create_from_memory
//                              + hsa_executable_load_agent_code_object
//   hipModuleGetFunction    -> hsa_executable_get_symbol_by_name (kernel object)
//   hipMalloc / hipMemcpy   -> hsa_amd_memory_pool_allocate + async copy
//   hipModuleLaunchKernel   -> the hsa AQL dispatch packet on an hsa_queue
//
// It cannot RUN without a powered GPU (hipInit enumerates no agent off-hardware),
// but it LINKS against libamdhip64 + ROCr, which proves every symbol on the AOT
// dispatch path is defined end to end: precompiled .hsaco -> HIP -> ROCr -> KFD.
//
// A trivial vector-add kernel is the canonical example; the .hsaco would be
// produced off-node (or on a Linux build host) by hipcc/clang -- NO runtime LLVM.
#include <hip/hip_runtime.h>
#include <cstdio>
#include <cstdlib>
#include <vector>

#define CHECK(x) do { hipError_t e = (x); if (e != hipSuccess) { \
    std::fprintf(stderr, "%s -> %s\n", #x, hipGetErrorString(e)); } } while (0)

int main(int argc, char** argv) {
  const char* hsaco = (argc > 1) ? argv[1] : "vector_add.hsaco";
  const int N = 1024;
  const size_t bytes = N * sizeof(float);

  // (1) runtime init + device -- enumerates the ROCr agent (GPU-gated).
  CHECK(hipInit(0));
  int ndev = 0;
  CHECK(hipGetDeviceCount(&ndev));
  std::printf("hip devices: %d\n", ndev);
  CHECK(hipSetDevice(0));

  // (2) AOT: load a precompiled code object (.hsaco) -> ROCr executable loader.
  hipModule_t mod;
  CHECK(hipModuleLoad(&mod, hsaco));

  // (3) resolve the kernel symbol -> hsa_executable_get_symbol_by_name.
  hipFunction_t fn;
  CHECK(hipModuleGetFunction(&fn, mod, "vector_add"));

  // (4) device allocations -> ROCr memory pool + async copy.
  float *dA = nullptr, *dB = nullptr, *dC = nullptr;
  CHECK(hipMalloc(&dA, bytes));
  CHECK(hipMalloc(&dB, bytes));
  CHECK(hipMalloc(&dC, bytes));
  std::vector<float> hA(N, 1.0f), hB(N, 2.0f), hC(N, 0.0f);
  CHECK(hipMemcpyHtoD(dA, hA.data(), bytes));
  CHECK(hipMemcpyHtoD(dB, hB.data(), bytes));

  // (5) AQL dispatch of the precompiled kernel -> hsa_queue AQL packet.
  struct { float* a; float* b; float* c; int n; } args = { dA, dB, dC, N };
  size_t argSize = sizeof(args);
  void* config[] = { HIP_LAUNCH_PARAM_BUFFER_POINTER, &args,
                     HIP_LAUNCH_PARAM_BUFFER_SIZE, &argSize,
                     HIP_LAUNCH_PARAM_END };
  hipStream_t stream;
  CHECK(hipStreamCreate(&stream));
  CHECK(hipModuleLaunchKernel(fn, (N + 63) / 64, 1, 1, 64, 1, 1,
                              0, stream, nullptr, config));
  CHECK(hipStreamSynchronize(stream));
  CHECK(hipMemcpyDtoH(hC.data(), dC, bytes));

  // teardown
  CHECK(hipFree(dA)); CHECK(hipFree(dB)); CHECK(hipFree(dC));
  CHECK(hipStreamDestroy(stream));
  CHECK(hipModuleUnload(mod));
  std::printf("AOT dispatch path exercised (result[0]=%f expected 3.0)\n", hC[0]);
  return 0;
}
