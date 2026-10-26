# graphics/tools.nix -- build-time tools for the meson-built graphics stack
# (wayland, libdrm, Mesa). None of these is in a runtime closure.
#
# meson runs on the build host's python3.9, the way gcc-src.nix runs on the IPS
# seed gcc: a build tool, not shipped. NixOS builds python from source; solnix
# has no from-source python yet (pkgs/illumos/default.nix, solnix-dev-full).
{ mkSrcPkg }:
rec {
  python = "/usr/bin/python3.9";

  meson = mkSrcPkg {
    pname = "meson"; version = "1.4.2";
    src = { url = "https://github.com/mesonbuild/meson/releases/download/1.4.2/meson-1.4.2.tar.gz";
            sha256 = "ea2546a26f4a171a741c1fd036f22c9c804d6198e3259f1df588e01f842dd69f"; };
    build = ''
      patch -p1 < ${./patches/meson-1.4.2-keep-store-rpath.patch}
      mkdir -p "$out/lib/meson" "$out/bin"
      cp -r mesonbuild meson.py "$out/lib/meson/"
      printf '#!/usr/bin/bash\nexec ${python} %s/lib/meson/meson.py "$@"\n' "$out" > "$out/bin/meson"
      chmod +x "$out/bin/meson"
      "$out/bin/meson" --version | grep -qx 1.4.2 || { echo "FATAL: meson --version" >&2; exit 1; }
    '';
  };

  # samurai: a ninja-compatible build runner in C (no C++ bootstrap, no python).
  samurai = mkSrcPkg {
    pname = "samurai"; version = "1.2";
    src = { url = "https://github.com/michaelforney/samurai/releases/download/1.2/samurai-1.2.tar.gz";
            sha256 = "3b8cf51548dfc49b7efe035e191ff5e1963ebc4fe8f6064a5eefc5343eaf78a5"; };
    build = ''
      # no -D__EXTENSIONS__: samurai's own __sun arm (graph.c) expects the
      # POSIX-hidden st_mtim.__tv_sec names, which that define renames.
      patch -p1 < ${./patches/samurai-1.2-illumos-getline.patch}
      gmake CC="$CC" CFLAGS=-O2 PREFIX="$out" install
      "$out/bin/samu" -h 2>&1 | grep -q usage || { echo "FATAL: samu" >&2; exit 1; }
    '';
  };

  # Mesa's generators import mako (and mako imports markupsafe). Pure python:
  # markupsafe falls back to _native.py when its C speedups are absent.
  markupsafe = mkSrcPkg {
    pname = "markupsafe"; version = "2.1.5";
    src = { url = "https://files.pythonhosted.org/packages/source/M/MarkupSafe/MarkupSafe-2.1.5.tar.gz";
            sha256 = "d283d37a890ba4c1ae73ffadf8046435c76e7bc2247bbb63c00bd1a709c6544b"; };
    build = ''mkdir -p "$out/lib/python" && cp -r src/markupsafe "$out/lib/python/"'';
  };
  mako = mkSrcPkg {
    pname = "mako"; version = "1.3.5";
    src = { url = "https://files.pythonhosted.org/packages/67/03/fb5ba97ff65ce64f6d35b582aacffc26b693a98053fa831ab43a437cbddb/Mako-1.3.5.tar.gz";
            sha256 = "48dbc20568c1d276a2698b36d968fa76161bf127194907ea6fc594fa81f943bc"; };
    build = ''
      mkdir -p "$out/lib/python" && cp -r mako "$out/lib/python/"
      PYTHONPATH="$out/lib/python:${markupsafe}/lib/python" ${python} -c 'import mako.template' \
        || { echo "FATAL: mako does not import" >&2; exit 1; }
    '';
  };

  # The shell lines every meson recipe runs; $1.. are the -D flags.
  mesonBuild = flags: ''
    export PATH="${meson}/bin:${samurai}/bin:$PATH"
    meson setup _b --prefix="$out" --libdir=lib/amd64 --buildtype=release \
      --wrap-mode=nodownload -Db_ndebug=true ${flags}
    samu -C _b -j16
    samu -C _b install
  '';
}
