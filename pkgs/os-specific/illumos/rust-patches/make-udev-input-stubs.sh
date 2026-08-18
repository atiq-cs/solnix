#!/bin/sh
# Regenerate the illumos link stubs for libudev / libinput.
# udev + libinput are Linux hardware C libraries with no illumos port. Several
# COSMIC config crates (cosmic-comp-config -> input -> udev, cosmic-settings
# page-display/page-input) only need these symbols to LINK; the hardware
# enumeration paths are runtime-gated (compositor/session). These stubs export
# every declared symbol as an abort()-ing no-op so the crates link on illumos.
# A real udev/libinput call aborts loudly (never reached at --help / compile).
#
# Symbol lists were extracted from the crate sources:
#   libudev-sys-0.1.4/src/*.rs   -> udev_symbols.txt   (82 fns)
#   input-sys-1.19.0/src/*.rs    -> libinput_symbols.txt (298 libinput_* fns)
#
# Usage: sh make-udev-input-stubs.sh /root/illumos-shims/udev
# Then build with:
#   PKG_CONFIG_PATH=<dir> RUSTFLAGS="-L <dir>" cargo build ...
# and at runtime: LD_LIBRARY_PATH=<dir>

set -e
D="${1:-/root/illumos-shims/udev}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$D"

# libudev stub
{
  echo '#include <stdlib.h>'
  while read s; do echo "long $s(){ abort(); return 0; }"; done < "$HERE/udev_symbols.txt"
} > "$D/udev_stub.c"
gcc -shared -fPIC -Wl,-h,libudev.so.1 -o "$D/libudev.so.1" "$D/udev_stub.c"
ln -sf libudev.so.1 "$D/libudev.so"

# libinput stub
{
  echo '#include <stdlib.h>'
  while read s; do echo "long $s(){ abort(); return 0; }"; done < "$HERE/libinput_symbols.txt"
} > "$D/input_stub.c"
gcc -shared -fPIC -Wl,-h,libinput.so.10 -o "$D/libinput.so.10" "$D/input_stub.c"
ln -sf libinput.so.10 "$D/libinput.so"

# pkg-config files (so *-sys build.rs find_library() succeeds)
for lib in udev:249:udev input:1.19.0:input; do
  name="${lib%%:*}"; rest="${lib#*:}"; ver="${rest%%:*}"; link="${rest#*:}"
  cat > "$D/lib$name.pc" <<EOF
prefix=$D
libdir=$D
includedir=$D
Name: lib$name
Description: illumos stub lib$name (link-satisfying no-ops)
Version: $ver
Libs: -L$D -l$link
Cflags: -I$D
EOF
done
echo "stubs + .pc written to $D"
