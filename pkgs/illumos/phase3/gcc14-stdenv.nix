# gcc14-stdenv.nix — a gcc-14.4.0 stdenv variant for x86_64-solaris.
#
# Wraps the from-source gcc-14.4.0 (gcc14.nix) with the SAME cc-wrapper wiring
# the seed gcc-10 uses (pkgs/stdenv/illumos mkStdenv): reuse the illumos Solaris
# bintools + seed libc, and feed the -B/--sysroot/GCC_EXEC_PREFIX flags so the
# fresh driver finds its own internal cc1/crt + the seed libc headers/crt. Then
# overrideCC the illumos stdenv so package builds use gcc-14 instead of gcc-10.
#
# The seed gcc-10 wrapper points -B/GCC_EXEC_PREFIX at usr/gcc/10/... (the OI
# nested prefix). gcc-14's from-source layout is the nixpkgs-standard
# $out/bin + $out/lib/gcc/<triple>/14.4.0/, so the -B set names those paths.
# The seedSyslibs -L (the versioned illumos syslibs the seed cc-wrapper adds) is
# carried over so link probes referencing libmd/libmp/... still resolve.
#
# USAGE (fork overlay): expose as pkgs.gcc14Stdenv; a proof package builds via
# `pkgs.zlib.override { stdenv = pkgs.gcc14Stdenv; }`.
{
  lib,
  wrapCCWith,
  overrideCC,
  stdenv,
  gnugrep,
  coreutils,
  seedSyslibs,
  gcc14, # the from-source gcc-14.4.0 (gcc14.nix)
}:

let
  prevCC = stdenv.cc; # the seed gcc-10 cc-wrapper
  triple = "x86_64-pc-solaris2.11";
  gccver = "14.4.0";
  libc = prevCC.libc; # seed bootstrapLibs slice

  cc14 = wrapCCWith {
    cc = gcc14;
    bintools = prevCC.bintools; # the Solaris ld wrapper (unchanged)
    inherit libc gnugrep coreutils;
    extraBuildCommands = ''
      internal="${gcc14}/lib/gcc/${triple}/${gccver}"
      # the fresh driver's own internal cc1/crt + include (nixpkgs layout)
      echo "-B${gcc14}/bin"                              >> $out/nix-support/cc-cflags
      echo "-B$internal"                                 >> $out/nix-support/cc-cflags
      # seed libc headers/crt: sysroot + native-header-dir at usr/include + crt -B
      echo "--sysroot=${libc}"                           >> $out/nix-support/cc-cflags
      echo "-idirafter ${libc}/usr/include"              >> $out/nix-support/cc-cflags
      echo "-B${libc}/usr/lib/amd64"                     >> $out/nix-support/cc-cflags
      echo "-L${gcc14}/lib/amd64"                        >> $out/nix-support/cc-cflags
      echo "-L${seedSyslibs}/lib/amd64"                  >> $out/nix-support/cc-cflags
      # route collect2 at THIS wrapper's own bin/ld -> ld-solaris (GNU->Solaris xlat)
      echo "-B$out/bin"                                  >> $out/nix-support/cc-cflags
      echo "export GCC_EXEC_PREFIX=${gcc14}/lib/gcc/"    >> $out/nix-support/setup-hook
    '';
  };
in
overrideCC stdenv cc14
