# pkgs/illumos/input-stack -- libinput on illumos (tpad4): libevdev, mtdev, libinput, and solnix's libudev
# (src/ports/libudev-solnix), for the precision-touchpad evdev node ihid exports (/dev/input/event<N>).
#
# Outside graphics/ on purpose: graphics/ is every COSMIC app's fixups input (cosmic.nix fixups = ./.), so a
# recipe there moves all 21 COSMIC outs. These four move nothing until a COSMIC build links them.
#
# Linux input headers: libevdev and libinput bundle include/linux/{linux,freebsd}/input*.h, both
# GPL-2.0 WITH Linux-syscall-note. solnix uses FreeBSD's BSD-2 sys/dev/evdev headers instead
# (src/ports/touchpad/evdev, shared with the ihid driver), installed as include/linux/sunos/ plus a
# third arm in the dispatcher header. Licences: libevdev MIT, mtdev MIT, libinput MIT, libudev-solnix MIT.
{ mkSrcPkg, meson, samurai, pkgconf, python3 ? null, gnupatch ? null, libc, world, gate, solnixDev, tools, bzip2-bin ? null, hostTools ? [ ],
  system ? "x86_64-solaris" }:
let
  evdevHeaders = builtins.path { path = ../../../src/ports/touchpad/evdev; name = "solnix-evdev-headers"; };
  pc = "export PATH=${pkgconf}/bin:$PATH";
  # generator scripts run via /usr/bin/env python3 (libevdev make-event-names.py, libinput's): the store python3 (a solnix
  # host has none on PATH); null = the OI bhost's /usr/bin/python3.14, as graphics/libs.nix.
  py = if python3 == null then "mkdir -p \"$TMPDIR/py\" && ln -sf /usr/bin/python3.14 \"$TMPDIR/py/python3\" && export PATH=\"$TMPDIR/py:$PATH\""
       else "mkdir -p \"$TMPDIR/py\" && ln -sf ${python3}/bin/python3 \"$TMPDIR/py/python3\" && export PATH=\"$TMPDIR/py:$PATH\"";
  mb = flags: ''
    export PATH="${meson}/bin:${samurai}/bin:$PATH" PYTHONDONTWRITEBYTECODE=1
    meson setup _b --prefix="$out" --libdir=lib/amd64 --buildtype=release --wrap-mode=nodownload -Db_ndebug=true ${flags}
    samu -C _b -j4
    samu -C _b install
  '';
  # illumos ld rejects --version-script: the repo's translator in front of $CC (links twice, v2 mapfile)
  vsMap = ''"$BASH" ${../version-script-mapfile.sh} wrap'';
  # <hdr> -> a dispatcher with an illumos (__sun) arm; fails closed if upstream's shape changed
  sunArm = dir: hdr: ''
    grep -q '__FreeBSD__' ${dir}/${hdr}.h || { echo "FATAL: ${dir}/${hdr}.h dispatcher changed" >&2; exit 1; }
    printf '#ifdef __linux__\n#include "linux/%s.h"\n#elif defined(__FreeBSD__)\n#include "freebsd/%s.h"\n#elif defined(__sun)\n#include "sunos/%s.h"\n#endif\n' ${hdr} ${hdr} ${hdr} > ${dir}/${hdr}.h
  '';
in
rec {
  # solnix's libudev: /dev/input/event* + the driver's udev-properties devinfo prop (no udevd, sysfs, netlink).
  libudev-solnix = derivation {
    name = "libudev-solnix-1.0"; inherit system gate solnixDev libc world;
    src = builtins.path { path = ../../../src/ports/libudev-solnix; name = "libudev-solnix-src"; };
    builder = "/usr/bin/bash";
    args = [ "-c" ''
      set -eu
      export PATH="$solnixDev/bin:${builtins.concatStringsSep ":" (map (t: "${t}/bin") tools)}"
      W=$(mktemp -d /tmp/libudev-solnix.XXXXXX); cp -r "$src/." "$W/"; chmod -R u+w "$W"; cd "$W"
      # libdevinfo is the world's (lib/amd64), as libpciaccess links it: its RUNPATH names the world, never /lib
      gmake -f Makefile.illumos LIBC="$libc" WORLD="$world" CC="gcc -I$gate/usr/include -L$gate/usr/lib/amd64" check > check.log 2>&1 \
        || { cat check.log >&2; echo "FATAL: libudev-solnix check" >&2; exit 1; }
      grep -q '^negative controls: 1/1' check.log || { cat check.log >&2; exit 1; }
      mkdir -p "$out/lib/amd64/pkgconfig" "$out/include" "$out/share/libudev-solnix" "$out/bin"
      cp libudev.so.1 "$out/lib/amd64/"; ln -s libudev.so.1 "$out/lib/amd64/libudev.so"; cp libudev.h "$out/include/"
      # udevtest: the touchpad question Settings asks (cosmic-itest t0 touchpad-udev), linked to the installed library
      gcc -std=gnu11 -Wall -Werror -I. -I$gate/usr/include -o "$out/bin/udevtest" udevtest.c -L"$out/lib/amd64" -ludev \
        -Wl,-R,"$out/lib/amd64:$libc/lib/amd64"
      cp check.log "$out/share/libudev-solnix/"
      printf 'prefix=%s\nlibdir=%s/lib/amd64\nincludedir=%s/include\nName: libudev\nDescription: solnix libudev (libudev-solnix)\nVersion: 255\nLibs: -L%s/lib/amd64 -ludev\nCflags: -I%s/include\n' \
        "$out" "$out" "$out" "$out" "$out" > "$out/lib/amd64/pkgconfig/libudev.pc"
      cd /; find "$W" -depth -delete
    '' ];
  };

  libevdev = mkSrcPkg {
    pname = "libevdev"; version = "1.13.6";
    src = { url = "https://www.freedesktop.org/software/libevdev/libevdev-1.13.6.tar.xz";
            sha256 = "73f215eccbd8233f414737ac06bca2687e67c44b97d2d7576091aa9718551110"; };
    build = ''
      mkdir -p include/linux/sunos
      cp ${evdevHeaders}/input.h ${evdevHeaders}/input-event-codes.h ${evdevHeaders}/uinput.h include/linux/sunos/
      chmod u+w include/linux/sunos/*
      sed -i 's|#include <dev/evdev/input.h>|#include "input.h"|' include/linux/sunos/uinput.h
      ${sunArm "include/linux" "input"}
      ${sunArm "include/linux" "uinput"}
      ${vsMap}
      ${py}
      ${pc}
      ${mb "-Dtests=disabled -Ddocumentation=disabled -Dtools=disabled"}
      # the installed libevdev.h includes <linux/input.h>: ship the BSD headers with it
      mkdir -p "$out/include/linux" "$out/include/evdev"
      cp ${evdevHeaders}/input.h ${evdevHeaders}/input-event-codes.h "$out/include/evdev/"
      printf '/* solnix: the Linux input ABI from the BSD-2 FreeBSD evdev headers */\n#include <evdev/input.h>\n' > "$out/include/linux/input.h"
      printf '#include <evdev/input-event-codes.h>\n' > "$out/include/linux/input-event-codes.h"
      sed -i 's|^Cflags: \(.*\)$|Cflags: \1 -I''${includedir}|' "$out/lib/amd64/pkgconfig/libevdev.pc"
    '';
  };

  mtdev = mkSrcPkg {
    pname = "mtdev"; version = "1.1.7";
    src = { url = "https://bitmath.org/code/mtdev/mtdev-1.1.7.tar.bz2";
            sha256 = "a107adad2101fecac54ac7f9f0e0a0dd155d954193da55c2340c97f2ff1d814e"; };
    linkDeps = [ libevdev ];   # its include/linux/input.h (the BSD headers), build time only
    deps = [ world ];
    # bzip2: GNU tar unpacks .tar.bz2 through it (a solnix host has none: 'lbzip2: Cannot exec', measured on lixi)
    nativeTools = if bzip2-bin == null then null else [ bzip2-bin ] ++ hostTools;
    build = ''
      # ioctl(2): <sys/ioctl.h> on illumos (glibc declares it via <unistd.h>)
      grep -q '#include "state.h"' src/caps.c || { echo "FATAL: mtdev caps.c anchor" >&2; exit 1; }
      sed -i 's|#include "state.h"|#include "state.h"\n#include <sys/ioctl.h>|' src/caps.c
      CPPFLAGS="-I${libevdev}/include" ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static
      gmake -j4 && gmake install
    '';
  };

  libinput = mkSrcPkg {
    pname = "libinput"; version = "1.31.3";
    src = { url = "https://gitlab.freedesktop.org/libinput/libinput/-/archive/1.31.3/libinput-1.31.3.tar.gz";
            sha256 = "b6749bf6f1890f6631c0a70a027c35fec9d2e096a39f720548896e41474a9854"; };
    deps = [ world libevdev mtdev libudev-solnix ];   # world: libdevinfo (via libudev-solnix), as libpciaccess
    build = ''
      mkdir -p include/linux/sunos
      cp ${evdevHeaders}/input.h ${evdevHeaders}/input-event-codes.h include/linux/sunos/; chmod u+w include/linux/sunos/*
      ${sunArm "include/linux" "input"}   # (libinput has no input-event-codes.h dispatcher: input.h includes the codes)
      # index(3C)/rindex(3C): <strings.h> on illumos
      grep -q '#include <string.h>' src/util-strings.h || { echo "FATAL: util-strings.h anchor" >&2; exit 1; }
      sed -i 's|#include <string.h>|#include <string.h>\n#include <strings.h>|' src/util-strings.h
      # struct winsize / TIOCGWINSZ: <termios.h> on illumos (debug-tablet-pad since 1.29)
      for t in tools/libinput-debug-tablet.c tools/libinput-debug-tablet-pad.c; do
        grep -q '#include <sys/ioctl.h>' $t || { echo "FATAL: $t anchor" >&2; exit 1; }
        sed -i 's|#include <sys/ioctl.h>|#include <sys/ioctl.h>\n#include <termios.h>|' $t
      done
      ${vsMap}
      ${py}
      ${pc}
      # lua-plugins (1.29+, auto by default): off, pinned (solnix has no lua; nixpkgs builds it with lua5_4)
      ${mb "-Dlibwacom=false -Ddebug-gui=false -Dtests=false -Ddocumentation=false -Dlua-plugins=disabled -Dudev-dir=$out/lib/udev -Dzshcompletiondir=no"}
      # the exported API is versioned (LIBINPUT_*), as on Linux
      /usr/bin/pvs -dos "$out/lib/amd64/libinput.so.10" | grep -q 'LIBINPUT_0.12.0: libinput_path_create_context;$' \
        || { echo "FATAL: libinput.so.10 lacks LIBINPUT_0.12.0: libinput_path_create_context" >&2; exit 1; }
      [ -f "$out/share/libinput/50-system-lenovo.quirks" ] || { echo "FATAL: no quirks installed" >&2; exit 1; }
    '';
  };
}
