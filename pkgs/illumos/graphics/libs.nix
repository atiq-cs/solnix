# graphics/libs.nix -- the C libraries under the Wayland/Mesa stack, from source.
{ mkSrcPkg, tools, pkgconf, zlib }:
let m = tools.mesonBuild; pc = "export PATH=${pkgconf}/bin:$PATH"; in
rec {
  expat = mkSrcPkg {
    pname = "expat"; version = "2.6.4";
    src = { url = "https://github.com/libexpat/libexpat/releases/download/R_2_6_4/expat-2.6.4.tar.xz";
            sha256 = "a695629dae047055b37d50a0ff4776d1d45d0a4c842cf4ccee158441f55ff7ee"; };
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

  # libdrm core only (no vendor sublibs: iris/anv talk i915 ioctls directly).
  # The patch forces the Linux _IOC encoding the i915 port decodes
  # (src/drm-port/i915/i915_drmioc.h) and installs the shim beside drm.h.
  libdrm = mkSrcPkg {
    pname = "libdrm"; version = "2.4.120";
    src = { url = "https://dri.freedesktop.org/libdrm/libdrm-2.4.120.tar.xz";
            sha256 = "3bf55363f76c7250946441ab51d3a6cc0ae518055c0ff017324ab76cdefb327a"; };
    build = ''
      patch -p1 < ${./patches/libdrm-2.4.120-illumos-ioctl.patch}
      # drmGetDevice2 & co. on illumos (no DRM major 226, clone minors): Mesa's loader needs it.
      patch -p1 < ${./patches/libdrm-2.4.120-illumos-device.patch}
      ${pc}
      ${m "-Dintel=disabled -Dradeon=disabled -Damdgpu=disabled -Dnouveau=disabled -Dvmwgfx=disabled -Dfreedreno=disabled -Dvc4=disabled -Detnaviv=disabled -Dcairo-tests=disabled -Dman-pages=disabled -Dvalgrind=disabled -Dtests=false -Dudev=false -Dc_args=-D__EXTENSIONS__"}
    '';
  };
}
