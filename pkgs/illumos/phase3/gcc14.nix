# gcc14.nix — from-source gcc-14.4.0 for x86_64-solaris (the LATEST proven floor).
#
# The top-level `gcc14` attr in nixpkgs wraps gccFun via `wrapCC`, whose
# bintools-wrapper asserts on the illumos toolchain path (bintools resolves to
# the Solaris ld slice in a shape wrapCC does not expect). So we build the RAW
# compiler derivation (gccFun = callPackage ../development/compilers/gcc) and let
# gcc14-stdenv.nix wrap it separately with wrapCCWith.
#
# Four illumos ports over the stock nixpkgs gcc expression, each a root cause:
#
#   1. TRIPLE. nixpkgs elaborates x86_64-solaris to targetPlatform.config
#      "x86_64-unknown-solaris" (lib/systems kernels.solaris carries no version),
#      so configurePlatforms feeds gcc --target=x86_64-unknown-solaris; config.sub
#      canonicalizes that to x86_64-unknown-solaris2, which gcc/config.gcc lists as
#      an UNSUPPORTED target (only *-*-solaris2.1[1-9]* is supported). Pin the
#      seed's proven native triple x86_64-pc-solaris2.11 (build==host==target).
#
#   2. NATIVE SYSTEM HEADER DIR. The native branch of gcc/common/configure-flags.nix
#      hardcodes --with-native-system-header-dir=${stdenv.cc.libc}/include, but the
#      seed libc slice keeps its headers at usr/include (incdir=/usr/include), so
#      fixincludes fails ("BUILD_SYSTEM_HEADER_DIR does not exist"). Rewrite the
#      flag to ${libc}/usr/include. (This is the fix for the libgcc "cannot compute
#      suffix of object files" wall: the target conftest needs the seed headers on
#      the search path, which this dir provides.)
#
#   3. LIBSTDC++ LINK -lintl/-lm. The seed cc-wrapper's ld force-appends NIX_LDFLAGS
#      to every link, including libtool's `collect-ld -r` partial reload of
#      libstdc++.la (no -L search path). NIX_LDFLAGS carried -lintl (from the
#      gettext nativeBuildInput; illumos gettext is NATIVE in libc, no standalone
#      libintl.so) and -lm (from gcc/default.nix's SunOS NIX_LDFLAGS="-lm"). Both
#      are unresolvable in the -r reload; gcc links libm via its own specs anyway.
#      Drop the gettext nativeBuildInput and clear env.NIX_LDFLAGS.
#
#   4. LIBGCC OUTPUT SPLIT. gcc/common/libgcc.nix's preFixupLibGccPhase moves
#      libgcc_s.so from $lib/lib into a separate $libgcc output then runs
#      `patchelf --set-rpath`. On illumos the SunOS install puts the runtime .so in
#      $out/lib{,/amd64} (not $lib/lib), patchelf is absent (elfedit world), and
#      $lib/lib does not exist -> "mv: cannot stat libgcc_s.so". Drop the
#      (unpopulated) libgcc output and blank the phase; libgcc_s.so stays in
#      $out/lib{,/amd64} where the cc-wrapper RUNPATH points.
#
#   5. LIBGFORTRAN -Werror ON A PHANTOM -I (only when langFortran = true).
#      libgfortran's kind-detection (libgfortran/mk-kinds-h.sh) runs the just-
#      built `gfortran -S` on a per-kind probe using $(FCCOMPILE) = FC +
#      AM_FCFLAGS. common/builder.nix's preUnpack sets
#      NIX_FIXINC_DUMMY="$libc_devdir/include" and feeds it as a bare
#      -I ${libc_dev}/include into CFLAGS_FOR_TARGET/FLAGS_FOR_TARGET. The seed
#      libc slice keeps headers at usr/include (incdir=/usr/include, the FIX-2
#      layout), so ${libc_dev}/include does NOT exist. C/C++ silently ignore a
#      nonexistent -I dir, but libgfortran hardcodes
#      AM_FCFLAGS="-I . -Wall -Werror ..." and the Fortran front-end emits
#      -Wmissing-include-dirs for the phantom dir, which -Werror promotes to a
#      FATAL error. Every kind probe then fails -> kinds.h is emitted empty ->
#      libgfortran.h hits `#error "GFC_INTEGER_4 should be available"`. Strip
#      -Werror from libgfortran's configure(.ac) via postPatch (the gcc build
#      autoreconfs, so both the .ac and the checked-in configure need the edit).
#      The phantom -I stays a harmless warning; kinds.h is populated and
#      libgfortran (libgfortran.so.5) + libquadmath build cleanly. Proven:
#      compiles a Fortran hello-world + a C-main/gfortran-subroutine link into
#      working x86_64-solaris ELFs, and builds openblas 0.3.33 (BLAS+LAPACK).
{
  lib,
  callPackage,
  path,       # the patched nixpkgs source root (gcc lives under it)
  stdenv,
  isl_0_20 ? null,
  langFortran ? false,  # add the gfortran front-end + libgfortran (FIX 5)
}:

let
  gccFun = callPackage (path + "/pkgs/development/compilers/gcc");
  triple = "x86_64-pc-solaris2.11";
  gccver = "14.4.0";
  libc = stdenv.cc.libc; # seed bootstrapLibs slice
  hdr = "${libc}${libc.incdir or "/include"}"; # bootstrapLibs/usr/include

  raw = gccFun {
    majorMinorVersion = "14";
    noSysDirs = true;
    langC = true;
    langCC = true;
    inherit langFortran;
    profiledCompiler = false;
    reproducibleBuild = true;
    enableMultilib = false; # LP64 only (illumos dropped i386 ~2018)
    enableLTO = false;
    enablePlugin = false;
    isl = isl_0_20;
  };

  isBadHdr = f: builtins.match ".*--with-native-system-header-dir=.*" f != null;
  isGettext = d: lib.hasInfix "gettext" (d.pname or d.name or "");
in
raw.overrideAttrs (old: {
  # FIX 1: pin the supported Solaris-11 GNU triple (native).
  configurePlatforms = [ ];
  configureFlags =
    (builtins.filter (f: !(isBadHdr f)) (old.configureFlags or [ ]))
    ++ [
      "--build=${triple}"
      "--host=${triple}"
      "--target=${triple}"
      # FIX 2: seed libc headers live at usr/include, not /include.
      "--with-native-system-header-dir=${hdr}"
    ];
  # FIX 3: gettext -> -lintl (native on illumos); NIX_LDFLAGS -lm both break the
  # libtool -r reload of libstdc++.la. Drop them; gcc links libm via specs.
  nativeBuildInputs = builtins.filter (d: !(isGettext d)) (old.nativeBuildInputs or [ ]);
  env = (old.env or { }) // { NIX_LDFLAGS = ""; };
  # FIX 4: the SunOS install keeps libgcc_s.so in $out/lib{,/amd64}; the glibc
  # move-to-$libgcc + patchelf phase does not apply (no patchelf, no $lib/lib).
  outputs = builtins.filter (o: o != "libgcc") (old.outputs or [ "out" ]);
  preFixupPhases = builtins.filter (p: p != "preFixupLibGccPhase") (old.preFixupPhases or [ ]);
  preFixupLibGccPhase = "";
  # FIX 5 (fortran only): drop libgfortran's hardcoded -Werror so the phantom
  # -I ${libc_dev}/include (nonexistent on illumos) stays a warning instead of
  # failing every mk-kinds-h.sh kind probe. Patch configure.ac (source of truth
  # for the build's autoreconf) AND the checked-in configure.
  postPatch = (old.postPatch or "") + lib.optionalString langFortran ''
    for f in libgfortran/configure.ac libgfortran/configure; do
      substituteInPlace "$f" \
        --replace-quiet '"-I . -Wall -Werror -fimplicit-none' '"-I . -Wall -fimplicit-none'
    done
  '';
})
