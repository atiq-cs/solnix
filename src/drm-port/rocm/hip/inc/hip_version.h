/* solnix: synthesized hip_version.h (cmake generates this from a template at
   build time). Values match rocm-4.2.0 (HIP 4.2, patch 42131). Only the
   HIP_VERSION_* macros are read by the runtime for hipRuntimeGetVersion. */
#ifndef HIP_VERSION_H
#define HIP_VERSION_H
#define HIP_VERSION_MAJOR 4
#define HIP_VERSION_MINOR 2
#define HIP_VERSION_PATCH 42131
#define HIP_VERSION_GITHASH "solnix"
#define HIP_VERSION_BUILD_ID 0
#define HIP_VERSION_BUILD_NAME "solnix"
#define HIP_VERSION (HIP_VERSION_MAJOR * 10000000 + HIP_VERSION_MINOR * 100000 + HIP_VERSION_PATCH)
#endif
