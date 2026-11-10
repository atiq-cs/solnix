# solnix-cmake.cmake -- CMAKE_TOOLCHAIN_FILE of a store-only build that runs cmake (mk-src-pkg's cmakeX: the recipe's build text names
# cmake; NixOS adds its cmake setup hook only with cmake in nativeBuildInputs, the same split). solnix-toolchain.cmake's settings
# (copied: a store file cannot include its source-tree neighbour), then what a cmake build needs.
set(CMAKE_FIND_USE_SYSTEM_ENVIRONMENT_PATH ON)   # PATH (store-only) is the search path for programs
set(CMAKE_FIND_USE_CMAKE_SYSTEM_PATH OFF)        # no /usr, /usr/local, /opt, /sw ... platform prefixes
set(CMAKE_SYSTEM_IGNORE_PREFIX_PATH "/usr;/usr/local;/usr/gnu;/opt;/usr/sfw;/sw;/opt/local")
set(CMAKE_SYSTEM_PREFIX_PATH "")
# The store's 64-bit libs are in <dep>/lib/amd64 (the illumos layout). Without this, find_library takes <dep>/lib, the 32-bit one, for a
# 64-bit build (measured on chef, cmake 4.1.2: find_package(ZLIB) -> zlib-1.3.2/lib/libz.so, ELF 32-bit). ABI is mk-src-pkg's.
if("$ENV{ABI}" STREQUAL "64")
  set(CMAKE_LIBRARY_ARCHITECTURE amd64)
endif()
# Never a host prefix, however a search reached it (a recipe's -DCMAKE_IGNORE_PREFIX_PATH is kept: appended to). "/" too: /lib/libz.so
# (a64s, aarch64 libgit2).
list(APPEND CMAKE_IGNORE_PREFIX_PATH / /usr /usr/local /usr/gnu /usr/sfw /opt /opt/local)
