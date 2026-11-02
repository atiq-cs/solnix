# solnix-toolchain.cmake -- every store-only build's CMAKE_TOOLCHAIN_FILE (mk-src-pkg exports it; cmake >= 3.21 reads the env var).
# cmake searches the system prefixes (/usr, /usr/local, /opt, /usr/gnu ...) for find_program/find_library/find_path whatever PATH
# says: fortune-mod found /usr/bin tools on the OI host (recipes1). NixOS's cmake setup hook sets the same knobs.
set(CMAKE_FIND_USE_SYSTEM_ENVIRONMENT_PATH ON)   # PATH (store-only) is the search path for programs
set(CMAKE_FIND_USE_CMAKE_SYSTEM_PATH OFF)        # no /usr, /usr/local, /opt, /sw ... platform prefixes
set(CMAKE_SYSTEM_IGNORE_PREFIX_PATH "/usr;/usr/local;/usr/gnu;/opt;/usr/sfw;/sw;/opt/local")
set(CMAKE_SYSTEM_PREFIX_PATH "")
