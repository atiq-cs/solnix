#!/usr/bin/env bash
# Build the solnix GGML_HIP HOST-dispatch proof (NO hipcc / NO LLVM).
#
# This compiles + links the C++ host half of llama.cpp's GGML_HIP backend
# dispatch chain against the solnix ROCm stack:
#   libamdhip64.so.5 (C6, hip/README.md) -> libhsa-runtime64.so.1 (C5) ->
#   libhsakmt.so.1 (C4) -> the C3-KFD /dev/kfd surface.
#
# It does NOT build the GGML_HIP device kernels (the 159 ggml-cuda/*.cu, launched
# via <<<...>>> -- 127 launch sites). Those are the LLVM boundary: <<<>>> is a
# hipcc/clang language extension and cannot be lowered by plain g++, nor can the
# kernels be AOT-precompiled to .hsaco the way rocBLAS ships Tensile kernels
# (GGML fuses host+device in one .cu and compiles from source). See
# LLAMA-HIP-STATUS.md for the full verdict.
set -eu

G=${CXX:-/usr/gcc/14/bin/g++}
HIP_INC=${HIP_INC:-/root/HIP/include}
HIP_GEN=${HIP_GEN:-/root/hip-build/gen}          # synthesized hip_version.h (C6)
HIP_LIB=${HIP_LIB:-/root/hip-build}              # libamdhip64.so.5
ROCR_LIB=${ROCR_LIB:-/root/rocr-build}           # libhsa-runtime64.so.1
KMT_LIB=${KMT_LIB:-/root/drm-port/rocm/build}    # libhsakmt.so.1
DRM_DIR=${DRM_DIR:-/var/tmp/libdrm-out}          # RADV libdrm

cd "$(dirname "$0")"

"$G" -m64 -std=c++14 -O2 -D__EXTENSIONS__ -D_POSIX_PTHREAD_SEMANTICS \
  -D__HIP_PLATFORM_AMD__ -D__HIP_PLATFORM_HCC__ \
  -I"$HIP_INC" -I"$HIP_INC/hip" -I"$HIP_GEN" \
  ggml-hip-host-dispatch-proof.cpp -o ggml-hip-host-dispatch-proof \
  -L"$HIP_LIB" -lamdhip64 \
  -L"$ROCR_LIB" -lhsa-runtime64 \
  -L"$KMT_LIB" -lhsakmt \
  -L"$DRM_DIR/lib" -ldrm -ldrm_amdgpu \
  -Wl,-R"$HIP_LIB" -Wl,-R"$ROCR_LIB" -Wl,-R"$KMT_LIB" -Wl,-R"$DRM_DIR/lib" \
  -lsendfile -lelf -lpthread -ldl -lrt -lm -lnsl -lsocket

echo "built: ggml-hip-host-dispatch-proof"
ldd ggml-hip-host-dispatch-proof | grep -iE "amdhip|hsa-runtime|hsakmt"
