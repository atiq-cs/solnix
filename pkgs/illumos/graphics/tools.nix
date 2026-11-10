# graphics/tools.nix -- build-time tools for the meson-built graphics stack
# (wayland, libdrm, Mesa). None of these is in a runtime closure.
#
# meson and mako run on the STORE python3 (cli/c-dev.nix) and patch with the store gnupatch (wave6; recipes2: the OI host's
# /usr/bin/python3.9 and patch made meson/mako unrowable on a solnix host). python3/gnupatch come from cliBase (default.nix);
# python3's own deps (libffi expat) are in graphics/libs.nix and use neither, so the reference is not a cycle.
{ mkSrcPkg, python3 ? null, gnupatch ? null, bash ? null }:
rec {
  python = if python3 == null then "/usr/bin/python3.9" else "${python3}/bin/python3";
  # meson's #!: the store bash (gate B9 FAILs #!/usr/bin/bash), as desktop/gtk/tools.nix. null: the old text (an exempt caller).
  shBang = if bash == null then "/usr/bin/bash" else "${bash}/bin/bash";
  patch = if gnupatch == null then "patch" else "${gnupatch}/bin/patch";
  # symbolextractor (every meson shared-library link) puts /usr/gnu/bin first on PATH on SunOS: the OI host's GNU nm/readelf (gate B13).
  # Dropped on the store-python3 instance, as desktop/gtk/tools.nix (1.10.2) and aarch64's meson; python3 == null keeps the old text.
  symFix = if python3 == null then "" else "\n" + ''
      grep -q "os.environ\['PATH'\] = '/usr/gnu/bin:' + origpath" mesonbuild/scripts/symbolextractor.py || { echo "FATAL: symbolextractor anchor" >&2; exit 1; }
      sed -i "s|os.environ\['PATH'\] = '/usr/gnu/bin:' + origpath|os.environ['PATH'] = origpath|" mesonbuild/scripts/symbolextractor.py
      ! grep -q /usr/gnu mesonbuild/scripts/symbolextractor.py || { echo "FATAL: symbolextractor still names /usr/gnu" >&2; exit 1; }'';

  meson = mkSrcPkg {
    pname = "meson"; version = "1.4.2";
    src = { url = "https://github.com/mesonbuild/meson/releases/download/1.4.2/meson-1.4.2.tar.gz";
            sha256 = "ea2546a26f4a171a741c1fd036f22c9c804d6198e3259f1df588e01f842dd69f"; };
    build = ''
      ${patch} -p1 < ${./patches/meson-1.4.2-keep-store-rpath.patch}${symFix}
      mkdir -p "$out/lib/meson" "$out/bin"
      cp -r mesonbuild meson.py "$out/lib/meson/"
      # no bytecode in the out (recipes2: 14 .pyc differed between builds); the wrapper runs with PYTHONDONTWRITEBYTECODE=1
      find "$out/lib/meson" -name __pycache__ -prune -exec rm -r {} + 2>/dev/null || true
      ! find "$out" -name '*.pyc' | grep -q . || { echo "FATAL: meson ships .pyc" >&2; exit 1; }
      printf '#!${shBang}\nexport PYTHONDONTWRITEBYTECODE=1\nexec ${python} %s/lib/meson/meson.py "$@"\n' "$out" > "$out/bin/meson"
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
      ${patch} -p1 < ${./patches/samurai-1.2-illumos-getline.patch}
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
      PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$out/lib/python:${markupsafe}/lib/python" ${python} -c 'import mako.template' \
        || { echo "FATAL: mako does not import" >&2; exit 1; }
      ! find "$out" -name '*.pyc' | grep -q . || { echo "FATAL: mako ships .pyc" >&2; exit 1; }
    '';
  };

  # mesa's meson.build checks mako's version with packaging.version, else distutils, which python 3.12 removed: on the store
  # python3 (3.13) mesa needs packaging (a64s, aarch64/mesa.nix: the same recipe; NixOS's mesa takes python3Packages.packaging).
  packaging = mkSrcPkg {
    pname = "packaging"; version = "24.1";   # PyPI sdist (pypi.org json digest)
    src = { url = "https://files.pythonhosted.org/packages/51/65/50db4dda066951078f0a96cf12f4b9ada6e4b811516bf0262c0f4f7064d4/packaging-24.1.tar.gz";
            sha256 = "026ed72c8ed3fcce5bf8950572258698927fd1dbda10a5e981cdf0ac37f4f002"; };
    build = ''
      mkdir -p "$out/lib/python" && cp -r src/packaging "$out/lib/python/"
      PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$out/lib/python" ${python} -c 'from packaging.version import Version; assert Version("1.3.5") >= Version("0.8.0")' \
        || { echo "FATAL: packaging does not import" >&2; exit 1; }
    '';
  };

  # The shell lines every meson recipe runs; $1.. are the -D flags.
  mesonBuild = flags: ''
    export PATH="${meson}/bin:${samurai}/bin:$PATH"
    # no .pyc into meson/mako/markupsafe: a root build on a writable store (single-user OI host) rewrote them after registration (wave3)
    export PYTHONDONTWRITEBYTECODE=1
    meson setup _b --prefix="$out" --libdir=lib/amd64 --buildtype=release \
      --wrap-mode=nodownload -Db_ndebug=true ${flags}
    samu -C _b -j16
    samu -C _b install
  '';
}
