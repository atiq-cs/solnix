#!/usr/bin/env bash
# build-hip-solnix.sh -- direct g++ build of the HIP core (libamdhip64) AOT
# dispatch path + ROCclr on illumos x86_64. No cmake, no LLVM, no comgr library
# (comgr is dlopen'd at runtime; only its header is needed to compile). Same
# approach as build-rocr-solnix.sh.
#
# Prerequisites under $B (=/root/hip-build on the node):
#   inc/amd_comgr.h                 header-only crib (see inc/amd_comgr.h.NOTE.md)
#   gen/hip/hip_version.h           synthesized version header (see inc/hip_version.h)
#   gen/hip/amd_detail/hip_prof_str.h   generated ONCE by HIP/hip_prof_gen.py
#     against a COPY of HIP/rocclr (the generator rewrites the sources it scans
#     in place -- run it on a throwaway copy, never the build tree). With the
#     profiler disabled (-DUSE_PROF_API=0) this header is not #included, so a
#     coarse/partial generation is harmless; the guard is what matters.
#   gen/amdocl/cl_gl_amd.hpp        symlink -> HIP/rocclr/cl_gl_amd.hpp
# Depends on the solnix ROCr (/root/rocr-build) + libhsakmt (/root/drm-port/rocm/build).
set -u
ROCCLR=/root/ROCclr
HIP=/root/HIP
ROCR=/root/ROCR-Runtime/src
THUNK=/root/ROCT-Thunk-Interface/include
B=/root/hip-build
OBJ=$B/obj
mkdir -p "$OBJ"

COMPAT="-include $B/solnix-hip-compat.h"
INCS="-I$B/shim \
 -I$ROCCLR -I$ROCCLR/include -I$ROCCLR/compiler/lib -I$ROCCLR/compiler/lib/include \
 -I$ROCCLR/compiler/lib/backends/common -I$ROCCLR/elf -I$ROCCLR/device/rocm \
 -I$HIP -I$HIP/amdocl -I$B/inc -I$B/gen -I$ROCR/inc -I$THUNK \
 -I$HIP/rocclr -I$HIP/include -I$HIP/include/hip"
DEFS="-D__x86_64__ -DOPENCL_MAJOR=2 -DOPENCL_MINOR=1 -DCL_TARGET_OPENCL_VERSION=220 \
 -DATI_OS_LINUX -DATI_ARCH_X86 -DLITTLEENDIAN_CPU -DATI_BITS_64 -DWITH_TARGET_AMDGCN \
 -DWITH_HSA_DEVICE -DUSE_COMGR_LIBRARY -DCOMGR_DYN_DLL -DWITH_LIGHTNING_COMPILER \
 -DOPENCL_C_MAJOR=2 -DOPENCL_C_MINOR=0 -DCL_USE_DEPRECATED_OPENCL_1_0_APIS \
 -DCL_USE_DEPRECATED_OPENCL_1_1_APIS -DCL_USE_DEPRECATED_OPENCL_1_2_APIS \
 -DCL_USE_DEPRECATED_OPENCL_2_0_APIS -D__HIP_PLATFORM_AMD__ -D__HIP_PLATFORM_HCC__ \
 -DUSE_PROF_API=0 -DVEGA10_ONLY=false"
CXXFLAGS="-m64 -std=c++14 -fPIC -fpermissive -w $DEFS $INCS $COMPAT"

# ROCclr core (the cmake oclruntime_src list) minus os_win32
ROCCLR_SRCS="
 thread/thread.cpp thread/monitor.cpp thread/semaphore.cpp
 utils/flags.cpp utils/debug.cpp
 device/appprofile.cpp device/device.cpp device/hwdebug.cpp
 device/blitcl.cpp device/blit.cpp device/devkernel.cpp
 device/devwavelimiter.cpp device/devprogram.cpp device/devhcprintf.cpp
 device/devhcmessages.cpp device/devhostcall.cpp device/comgrctx.cpp
 platform/activity.cpp platform/kernel.cpp platform/context.cpp
 platform/command.cpp platform/ndrange.cpp platform/runtime.cpp
 platform/memory.cpp platform/program.cpp platform/commandqueue.cpp
 platform/agent.cpp
 os/alloc.cpp os/os.cpp os/os_posix.cpp
 compiler/lib/utils/options.cpp elf/elf.cpp"

# ROCclr HSA device backend
ROCM_SRCS="
 device/rocm/rocappprofile.cpp device/rocm/rocblit.cpp device/rocm/roccounters.cpp
 device/rocm/rocdevice.cpp device/rocm/rockernel.cpp device/rocm/rocmemory.cpp
 device/rocm/rocprintf.cpp device/rocm/rocprogram.cpp device/rocm/rocschedcl.cpp
 device/rocm/rocsettings.cpp device/rocm/rocsignal.cpp device/rocm/rocvirtual.cpp
 device/rocm/rocglinterop.cpp"

# HIP core runtime (the AOT dispatch path; skip hip_rtc = the LLVM JIT)
HIP_SRCS="
 hip_code_object.cpp hip_context.cpp hip_device_runtime.cpp hip_device.cpp
 hip_error.cpp hip_event.cpp hip_fatbin.cpp hip_global.cpp hip_hmm.cpp
 hip_intercept.cpp hip_memory.cpp hip_module.cpp hip_peer.cpp hip_platform.cpp
 hip_profile.cpp hip_stream_ops.cpp hip_stream.cpp hip_surface.cpp
 hip_texture.cpp hip_activity.cpp fixme.cpp cl_gl.cpp cl_lqdflash_amd.cpp"

FAIL=0; OK=0; OBJS=""
compile() { # dir file
  local dir="$1" f="$2" o
  o="$OBJ/$(echo "$f" | tr '/' '_').o"
  if g++ $CXXFLAGS -c "$dir/$f" -o "$o" 2>"$OBJ/$(echo "$f" | tr '/' '_').log"; then
    OK=$((OK+1)); OBJS="$OBJS $o"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $f"; grep -E "error:" "$OBJ/$(echo "$f" | tr '/' '_').log" | head -4
  fi
}

echo "=== ROCclr core ==="
for f in $ROCCLR_SRCS; do compile "$ROCCLR" "$f"; done
echo "=== ROCclr HSA device ==="
for f in $ROCM_SRCS; do compile "$ROCCLR" "$f"; done
echo "=== HIP core (AOT) ==="
for f in $HIP_SRCS; do compile "$HIP/rocclr" "$f"; done

echo "=== compiled OK=$OK FAIL=$FAIL ==="
if [ "$FAIL" -eq 0 ]; then
  echo "=== linking libamdhip64.so.5 ==="
  g++ -m64 -shared -fPIC -o "$B/libamdhip64.so.5" $OBJS \
    -L/root/rocr-build -lhsa-runtime64 \
    -L/root/drm-port/rocm/build -lhsakmt \
    -lelf -lpthread -ldl -lrt 2>&1 | head -40
  ls -la "$B/libamdhip64.so.5" 2>/dev/null && echo "LINKED"
fi
