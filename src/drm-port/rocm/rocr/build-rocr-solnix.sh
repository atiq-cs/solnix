#!/usr/bin/env bash
# build-rocr-solnix.sh -- compile ROCR-Runtime core (libhsa-runtime64.so) for
# illumos x86_64 against the solnix libhsakmt, direct g++ (no cmake).
#
# Mirrors build-libhsakmt-solnix.sh: the cmake build graph is reduced to the
# 38 core-runtime .cpp the CMakeLists SRCS list feeds into the shared library,
# plus the solnix force-include compat header. comgr/LLVM is NOT a dependency
# of the rocm-4.2.0 core runtime (the code-object loader is libamdhsacode, its
# own libelf-based ELF reader) -- see ROCM-STATUS.md.
set -u

ROCR=/root/ROCR-Runtime/src
THUNK=/root/ROCT-Thunk-Interface/include/hsakmt
LIBDRM=/var/tmp/libdrm-out/include/libdrm
COMPAT=/root/rocr-build/solnix-rocr-compat.h
OUT=/root/rocr-build
mkdir -p "$OUT/obj"

# The CMakeLists SRCS list (rocm-4.2.0), core shared library only.
SRCS="
core/util/lnx/os_linux.cpp
core/util/small_heap.cpp
core/util/timer.cpp
core/runtime/amd_blit_kernel.cpp
core/runtime/amd_blit_sdma.cpp
core/runtime/amd_cpu_agent.cpp
core/runtime/amd_gpu_agent.cpp
core/runtime/amd_hsa_loader.cpp
core/runtime/amd_aql_queue.cpp
core/runtime/amd_loader_context.cpp
core/runtime/hsa_ven_amd_loader.cpp
core/runtime/amd_memory_region.cpp
core/runtime/amd_filter_device.cpp
core/runtime/amd_topology.cpp
core/runtime/default_signal.cpp
core/runtime/host_queue.cpp
core/runtime/hsa.cpp
core/runtime/hsa_api_trace.cpp
core/runtime/hsa_ext_amd.cpp
core/runtime/hsa_ext_interface.cpp
core/runtime/interrupt_signal.cpp
core/runtime/intercept_queue.cpp
core/runtime/ipc_signal.cpp
core/runtime/isa.cpp
core/runtime/runtime.cpp
core/runtime/signal.cpp
core/runtime/queue.cpp
core/runtime/cache.cpp
core/common/shared.cpp
core/common/hsa_table_interface.cpp
loader/executable.cpp
loader/loaders.cpp
libamdhsacode/amd_elf_image.cpp
libamdhsacode/amd_hsa_code_util.cpp
libamdhsacode/amd_hsa_locks.cpp
libamdhsacode/amd_options.cpp
libamdhsacode/amd_hsa_code.cpp
"

# Compile defs from the CMakeLists target_compile_definitions (minus the build-id
# noise). __linux__ selects the lnx backend; illumos __sun is also defined by gcc
# so the compat header + our #ifdef __sun edits apply on top.
CXXFLAGS="-std=c++17 -fPIC -O2 \
  -D__linux__ -DHSA_EXPORT=1 -DHSA_EXPORT_FINALIZER=1 -DHSA_EXPORT_IMAGES=1 -DHSA_DEPRECATED= \
  -DROCR_BUILD_ID=\"solnix\" \
  -fexceptions -fno-rtti -fvisibility=hidden -fno-math-errno \
  -fno-threadsafe-statics -fmerge-all-constants -fms-extensions \
  -Wno-sign-compare -Wno-write-strings -Wno-conversion-null -Wno-comment \
  -Wno-pointer-arith -Wno-unused-variable -Wno-unused-function \
  -Wno-deprecated-declarations -Wno-attributes \
  -include $COMPAT \
  -I$OUT/shim \
  -I$ROCR -I$ROCR/inc -I$ROCR/libamdhsacode \
  -I$THUNK -I$LIBDRM"

# The rocr/ shim dir supplies <linux/limits.h> -> <limits.h>.
mkdir -p "$OUT/shim/linux"
cp /root/rocr-build/limits.h "$OUT/shim/linux/limits.h" 2>/dev/null || true

cd "$ROCR" || exit 2
FAIL=0
OBJS=""
for s in $SRCS; do
  o="$OUT/obj/$(echo "$s" | tr '/' '_').o"
  if ! eval g++ $CXXFLAGS -c "$s" -o "$o" 2>"$OUT/obj/$(basename "$s").err"; then
    echo "FAIL: $s"
    grep -E "error:" "$OUT/obj/$(basename "$s").err" | head -8
    FAIL=1
  else
    OBJS="$OBJS $o"
  fi
done

if [ "$FAIL" != 0 ]; then
  echo "=== compile errors above; not linking ==="
  exit 1
fi

echo "=== all $(echo $SRCS | wc -w) units compiled; linking libhsa-runtime64.so ==="
# Link script + version script are cmake-era; a plain shared link is enough for
# the compile-phase milestone (zero-phantom audit runs on the result).
g++ -shared -o "$OUT/libhsa-runtime64.so.1" $OBJS \
  -L/root/drm-port/rocm/build -lhsakmt \
  -L$(dirname $(g++ -print-file-name=libstdc++.so)) \
  -lelf -ldl -lpthread -lrt 2>&1 | head -40
echo "link-exit=${PIPESTATUS[0]}"
ls -la "$OUT/libhsa-runtime64.so.1" 2>/dev/null
