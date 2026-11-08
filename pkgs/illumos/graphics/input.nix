# graphics/input.nix -- the C libraries cosmic-comp links beyond Mesa:
# pixman, libxkbcommon (+ xkeyboard-config data), libdisplay-info, libseat.
{ mkSrcPkg, tools, pkgconf, python3 ? null, gnupatch ? null, perl ? null, bison ? null }:
let m = tools.mesonBuild; pc = "export PATH=${pkgconf}/bin:$PATH";
  # patch is on /usr/gnu/bin on the OI bhost (gnupatch==null -> no-op); a solnix host has no /usr/gnu, so put the store patch on PATH.
  pp = if gnupatch == null then "" else "export PATH=${gnupatch}/bin:$PATH";
  # perl: xkeyboard-config's rules/xml2lst.pl runs via /usr/bin/env perl. On the OI bhost perl is /usr/bin (perl==null -> no-op); a solnix host has none.
  pl = if perl == null then "" else "export PATH=${perl}/bin:$PATH";
  # bison: libxkbcommon's meson needs a YACC (bison or byacc). On the OI bhost it is /usr/bin/bison (bison==null -> no-op); a solnix host has none.
  bs = if bison == null then "" else "export PATH=${bison}/bin:$PATH";
  # python3: libdisplay-info's tool/gen-search-table.py runs via /usr/bin/env python3. OI bhost: /usr/bin/python3.14; solnix host: the store python3.
  py = if python3 == null then "mkdir -p \"$TMPDIR/py\" && ln -sf /usr/bin/python3.14 \"$TMPDIR/py/python3\" && export PATH=\"$TMPDIR/py:$PATH\"" else "mkdir -p \"$TMPDIR/py\" && ln -sf ${python3}/bin/python3 \"$TMPDIR/py/python3\" && export PATH=\"$TMPDIR/py:$PATH\"";
in
rec {
  pixman = mkSrcPkg {
    pname = "pixman"; version = "0.43.4";
    src = { url = "https://www.x.org/releases/individual/lib/pixman-0.43.4.tar.gz";
            sha256 = "a0624db90180c7ddb79fc7a9151093dc37c646d8c38d3f232f767cf64b85a226"; };
    build = ''
      ${pc}
      ${m "-Dtests=disabled -Ddemos=disabled -Dgtk=disabled -Dlibpng=disabled -Dopenmp=disabled"}
    '';
  };

  # Keyboard maps (data only). NixOS: xkeyboard_config, libxkbcommon's xkb-config-root.
  xkeyboard-config = mkSrcPkg {
    pname = "xkeyboard-config"; version = "2.43";
    src = { url = "https://www.x.org/releases/individual/data/xkeyboard-config/xkeyboard-config-2.43.tar.xz";
            sha256 = "c810f362c82a834ee89da81e34cd1452c99789339f46f6037f4b9e227dd06c01"; };
    build = ''
      # rules/ needs python >= 3.11 (enum.StrEnum): the store python3 (3.13; wave6), the OI host's python3.14 on the seed path
      mkdir -p "$TMPDIR/py" && ln -sf ${if python3 == null then "/usr/bin/python3.14" else "${python3}/bin/python3"} "$TMPDIR/py/python3" && export PATH="$TMPDIR/py:$PATH"
      ${pl}   # rules/xml2lst.pl: /usr/bin/env perl
      ${m "-Dnls=false -Dxorg-rules-symlinks=true -Dcompat-rules=true"}
      [ -e "$out/share/X11/xkb/rules/evdev" ] || { echo "FATAL: no rules/evdev" >&2; exit 1; }
    '';
  };

  # libxkbcommon only: no -x11 (no xcb), no xkbregistry (needs libxml2; cosmic-comp does not link it).
  libxkbcommon = mkSrcPkg {
    pname = "libxkbcommon"; version = "1.7.0";
    src = { url = "https://xkbcommon.org/download/libxkbcommon-1.7.0.tar.xz";
            sha256 = "65782f0a10a4b455af9c6baab7040e2f537520caa2ec2092805cdfd36863b247"; };
    build = ''
      ${pc}
      ${bs}   # meson needs a YACC (bison); host /usr/bin/bison on the OI bhost, store bison on a solnix host
      ${m "-Denable-x11=false -Denable-xkbregistry=false -Denable-wayland=false -Denable-docs=false -Denable-tools=false -Denable-bash-completion=false -Dxkb-config-root=${xkeyboard-config}/share/X11/xkb -Dxkb-config-extra-path=/etc/xkb -Dx-locale-root=${xkeyboard-config}/share/X11/locale"}
    '';
  };

  # pnp.ids for libdisplay-info's vendor table (build input only).
  hwdata = mkSrcPkg {
    pname = "hwdata"; version = "0.390";
    src = { url = "https://github.com/vcrhonek/hwdata/archive/refs/tags/v0.390.tar.gz";
            sha256 = "f10684093d2a7780de8a96d3dd8a2dd544ed6136dd359197750c42bb08ce526f"; };
    build = ''
      mkdir -p "$out/share/hwdata" "$out/share/pkgconfig" && cp pnp.ids "$out/share/hwdata/"
      printf 'pkgdatadir=%s/share/hwdata\nName: hwdata\nDescription: hwdata\nVersion: 0.390\n' "$out" > "$out/share/pkgconfig/hwdata.pc"
    '';
  };

  libdisplay-info = mkSrcPkg {
    pname = "libdisplay-info"; version = "0.2.0";
    src = { url = "https://gitlab.freedesktop.org/emersion/libdisplay-info/-/releases/0.2.0/downloads/libdisplay-info-0.2.0.tar.xz";
            sha256 = "5a2f002a16f42dd3540c8846f80a90b8f4bdcd067a94b9d2087bc2feae974176"; };
    linkDeps = [ hwdata ];
    build = ''
      # illumos ld has no --version-script (and v1 mapfiles take no globs): export all.
      sed -i "s|link_args: symbols_flag,||" meson.build
      ${py}   # tool/gen-search-table.py: /usr/bin/env python3
      ${pc}
      ${m "-Dc_args=-D__EXTENSIONS__"}
    '';
  };

  # seatd + libseat, builtin and seatd backends, no logind: NixOS seatd with
  # systemdSupport = false is exactly -Dlibseat-logind=disabled -Dlibseat-builtin=enabled -Dserver=enabled.
  seatd = mkSrcPkg {
    pname = "seatd"; version = "0.9.1";
    src = { url = "https://git.sr.ht/~kennylevinsen/seatd/archive/0.9.1.tar.gz";
            sha256 = "819979c922a0be258aed133d93920bce6a3d3565a60588d6d372ce9db2712cd3"; };
    build = ''
      ${pp}
      patch -p1 < ${./patches/seatd-0.9.1-illumos.patch}
      # realpath(/dev/dri/card0) is a /devices/...:card0 node on illumos: still DRM.
      patch -p1 < ${./patches/seatd-0.9.1-illumos-devices-path.patch}
      # /dev/kbd and /dev/mouse (conskbd/consms) open through the seat, like the DRM node.
      patch -p1 < ${./patches/seatd-0.9.1-illumos-vuid.patch}
      sed -i "s|link_args: symbols_flag,||" meson.build   # no --version-script on illumos ld
      ${pc}
      ${m "-Dlibseat-logind=disabled -Dlibseat-seatd=enabled -Dlibseat-builtin=enabled -Dserver=enabled -Dexamples=disabled -Dman-pages=disabled '-Dc_link_args=-lsocket -lnsl'"}
    '';
  };
}
