# solnix: amd_comgr.h -- header-only crib, NOT committed here

HIP/ROCclr reference amd_comgr's types (amd_comgr_status_t, amd_comgr_data_t,
the ~90 t_amd_comgr_* function-pointer typedefs in device/comgrctx.hpp) at
COMPILE time. They never LINK the comgr library: ROCclr dlopen's
libamd_comgr.so.2 at RUNTIME (device/comgrctx.cpp:36, LoadLib()), and only the
hiprtc JIT path ever calls it. The AOT dispatch path (load a precompiled
.hsaco + AQL-dispatch it) never touches comgr, so no LLVM/comgr is linked.

Because only the *header* is needed to compile, obtain it from the matching
rocm-4.2.0 comgr source and substitute the two cmake version tokens:

    curl -sL https://raw.githubusercontent.com/ROCm/ROCm-CompilerSupport/rocm-4.2.0/lib/comgr/include/amd_comgr.h.in \
      | sed -e 's/@amd_comgr_VERSION_MAJOR@/1/g' -e 's/@amd_comgr_VERSION_MINOR@/9/g' \
      > inc/amd_comgr.h

The version tokens only feed a #define constant that the AOT path does not gate
on; any valid integer compiles. On the node it lives at
/root/hip-build/inc/amd_comgr.h. audit-undef-hip.sh asserts `amd_comgr link: 0`
to prove no comgr symbol is a link-time dependency.
