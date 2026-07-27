# solnix sparc illumos world — standalone Nix expression for the illumos build
# host. MIRRORS pkgs/illumos/aarch64/default.nix (the aarch64 world slices),
# which mirrors pkgs/illumos/default.nix (x86_64). Build on an illumos host with
# Nix 2.3.16 (currentSystem x86_64-solaris; the slices are BIG-ENDIAN SPARC V9
# ELF but the slicing/relocation runs on the amd64 host — cross, per design §3.5,
# same as aarch64):
#   nix-build pkgs/illumos/sparc/default.nix -A gate
#   nix-build pkgs/illumos/sparc/default.nix -A libc
#   nix-build pkgs/illumos/sparc/default.nix -A rtld
#   nix-build pkgs/illumos/sparc/default.nix -A ld
#   nix-build pkgs/illumos/sparc/default.nix -A sys
#   nix-build pkgs/illumos/sparc/default.nix -A systemPath
#
# KEY DIFFERENCES FROM aarch64 (docs/design-sparc-riscv-qemu.md S2):
#   - SPARC keeps the classic ISA split like x86 (NOT LP64-flat like aarch64):
#     the 64-bit SPARC V9 libs/objects live under the sparcv9/ subdir
#     (lib/sparcv9, usr/lib/sparcv9), the SPARC analog of x86's amd64/. The
#     sparcv9-solaris TARGET is 64-bit (cpu=sparc64), so every slice references
#     the sparcv9/ objects and $ORIGIN parts reach lib/sparcv9.
#   - BIG-ENDIAN: the ELF is ELF64 MSB SPARC V9 (EM_SPARCV9). The host
#     elfdump/elfedit relocate RUNPATH cross-arch regardless of endianness
#     (mechanism edits the DT_RUNPATH string offset), exactly as for aarch64.
#   - kernel: platform/sun4u/kernel/sparcv9/{unix,genunix} (Ultra 45 = sun4u),
#     NOT platform/i86pc/.../amd64/unix or platform/armv8/.../aarch64/unix.
#   - libm soname is libm.so.2 (sparc, like x86_64) — not aarch64's libm.so.0.
#   - CRT OBJECTS ABSENT: the source is the Tribblix m34 boot_archive (a runtime
#     ramdisk), which ships NO compile-time crt*.o/values-*.o. So the libc slice
#     omits them (unlike x86/aarch64 which sliced them from a full gate proto).
#     CEILING: crt objects deferred — add them when a full sparc gate proto
#     (native Ultra 45 Hipster build) is reachable; needed for a working cc, not
#     for the runtime world slices below.

let
  gate = import ./gate.nix { };

  mkIllumosComponent = args: import ../mk-illumos-component.nix ({ gate = gate; } // args);

  # sparcv9 libc lib dir (the 64-bit ISA subdir). Baked as a cross-component
  # RUNPATH entry for consumers (rtld/ld).
  libcLibDirs = [ "${libc}/lib/sparcv9" ];

  # GATE B: libc slice — 64-bit SPARC V9. All siblings live in this component in
  # lib/sparcv9/, so intra-component resolution is $ORIGIN. Headers in
  # usr/include (partial — the boot_archive header set). No crt objects (see the
  # header note): the runtime ramdisk has none.
  libc = mkIllumosComponent {
    name = "libc";
    originParts = [ "$ORIGIN" ]; # siblings share lib/sparcv9; $ORIGIN covers them.
    files = [
      # --- runtime libc + historically-split siblings (all in lib/sparcv9/) ---
      "lib/sparcv9/libc.so.1"
      "lib/sparcv9/libm.so.2"
      "lib/sparcv9/libsocket.so.1"
      "lib/sparcv9/libnsl.so.1"
      "lib/sparcv9/libresolv.so.2"
      "lib/sparcv9/libelf.so.1"
      "lib/sparcv9/libpthread.so.1"
      "lib/sparcv9/librt.so.1"
      "lib/sparcv9/libdl.so.1"
      "lib/sparcv9/libmd.so.1"
      # libc-adjacent siblings the coreutils/SMF pull
      "lib/sparcv9/libmp.so.2"
      "lib/sparcv9/libcustr.so.1"
      "lib/sparcv9/libofmt.so.1"
      "lib/sparcv9/libumem.so.1"
      # link-editor .so -> .so.N symlinks (in lib/sparcv9 + usr/lib/sparcv9)
      "lib/sparcv9/libc.so"
      "lib/sparcv9/libm.so"
      "lib/sparcv9/libsocket.so"
      "lib/sparcv9/libnsl.so"
      "lib/sparcv9/libresolv.so"
      "lib/sparcv9/libelf.so"
      "usr/lib/sparcv9/libc.so"
      "usr/lib/sparcv9/libm.so"
      "usr/lib/sparcv9/libsocket.so"
      "usr/lib/sparcv9/libnsl.so"
      "usr/lib/sparcv9/libresolv.so"
      "usr/lib/sparcv9/libelf.so"
      # partial system header tree (boot_archive header set; full headers come
      # from a native Ultra 45 gate build — S3+)
      "usr/include"
    ];
  };

  # rtld — ld.so.1 (the .interp target) + the libs it NEEDs (librtld/libld/
  # liblddbg in lib/sparcv9). Its NEEDED libld/liblddbg also NEED libc/libelf ->
  # libc slice cross-dep. Siblings share lib/sparcv9, so $ORIGIN covers them.
  rtld = mkIllumosComponent {
    name = "rtld";
    originParts = [ "$ORIGIN" ];
    files = [
      "lib/sparcv9/ld.so.1"          # sparcv9 runtime linker (.interp target)
      "lib/sparcv9/librtld.so.1"     # NEEDED by ld.so.1
      "lib/sparcv9/libld.so.4"       # NEEDED by ld.so.1
      "lib/sparcv9/liblddbg.so.4"    # NEEDED by libld/ld.so.1
    ];
    depRunpaths = libcLibDirs; # librtld/libld -> libc/libelf from the libc slice
  };

  # ld — the Solaris link-editor. usr/bin/ld + the support libs it (and libld)
  # NEED: libld/liblddbg/libumem in lib/sparcv9, libldstab (mapfile stabbing) in
  # usr/lib/sparcv9. libelf + libc from the libc slice (cross-component RUNPATH).
  # usr/bin/ld reaches lib/sparcv9 via $ORIGIN/../../lib/sparcv9; libldstab in
  # usr/lib/sparcv9 via $out (selfLibDirs).
  ld = mkIllumosComponent {
    name = "ld";
    originParts = [ "$ORIGIN" "$ORIGIN/../../lib/sparcv9" ];
    files = [
      "usr/bin/ld"
      "lib/sparcv9/libld.so.4"
      "lib/sparcv9/liblddbg.so.4"
      "lib/sparcv9/libumem.so.1"
      "usr/lib/sparcv9/libldstab.so.1"
    ];
    selfLibDirs = [ "usr/lib/sparcv9" ]; # libldstab not reachable via $ORIGIN
    depRunpaths = libcLibDirs;           # libelf + libc from the libc slice
  };

  # sys — the kernel. sun4u platform unix + sparcv9 genunix + the sun4u kernel
  # module tree. Kernel objects are NOT userland ELF (no SONAME/NEEDED/RUNPATH),
  # so the relocation loop skips them and CTF survives cp -a verbatim.
  # unix is at platform/sun4u/kernel/sparcv9/unix (the Ultra 45 = sun4u class);
  # genunix at platform/sun4u/kernel/sparcv9/genunix.
  sys = mkIllumosComponent {
    name = "sys";
    originParts = [ "$ORIGIN" ]; # cosmetic: kernel ELF has no RUNPATH so the
                                 # relocation loop skips every object anyway.
    files = [
      "platform/sun4u/kernel" # unix + platform kernel modules (sun4u = Ultra 45)
      "kernel"                # shared kernel module tree
    ];
    # deps=[] : the kernel does not link userland libc. Nothing to relocate.
  };

  # systemPath — compose the world into one symlink-farm tree (design §4.2).
  # Plain derivation (no nixpkgs buildEnv) that symlink-merges the component
  # store paths with the runtime /usr,/lib,/sbin,/kernel,/platform layout.
  # sparc sanity paths (sun4u unix + sparcv9 genunix + sparcv9 libc).
  systemPath = derivation {
    name = "system-path";
    system = builtins.currentSystem;
    builder = "/usr/bin/bash";
    PATH = "/usr/gnu/bin:/usr/bin:/usr/sbin";
    paths = [ sys rtld libc ld ];
    args = [ "-c" ''
      set -eu
      mkdir -p "$out"
      for p in $paths; do
        (cd "$p" && find . -type d) | while read -r d; do mkdir -p "$out/$d"; done
        (cd "$p" && find . \( -type f -o -type l \)) | while read -r f; do
          rel="''${f#./}"
          ln -sf "$p/$rel" "$out/$rel"
        done
      done
      [ -e "$out/lib/sparcv9/libc.so.1" ]                        || { echo "FATAL: no sparcv9 libc in systemPath" >&2; exit 1; }
      [ -e "$out/lib/sparcv9/ld.so.1" ]                          || { echo "FATAL: no sparcv9 rtld in systemPath" >&2; exit 1; }
      [ -e "$out/usr/bin/ld" ]                                   || { echo "FATAL: no ld in systemPath" >&2; exit 1; }
      [ -e "$out/platform/sun4u/kernel/sparcv9/unix" ]           || { echo "FATAL: no sun4u unix in systemPath" >&2; exit 1; }
      [ -e "$out/platform/sun4u/kernel/sparcv9/genunix" ]        || { echo "FATAL: no sun4u genunix in systemPath" >&2; exit 1; }
    '' ];
  };
in
{
  inherit gate libc rtld ld sys systemPath;
}
