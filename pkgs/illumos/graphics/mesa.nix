# graphics/mesa.nix -- Mesa 24.0.9 for x86_64-illumos, one derivation:
#   gallium iris (Iris Xe, hardware GL/GLES) + softpipe (CPU fallback),
#   vulkan intel (anv), EGL + GBM, platforms=wayland, against the nix wayland.
#
# Why 24.0.9: 24.3+ makes iris/anv require intel_clc (LLVM + libclc +
# SPIRV-LLVM-Translator), and no LLVM derivation exists yet. 24.0.9 is also the
# pin the C2/ANV ports were measured on (src/drm-port/anv/ANV-STATUS.md).
# llvmpipe/lavapipe need an LLVM derivation too, so softpipe is the CPU GL.
#
# iris/anv need a DRM render node only at RUN time (i915 stage B). They build now.
{ mkSrcPkg, tools, pkgconf, zlib, expat, libffi, wayland, wayland-protocols, libdrm, cmake ? null, hostTools ? [ ], gnupatch ? null, python3 ? null, bison ? null, flex ? null, gnum4 ? null }:
let
  # patch is on /usr/gnu/bin on the OI bhost (gnupatch==null -> no-op); a solnix host has no /usr/gnu, so put the store patch on PATH.
  pp = if gnupatch == null then "" else "export PATH=${gnupatch}/bin:$PATH";
  # python3: mesa's meson (find_program('python3'), meson.build:923) and its mako codegen need python3 on PATH.
  # OI bhost: /usr/bin/python3 (python3==null -> fall back); solnix host: the store python3.
  py = if python3 == null then "mkdir -p \"$TMPDIR/py\" && ln -sf /usr/bin/python3 \"$TMPDIR/py/python3\" && export PATH=\"$TMPDIR/py:$PATH\"" else "mkdir -p \"$TMPDIR/py\" && ln -sf ${python3}/bin/python3 \"$TMPDIR/py/python3\" && export PATH=\"$TMPDIR/py:$PATH\"";
  # bison: mesa's meson needs a YACC (glsl parser, meson.build:1944). OI bhost /usr/bin/bison; solnix host store bison.
  bs = if bison == null then "" else "export PATH=${bison}/bin:$PATH";
  # flex: mesa's meson needs a lexer (meson.build:1955). OI bhost /usr/bin/flex; solnix host store flex.
  fl = if flex == null then "" else "export PATH=${flex}/bin:$PATH";
  # gnum4: flex runs `m4 -P`; the world's illumos-userland m4 (on PATH via `world`) rejects -P. Prepend GNU m4.
  m4h = if gnum4 == null then "" else "export PATH=${gnum4}/bin:$PATH";
  # glslang compiles anv's five internal GLSL shaders at build time. Host-run
  # C++ tool, built with the store cmake (it ran the OI host's /usr/bin/cmake before wave6); nothing of it ships.
  glslang = mkSrcPkg ({
    pname = "glslang"; version = "14.3.0";
    src = { url = "https://github.com/KhronosGroup/glslang/archive/refs/tags/14.3.0.tar.gz";
            sha256 = "be6339048e20280938d9cb399fcdd06e04f8654d43e170e8cce5a56c9a754284"; };
    build = ''
      cmake -S . -B _b -DCMAKE_INSTALL_PREFIX="$out" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" -DENABLE_OPT=OFF \
        ${if python3 == null then "" else "-DPython3_EXECUTABLE=${python3}/bin/python3 "}-DGLSLANG_TESTS=OFF -DENABLE_HLSL=OFF -DBUILD_SHARED_LIBS=OFF -DCMAKE_INSTALL_LIBDIR=lib/amd64
      gmake -C _b -j16 install
      "$out/bin/glslangValidator" --version | grep -q Glslang || { echo "FATAL: glslang" >&2; exit 1; }
    '';
  } // (if cmake == null then { } else { nativeTools = [ cmake ] ++ hostTools; }));
in
mkSrcPkg {
  pname = "mesa"; version = "24.0.9";
  src = { url = "https://archive.mesa3d.org/mesa-24.0.9.tar.xz";
          sha256 = "51aa686ca4060e38711a9e8f60c8f1efaa516baf411946ed7f2c265cd582ca4c"; };
  deps = [ zlib expat wayland libdrm ];
  # libffi: wayland-client.pc Requires.private it (build-time .pc lookup only).
  linkDeps = [ wayland-protocols libffi ];
  build = ''
    ${pp}
    patch -p1 < ${./patches/mesa-24.0.9-illumos.patch}
    # illumos ld has no --build-id: anv's UUIDs and iris's disk cache need one (fallback note).
    patch -p1 < ${./patches/mesa-24.0.9-illumos-build-id.patch}
    # PIPE_CAP_DMABUF on illumos (dma-buf fds, src/drm-port obsd_file.c): EGL_EXT_image_dma_buf_import.
    patch -p1 < ${./patches/mesa-24.0.9-illumos-dmabuf.patch}
    export PATH=${pkgconf}/bin:${glslang}/bin:${wayland}/bin:$PATH
    ${py}   # mesa meson find_program('python3') + mako codegen
    ${bs}   # mesa meson YACC (glsl parser, meson.build:1944)
    ${fl}   # mesa meson lexer (meson.build:1955)
    ${m4h}  # flex runs m4 -P: GNU m4, not the world's illumos m4
    export PYTHONPATH=${tools.mako}/lib/python:${tools.markupsafe}/lib/python:${tools.packaging}/lib/python   # packaging: mako's version check
    ${tools.mesonBuild (builtins.concatStringsSep " " [
      "-Dgallium-drivers=iris,swrast -Dvulkan-drivers=intel -Dllvm=disabled"
      "-Dplatforms=wayland -Degl=enabled -Dgbm=enabled -Dgles1=disabled -Dgles2=enabled"
      "-Dopengl=true -Dshared-glapi=enabled -Dglx=disabled -Dglvnd=false -Ddri3=disabled"
      "-Dvideo-codecs= -Dzstd=disabled -Dvalgrind=disabled -Dlibunwind=disabled"
      "-Dlmsensors=disabled -Dintel-clc=disabled -Dosmesa=false"
      # _POSIX_PTHREAD_SEMANTICS: the POSIX 5-argument getpwuid_r (disk_cache_os.c).
      "-Dc_args='-D_POSIX_PTHREAD_SEMANTICS -Wno-error=incompatible-pointer-types -Wno-error=pointer-sign'"
      "-Dcpp_args='-D_POSIX_PTHREAD_SEMANTICS -Wno-error=incompatible-pointer-types'"
      "'-Dc_link_args=-lsocket -lnsl' '-Dcpp_link_args=-lsocket -lnsl'"
    ])}
    # The proof the brief asks for, checked here so a build without it fails.
    for f in lib/amd64/dri/iris_dri.so lib/amd64/dri/swrast_dri.so lib/amd64/libvulkan_intel.so \
             lib/amd64/libEGL.so.1 lib/amd64/libgbm.so.1 lib/amd64/libGLESv2.so.2; do
      [ -e "$out/$f" ] || { echo "FATAL: mesa did not install $f" >&2; exit 1; }
    done
    elfdump -e "$out/lib/amd64/dri/iris_dri.so" | grep -q EM_AMD64 || { echo "FATAL: iris not AMD64" >&2; exit 1; }
  '';
}
