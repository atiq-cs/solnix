#!/usr/bin/bash
# cosmic-comp-stubs.sh <vendor-dir> <outlib>: link-only STUB libudev.so.1 + libinput.so.10 (+ .pc).
# STUB, not an implementation: every symbol returns 0/NULL with errno=ENOSYS. The input route is
# the VUID backend (cosmic2/input-route.md); these exist so smithay's backend_udev/backend_libinput
# and cosmic-comp-config's `input` crate LINK. udev_new()/libinput_*_create_context() return NULL,
# so any runtime use fails loudly as an Err, never silently.
set -eu
V=$1; O=$2; T=$(mktemp -d /var/tmp/ccstub.XXXXXX); mkdir -p "$O/pkgconfig"
gen() { # gen <soname> <pcname> <version> <files...>
  so=$1 pcn=$2 ver=$3; shift 3
  # a real library (solnix's libudev, libinput: pkgs/illumos/input-stack) replaces this STUB: it is in libDirs instead
  case " ${REAL_INPUT_LIBS:-} " in *" $so "*) echo "REAL $so (no STUB)" >&2; return 0;; esac
  { echo '#include <errno.h>'; grep -ho 'pub fn [a-z0-9_]*' "$@" | awk '{print $3}' | sort -u |
    awk '{print "long " $1 "() { errno = ENOSYS; return 0; }"}'; } > "$T/$pcn.c"
  n=$(grep -c '^long ' "$T/$pcn.c"); [ "$n" -gt 20 ] || { echo "FATAL: only $n symbols for $so" >&2; exit 1; }
  $CC -shared -fPIC -O1 -o "$O/$so" "$T/$pcn.c" -Wl,-h,"$so"
  ln -sf "$so" "$O/${so%%.so*}.so"
  printf 'libdir=%s\nincludedir=%s\nName: %s\nDescription: STUB (link only)\nVersion: %s\nLibs: -L${libdir} -l%s\nCflags:\n' \
    "$O" "$O" "$pcn" "$ver" "${so#lib}" | sed 's/\.so\.[0-9]*$//' > "$O/pkgconfig/$pcn.pc"
  echo "STUB $so: $n symbols" >&2
}
# Only for the -sys crates this app vendors (cosmic-comp has both; most clients neither).
[ -d "$V/libudev-sys" ] && gen libudev.so.1 libudev 255 "$V"/libudev-sys/src/lib.rs
[ -d "$V/input-sys" ] && gen libinput.so.10 libinput 1.21.0 "$V"/input-sys/src/bindings/*.rs
true
