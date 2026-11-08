# graphics/libs.nix -- the C libraries under the Wayland/Mesa stack, from source.
{ mkSrcPkg, tools, pkgconf, zlib, world, perl ? null, hostTools ? [ ], gnupatch ? null, python3 ? null }:
let m = tools.mesonBuild; pc = "export PATH=${pkgconf}/bin:$PATH";
  # patch is on /usr/gnu/bin on the OI bhost (gnupatch==null -> no-op); a solnix host has no /usr/gnu, so put the store patch on PATH.
  pp = if gnupatch == null then "" else "export PATH=${gnupatch}/bin:$PATH";
  # python3: dbus's test/data/copy_data_for_tests.py runs via /usr/bin/env python3 at BUILD time. OI bhost: /usr/bin/python3.14; solnix host: the store python3.
  py = if python3 == null then "mkdir -p \"$TMPDIR/py\" && ln -sf /usr/bin/python3.14 \"$TMPDIR/py/python3\" && export PATH=\"$TMPDIR/py:$PATH\"" else "mkdir -p \"$TMPDIR/py\" && ln -sf ${python3}/bin/python3 \"$TMPDIR/py/python3\" && export PATH=\"$TMPDIR/py:$PATH\"";
in
rec {
  expat = mkSrcPkg {
    pname = "expat"; version = "2.10.0";   # 11 High in 2.6.4; 2.10.0 (2026-11-02) is the first with CVE-2026-115506
    src = { url = "https://github.com/libexpat/libexpat/releases/download/R_2_10_0/expat-2.10.0.tar.xz";
            sha256 = "c624ba2998fc65df1163a49641ff3f9ab73138b11641d92c86bee0fb01b1bc7f"; };
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static \
        --without-docbook --without-examples --without-tests
      gmake -j8 && gmake install
    '';
  };

  libffi = mkSrcPkg {
    pname = "libffi"; version = "3.4.6";
    src = { url = "https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz";
            sha256 = "b0dea9df23c863a7a50e825440f3ebffabd65df1497108e5d437747843895a4e"; };
    # make_sunver.pl (the libffi.map-sun version script) is perl: the OI build host had /usr/bin/perl, a solnix host has none (wave4 dixi)
    nativeTools = if perl == null then [ ] else [ perl ] ++ hostTools;
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static \
        --disable-docs --disable-multi-os-directory
      gmake -j8 && gmake install
    '';
  };

  # libwayland-{client,server,egl,cursor} + wayland-scanner. One illumos patch:
  # wl_os_socket_peercred via getpeerucred(3C) (wayland #errors otherwise).
  # epoll/signalfd/timerfd are native on illumos, so no epoll-shim.
  wayland = mkSrcPkg {
    pname = "wayland"; version = "1.23.1";
    src = { url = "https://gitlab.freedesktop.org/wayland/wayland/-/releases/1.23.1/downloads/wayland-1.23.1.tar.xz";
            sha256 = "864fb2a8399e2d0ec39d56e9d9b753c093775beadc6022ce81f441929a81e5ed"; };
    deps = [ expat libffi ];
    build = ''
      ${pp}
      patch -p1 < ${./patches/wayland-1.23.1-illumos-peercred.patch}
      ${pc}
      ${m "-Ddocumentation=false -Dtests=false -Ddtd_validation=false -Dc_args=-D__EXTENSIONS__ '-Dc_link_args=-lsocket -lnsl'"}
    '';
  };

  wayland-protocols = mkSrcPkg {
    pname = "wayland-protocols"; version = "1.38";
    src = { url = "https://gitlab.freedesktop.org/wayland/wayland-protocols/-/releases/1.38/downloads/wayland-protocols-1.38.tar.xz";
            sha256 = "ff17292c05159d2b20ce6cacfe42d7e31a28198fa1429a769b03af7c38581dbe"; };
    deps = [ wayland ];
    build = ''
      ${pc}
      ${m "-Dtests=false"}
    '';
  };

  # The reference D-Bus daemon + libdbus-1 (NixOS pkgs.dbus): the session bus cosmic-session
  # and every COSMIC app talk on (start-cosmic runs dbus-run-session). Prefix-relative config
  # (session.conf in $out/share/dbus-1), so a session bus needs nothing in /etc. No systemd,
  # no X11 autolaunch; poll, not epoll (NixOS enables epoll on Linux only). -lsocket: meson's
  # has_function(socket) passes, but tools/ links with -z defs and no network_libs.
  dbus = mkSrcPkg {
    pname = "dbus"; version = "1.16.2";
    src = { url = "https://dbus.freedesktop.org/releases/dbus/dbus-1.16.2.tar.xz";
            sha256 = "0ba2a1a4b16afe7bceb2c07e9ce99a8c2c3508e5dec290dbb643384bd6beb7e2"; };
    deps = [ expat world ];   # world: libbsm (ADT audit, the Solaris arm) for the launch helper
    build = ''
      # meson calls illumos "sunos"; dbus's Solaris arms test for "solaris" (meson.build:174
      # -D_XOPEN_SOURCE=500 for SCM_RIGHTS fd passing; :535 console owner file; :1382 summary). Same OS family.
      grep -c "host_os.contains('solaris')" meson.build | grep -qx 3 || { echo "FATAL: dbus solaris anchors" >&2; exit 1; }
      sed -i "s/host_os.contains('solaris')/(host_os.contains('solaris') or host_os == 'sunos')/" meson.build
      # ...and upstream writes ' -D_XOPEN_SOURCE=500' with a leading space, so
      # cc.get_supported_arguments() drops it (msghdr then has no msg_control: measured).
      grep -q "' -D_XOPEN_SOURCE=500'" meson.build || { echo "FATAL: dbus XOPEN anchor" >&2; exit 1; }
      sed -i "s/' -D_XOPEN_SOURCE=500'/'-D_XOPEN_SOURCE=500'/" meson.build
      ${py}   # test/data/copy_data_for_tests.py: /usr/bin/env python3
      ${pc}
      ${m "-Dsystemd=disabled -Dx11_autolaunch=disabled -Dselinux=disabled -Dapparmor=disabled -Dlibaudit=disabled -Depoll=disabled -Dinotify=disabled -Dkqueue=disabled -Dlaunchd=disabled -Ddoxygen_docs=disabled -Dducktype_docs=disabled -Dxml_docs=disabled -Dqt_help=disabled -Dmodular_tests=disabled -Dsession_socket_dir=/tmp '-Dc_link_args=-lsocket -lnsl'"}
      # run check: dbus-run-session (what start-cosmic uses) starts a bus that answers ListNames.
      "$out/bin/dbus-run-session" -- "$out/bin/dbus-send" --session --print-reply --dest=org.freedesktop.DBus \
        /org/freedesktop/DBus org.freedesktop.DBus.ListNames | grep -q '"org.freedesktop.DBus"' \
        || { echo "FATAL: session bus did not answer ListNames" >&2; exit 1; }
    '';
  };

  # libdrm core only (no vendor sublibs: iris/anv talk i915 ioctls directly).
  # The patch forces the Linux _IOC encoding the i915 port decodes
  # (src/drm-port/i915/i915_drmioc.h) and installs the shim beside drm.h.
  libdrm = mkSrcPkg {
    pname = "libdrm"; version = "2.4.120";
    src = { url = "https://dri.freedesktop.org/libdrm/libdrm-2.4.120.tar.xz";
            sha256 = "3bf55363f76c7250946441ab51d3a6cc0ae518055c0ff017324ab76cdefb327a"; };
    build = ''
      ${pp}
      patch -p1 < ${./patches/libdrm-2.4.120-illumos-ioctl.patch}
      # drmGetDevice2 & co. on illumos (no DRM major 226, clone minors): Mesa's loader needs it.
      patch -p1 < ${./patches/libdrm-2.4.120-illumos-device.patch}
      # PCI info through the caller's fd (seatd passes card0; /dev/dri stays 0600 root)
      patch -p1 < ${./patches/libdrm-2.4.120-illumos-fd-pciinfo.patch}
      ${pc}
      ${m "-Dintel=disabled -Dradeon=disabled -Damdgpu=disabled -Dnouveau=disabled -Dvmwgfx=disabled -Dfreedreno=disabled -Dvc4=disabled -Detnaviv=disabled -Dcairo-tests=disabled -Dman-pages=disabled -Dvalgrind=disabled -Dtests=false -Dudev=false -Dc_args=-D__EXTENSIONS__"}
    '';
  };
}
