# aarch64/mesa.nix -- Mesa 24.0.9 for aarch64-illumos (a64s): gallium softpipe (swrast) only, EGL + GBM + GLES2, Wayland
# platform. Same version, illumos patches and flags as ../graphics/mesa.nix (x86: iris + anv + softpipe), minus the hardware
# drivers: illumos has no ARM GPU driver, and llvmpipe/lavapipe need an LLVM derivation (none on aarch64), as x86's note says.
# NixOS's aarch64 mesa also ships the software rasterizer; this is that, without LLVM. x86's mesa is unchanged.
# Build tools: desktop/gtk/tools.nix's meson on the store python3 (x86: graphics/tools.nix's meson on the OI host's python3.9),
# graphics/tools.nix's mako + markupsafe (pure python), and packaging (mesa's mako version check imports packaging.version, or
# distutils, which python 3.12+ removed; NixOS's mesa takes python3Packages.packaging for the same check).
{ mkSrcPkg, tools, python3, bison, flex, zlib, expat, libffi, wayland, wayland-protocols, libdrm }:
let
  py = "PYTHONDONTWRITEBYTECODE=1 ${python3}/bin/python3";
  # mako + markupsafe: ../graphics/tools.nix's sources, with the import check on the store python3 (x86: /usr/bin/python3.9)
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
      PYTHONPATH="$out/lib/python:${markupsafe}/lib/python" ${py} -c 'import mako.template' || { echo "FATAL: mako does not import" >&2; exit 1; }
    '';
  };
  packaging = mkSrcPkg {
    pname = "packaging"; version = "24.1";   # PyPI sdist (pypi.org json digest)
    src = { url = "https://files.pythonhosted.org/packages/51/65/50db4dda066951078f0a96cf12f4b9ada6e4b811516bf0262c0f4f7064d4/packaging-24.1.tar.gz";
            sha256 = "026ed72c8ed3fcce5bf8950572258698927fd1dbda10a5e981cdf0ac37f4f002"; };
    build = ''
      mkdir -p "$out/lib/python" && cp -r src/packaging "$out/lib/python/"
      PYTHONPATH="$out/lib/python" ${py} -c 'from packaging.version import Version; assert Version("1.3.5") >= Version("0.8.0")' \
        || { echo "FATAL: packaging does not import" >&2; exit 1; }
    '';
  };
in
{ inherit packaging mako markupsafe; } // { mesa = mkSrcPkg {
  pname = "mesa"; version = "24.0.9";
  src = { url = "https://archive.mesa3d.org/mesa-24.0.9.tar.xz";
          sha256 = "51aa686ca4060e38711a9e8f60c8f1efaa516baf411946ed7f2c265cd582ca4c"; };
  deps = [ zlib expat wayland libdrm ];
  linkDeps = [ wayland-protocols libffi ];   # libffi: wayland-client.pc Requires.private (as x86)
  nativeTools = [ bison flex ];              # glsl/glcpp parsers (x86: the OI host's /usr/bin bison + flex)
  build = ''
    patch -p1 < ${../graphics/patches/mesa-24.0.9-illumos.patch}
    patch -p1 < ${../graphics/patches/mesa-24.0.9-illumos-build-id.patch}
    patch -p1 < ${../graphics/patches/mesa-24.0.9-illumos-dmabuf.patch}
    export PATH=${wayland}/bin:$PATH   # wayland-scanner
    export PYTHONPATH=${mako}/lib/python:${markupsafe}/lib/python:${packaging}/lib/python
    ${tools.mesonBuild (builtins.concatStringsSep " " [
      "-Dgallium-drivers=swrast -Dvulkan-drivers= -Dllvm=disabled"
      "-Dplatforms=wayland -Degl=enabled -Dgbm=enabled -Dgles1=disabled -Dgles2=enabled"
      "-Dopengl=true -Dshared-glapi=enabled -Dglx=disabled -Dglvnd=false -Ddri3=disabled"
      "-Dvideo-codecs= -Dzstd=disabled -Dvalgrind=disabled -Dlibunwind=disabled"
      "-Dlmsensors=disabled -Dintel-clc=disabled -Dosmesa=false"
      "-Dc_args='-D_POSIX_PTHREAD_SEMANTICS -Wno-error=incompatible-pointer-types -Wno-error=pointer-sign'"
      "-Dcpp_args='-D_POSIX_PTHREAD_SEMANTICS -Wno-error=incompatible-pointer-types'"
      "'-Dc_link_args=-lsocket -lnsl' '-Dcpp_link_args=-lsocket -lnsl'"
    ])}
    for f in lib/amd64/dri/swrast_dri.so lib/amd64/libEGL.so.1 lib/amd64/libgbm.so.1 lib/amd64/libGLESv2.so.2; do
      [ -e "$out/$f" ] || { echo "FATAL: mesa did not install $f" >&2; exit 1; }
    done
    ! ls "$out"/lib/amd64/dri | grep -v -e '^swrast_dri\.so$' -e '^kms_swrast_dri\.so$' || { echo "FATAL: mesa built a hardware driver" >&2; exit 1; }
    /usr/bin/elfdump -e "$out/lib/amd64/dri/swrast_dri.so" | grep -q EM_AARCH64 || { echo "FATAL: swrast not AARCH64" >&2; exit 1; }
  '';
}; }
