# Modern compiler toolchains for solnix — SLICED from the OpenIndiana host IPS
# install and RUNPATH-relocated into the /nix/store, same mechanism as the world
# slices (docs/design-gate-derivation.md §2, mkIllumosComponent + elfedit).
#
# This is the foundation the package-batch work depends on: it lets a package be
# built with GCC-14 OR Clang-21 against the sliced libc + Solaris ld, so the
# registry can be built with "at least GCC and Clang, latest versions" (backlog
# PS-1 clang / PS-4 latest-GCC/GDB, pulled forward). See docs/design-toolchains.md.
#
# WHY slice, not build-from-source: OI already ships gcc-14 (14.3.0) and clang-21
# (21.1.8) as IPS packages, both already targeting x86_64-pc-solaris2.11 and both
# proven to compile the illumos world. Building either from source is a huge,
# redundant effort — the lazy CORRECT path is to re-express the OI binaries as
# relocatable store toolchains, exactly like we sliced libc/ld/rtld from the gate
# proto. A newer-than-OI compiler (or a differently-configured one) is a
# from-source follow-on, noted in docs/design-toolchains.md.
#
# HOST PROVENANCE (sandbox=false, Phase-1 host-impure stance, design §1.3):
#   gcc-14   IPS developer/gcc-14 @ 14.3.0-2026.0.0.2  -> /usr/gcc/14
#   clang-21 IPS developer/clang-21 @ 21.1.8-2025.0.0.0 -> /usr/clang/21
#   gdb      IPS developer/debug/gdb @ 16.3-2025.0.0.0  -> /usr/bin/gdb
# Third-party runtime libs (libz/libzstd/libedit/...) sliced from /usr/lib/64.
# TODO(P2): pin these to gate/IPS versions or build from source, like externalLibs.

{ mkIllumosComponent  # from ./mk-illumos-component.nix (already bound to the gate)
, libc                # the illumos.libc slice (supplies libc.so.1 + siblings)
}:

let
  # libc slice lib dirs, baked as cross-component RUNPATH entries. Both ABIs, so
  # a 64-bit toolchain binary resolves libc.so.1 from lib/amd64 and any stray
  # 32-bit helper from lib (the loader picks the matching class). Same idiom as
  # default.nix's libcLibDirs.
  libcLibDirs = [ "${libc}/lib/amd64" "${libc}/lib" ];
in
rec {
  # ---------------------------------------------------------------------------
  # gcc14 — GCC 14.3.0, sliced from /usr/gcc/14. Relocatable store toolchain:
  # the driver + cc1/cc1plus + gcc runtime + full C/C++ headers + gcc internal
  # headers + crt objects, all under $out/usr/gcc/14. RUNPATH points at its own
  # lib dirs ($out/usr/gcc/14/lib{,/amd64}) + the libc slice; cc1 also NEEDs
  # libz/libzstd which are NOT under /usr/gcc/14, so we bundle them beside the
  # gcc runtime via extraFiles (design's externalLibs idiom).
  #
  # The driver invokes the HOST assembler (/usr/bin/gas) and Solaris ld
  # (/usr/bin/ld) at compile/link time — those stay host tools for Phase-1
  # (native-on-illumos, host-impure). To drive the STORE Solaris ld instead, a
  # cc-wrapper passes -B <ld-slice>/usr/bin (see docs/design-toolchains.md §wire).
  gcc14 = mkIllumosComponent {
    name = "gcc14";
    srcRoot = "/";                 # slice from the host, not the gate proto
    files = [ "usr/gcc/14" ];      # whole gcc-14 prefix (bin, lib, libexec, include)
    extraFiles = [
      # cc1/cc1plus NEED these beyond libc; drop them beside the 64-bit gcc
      # runtime so $ORIGIN + the lib/amd64 selfLibDir resolves them.
      { src = "/usr/lib/64/libz.so.1";    dst = "usr/gcc/14/lib/amd64/libz.so.1"; }
      { src = "/usr/lib/64/libzstd.so.1"; dst = "usr/gcc/14/lib/amd64/libzstd.so.1"; }
    ];
    # $ORIGIN can't bridge bin -> lib/amd64 (different depth) reliably for all the
    # gcc binaries, so bake both gcc lib dirs as $out-absolute RUNPATH entries.
    selfLibDirs = [ "usr/gcc/14/lib/amd64" "usr/gcc/14/lib" ];
    # 32-bit gcc runtime + the 64-bit one are both under selfLibDirs above; drop
    # the amd64 $ORIGIN parts (default assumes a lib/amd64 sibling layout, which
    # gcc's bin/ + lib/ tree does not have).
    originParts = [ "$ORIGIN" ];
    depRunpaths = libcLibDirs;     # libc.so.1 + siblings from the libc slice
  };

  # ---------------------------------------------------------------------------
  # clang — Clang/LLVM 21.1.8, sliced from /usr/clang/21. Same idea: the clang
  # driver + all clang/llvm tools + libLLVM/libclang-cpp + clang's own resource
  # headers, under $out/usr/clang/21. clang NEEDs the gcc-14 C++/unwind runtime
  # (libstdc++/libgcc_s) plus a set of third-party libs (libedit/libz/libzstd/
  # libxml2.so.2/libncurses.so.5/libicu*) that live in /usr/lib/64, none of which
  # are under /usr/clang/21 — bundle all of them into $out/lib-extra and bake
  # that dir into the RUNPATH so clang is self-contained (no host /usr/lib leak).
  #
  # clang targets x86_64-pc-solaris2.11 by default (verified: clang -dumpmachine).
  # It drives the HOST Solaris ld for linking (illumos "shadow compiler" promoted
  # to primary here). C++ uses libstdc++ (gcc-14's), NOT libc++ — OI's clang is
  # configured against the gcc-14 libstdc++, so C++ hellos link libstdc++.so.6.
  clang = mkIllumosComponent {
    name = "clang";
    srcRoot = "/";
    files = [ "usr/clang/21" ];    # whole clang-21 prefix (bin, lib, resource dirs)
    extraFiles = [
      # gcc-14 C++/unwind runtime clang links against (OI clang uses libstdc++).
      { src = "/usr/gcc/14/lib/amd64/libstdc++.so.6"; dst = "lib-extra/libstdc++.so.6"; }
      { src = "/usr/gcc/14/lib/amd64/libgcc_s.so.1";  dst = "lib-extra/libgcc_s.so.1"; }
      # third-party deps of clang/libLLVM/libclang-cpp (from /usr/lib/64).
      { src = "/usr/lib/64/libedit.so.0";      dst = "lib-extra/libedit.so.0"; }
      { src = "/usr/lib/64/libncurses.so.5";   dst = "lib-extra/libncurses.so.5"; }
      { src = "/usr/lib/64/libz.so.1";         dst = "lib-extra/libz.so.1"; }
      { src = "/usr/lib/64/libzstd.so.1";      dst = "lib-extra/libzstd.so.1"; }
      { src = "/usr/lib/64/libxml2.so.2";      dst = "lib-extra/libxml2.so.2"; }
      { src = "/usr/lib/64/libicuuc.so.78";    dst = "lib-extra/libicuuc.so.78"; }
      { src = "/usr/lib/64/libicudata.so.78";  dst = "lib-extra/libicudata.so.78"; }
    ];
    # libLLVM/libclang-cpp sit in usr/clang/21/lib; the bundled 3rd-party libs in
    # lib-extra. Neither is reachable from usr/clang/21/bin via one $ORIGIN rule,
    # so bake both as $out-absolute RUNPATH entries.
    selfLibDirs = [ "usr/clang/21/lib" "lib-extra" ];
    originParts = [ "$ORIGIN" ];
    depRunpaths = libcLibDirs;
  };

  # ---------------------------------------------------------------------------
  # gdb — GNU GDB 16.3, sliced from /usr/bin/gdb. Big NEEDED closure (python3.9,
  # glib, babeltrace, mpfr/gmp, the dladm/nvpair/scf chain, ...) — all bundled
  # into $out/lib-extra so gdb resolves everything from the store. gcc-14 runtime
  # (libstdc++/libgcc_s) + libc slice as usual. Debugger, not on the compile path.
  gdb = mkIllumosComponent {
    name = "gdb";
    srcRoot = "/";
    files = [ "usr/bin/gdb" "usr/bin/gdb-add-index" "usr/bin/gdbtui" ];
    extraFiles = [
      { src = "/usr/gcc/14/lib/amd64/libstdc++.so.6"; dst = "lib-extra/libstdc++.so.6"; }
      { src = "/usr/gcc/14/lib/amd64/libgcc_s.so.1";  dst = "lib-extra/libgcc_s.so.1"; }
      # gdb's non-libc-slice NEEDED closure (from /usr/lib/64 + /lib/64).
      { src = "/usr/lib/64/libbabeltrace.so.1";      dst = "lib-extra/libbabeltrace.so.1"; }
      { src = "/usr/lib/64/libbabeltrace-ctf.so.1";  dst = "lib-extra/libbabeltrace-ctf.so.1"; }
      { src = "/usr/lib/64/libexpat.so.1";           dst = "lib-extra/libexpat.so.1"; }
      { src = "/usr/lib/64/libglib-2.0.so.0";        dst = "lib-extra/libglib-2.0.so.0"; }
      { src = "/usr/lib/64/libgmp.so.10";            dst = "lib-extra/libgmp.so.10"; }
      { src = "/usr/lib/64/libmpfr.so.6";            dst = "lib-extra/libmpfr.so.6"; }
      { src = "/usr/lib/64/liblzma.so.5";            dst = "lib-extra/liblzma.so.5"; }
      { src = "/usr/lib/64/libncurses.so.5";         dst = "lib-extra/libncurses.so.5"; }
      { src = "/usr/lib/64/libpcre2-8.so.0";         dst = "lib-extra/libpcre2-8.so.0"; }
      { src = "/usr/lib/64/libpython3.9.so.1.0";     dst = "lib-extra/libpython3.9.so.1.0"; }
      { src = "/usr/lib/64/libxml2.so.16";           dst = "lib-extra/libxml2.so.16"; }
      { src = "/usr/lib/64/libicuuc.so.78";           dst = "lib-extra/libicuuc.so.78"; }
      { src = "/usr/lib/64/libicudata.so.78";         dst = "lib-extra/libicudata.so.78"; }
      { src = "/usr/lib/64/libxxhash.so.0";          dst = "lib-extra/libxxhash.so.0"; }
      { src = "/usr/lib/64/libz.so.1";               dst = "lib-extra/libz.so.1"; }
      { src = "/usr/lib/64/libzstd.so.1";            dst = "lib-extra/libzstd.so.1"; }
      { src = "/usr/lib/64/libidmap.so.1";           dst = "lib-extra/libidmap.so.1"; }
      { src = "/usr/lib/64/libidspace.so.1";         dst = "lib-extra/libidspace.so.1"; }
      { src = "/usr/lib/64/libexacct.so.1";          dst = "lib-extra/libexacct.so.1"; }
      { src = "/usr/lib/64/libpool.so.1";            dst = "lib-extra/libpool.so.1"; }
      { src = "/usr/lib/64/librename.so.1";          dst = "lib-extra/librename.so.1"; }
      { src = "/usr/lib/64/libsmbios.so.1";          dst = "lib-extra/libsmbios.so.1"; }
      { src = "/lib/64/libavl.so.1";                 dst = "lib-extra/libavl.so.1"; }
      { src = "/lib/64/libdevinfo.so.1";             dst = "lib-extra/libdevinfo.so.1"; }
      { src = "/lib/64/libdladm.so.1";               dst = "lib-extra/libdladm.so.1"; }
      { src = "/lib/64/libdlpi.so.1";                dst = "lib-extra/libdlpi.so.1"; }
      { src = "/lib/64/libgen.so.1";                 dst = "lib-extra/libgen.so.1"; }
      { src = "/lib/64/libinetutil.so.1";            dst = "lib-extra/libinetutil.so.1"; }
      { src = "/lib/64/libintl.so.1";                dst = "lib-extra/libintl.so.1"; }
      { src = "/lib/64/libkstat.so.1";               dst = "lib-extra/libkstat.so.1"; }
      { src = "/lib/64/libnvpair.so.1";              dst = "lib-extra/libnvpair.so.1"; }
      { src = "/lib/64/librcm.so.1";                 dst = "lib-extra/librcm.so.1"; }
      { src = "/lib/64/libscf.so.1";                 dst = "lib-extra/libscf.so.1"; }
      { src = "/lib/64/libsec.so.1";                 dst = "lib-extra/libsec.so.1"; }
      { src = "/lib/64/libsendfile.so.1";            dst = "lib-extra/libsendfile.so.1"; }
      { src = "/lib/64/libumem.so.1";                dst = "lib-extra/libumem.so.1"; }
      { src = "/lib/64/libuuid.so.1";                dst = "lib-extra/libuuid.so.1"; }
      { src = "/lib/64/libuutil.so.1";               dst = "lib-extra/libuutil.so.1"; }
      { src = "/lib/64/libvarpd.so.1";               dst = "lib-extra/libvarpd.so.1"; }
    ];
    selfLibDirs = [ "lib-extra" ];
    originParts = [ "$ORIGIN" ];
    depRunpaths = libcLibDirs;
  };
}
