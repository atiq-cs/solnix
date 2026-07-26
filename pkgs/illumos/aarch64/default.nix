# solnix aarch64 illumos world — standalone Nix expression for the illumos build
# host. MIRRORS pkgs/illumos/default.nix (the x86_64 world slices) for the
# richlowe/arm64-gate aarch64 proto (A3). Build on an illumos host with Nix
# 2.3.16 (currentSystem x86_64-solaris; the slices are aarch64 ELF but the
# slicing/relocation runs on the amd64 host — cross, per design §3.5):
#   nix-build pkgs/illumos/aarch64/default.nix -A gate
#   nix-build pkgs/illumos/aarch64/default.nix -A libc
#   nix-build pkgs/illumos/aarch64/default.nix -A rtld
#   nix-build pkgs/illumos/aarch64/default.nix -A ld
#   nix-build pkgs/illumos/aarch64/default.nix -A sys
#   nix-build pkgs/illumos/aarch64/default.nix -A systemPath
#
# KEY DIFFERENCES FROM x86_64 (docs/design-aarch64-bootstrap.md §3):
#   - proto = proto/root_aarch64 (LP64-only, NO amd64/ ISA subdir). Libs and crt
#     live directly in lib/ and usr/lib/; `lib/64 -> .` + `usr/lib/64 -> .`
#     compat symlinks. So $ORIGIN parts collapse to just [ "$ORIGIN" ] and lib
#     dirs are lib/ + usr/lib/ (no lib/amd64).
#   - kernel: platform/armv8/kernel/aarch64/unix + kernel/aarch64/genunix
#     (NOT platform/i86pc/.../amd64/unix).
#   - libm soname is libm.so.0 (aarch64), not libm.so.1/.2.
#   - elfedit/elfdump are aarch64-native in the proto (only RUN on aarch64), so
#     the RELOCATION still uses the HOST (amd64) /usr/bin/elfedit — same as
#     x86_64: the mechanism is arch-independent, the host tool edits the aarch64
#     ELF's DT_RUNPATH string in place. (mk-illumos-component default elfedit.)

let
  gate = import ./gate.nix { };

  mkIllumosComponent = args: import ../mk-illumos-component.nix ({ gate = gate; } // args);

  # aarch64 libc lib dir (single ABI, no amd64). Baked as a cross-component
  # RUNPATH entry for consumers (rtld/ld). lib/64 -> . so "${libc}/lib" covers 64.
  libcLibDirs = [ "${libc}/lib" ];

  # GATE B: libc slice — LP64 only. All siblings live inside this component in
  # lib/, so intra-component resolution is $ORIGIN. crt + values + headers in
  # usr/lib + usr/include. No amd64 subdir anywhere.
  libc = mkIllumosComponent {
    name = "libc";
    originParts = [ "$ORIGIN" ]; # LP64-only; no lib/amd64 to reach.
    files = [
      # --- runtime libc + historically-split siblings (all in lib/) ---
      "lib/libc.so.1"
      "lib/libm.so.0"
      "lib/libsocket.so.1"
      "lib/libnsl.so.1"
      "lib/libresolv.so.2"
      "lib/libelf.so.1"
      "lib/libpthread.so.1"
      "lib/librt.so.1"
      "lib/libdl.so.1"
      "lib/libmd.so.1"
      # libc-adjacent siblings the coreutils/SMF pull
      "lib/libmp.so.2"
      "lib/libcustr.so.1"
      "lib/libofmt.so.1"
      "lib/libumem.so.1"
      # --- crt + values startup objects (usr/lib, no amd64) ---
      "usr/lib/crt1.o"
      "usr/lib/crti.o"
      "usr/lib/crtn.o"
      "usr/lib/values-Xa.o"
      "usr/lib/values-Xc.o"
      "usr/lib/values-Xs.o"
      "usr/lib/values-Xt.o"
      "usr/lib/values-xpg4.o"
      "usr/lib/values-xpg6.o"
      # link-editor .so -> .so.N symlinks
      "usr/lib/libc.so"
      "usr/lib/libm.so"
      "usr/lib/libsocket.so"
      "usr/lib/libnsl.so"
      "usr/lib/libresolv.so"
      "usr/lib/libelf.so"
      "lib/libc.so"
      "lib/libm.so"
      "lib/libsocket.so"
      "lib/libnsl.so"
      "lib/libresolv.so"
      "lib/libelf.so"
      # full system header tree
      "usr/include"
    ];
  };

  # rtld — ld.so.1 (the .interp target) + the libs it NEEDs (librtld/libld/
  # liblddbg in lib/). Its NEEDED libld/liblddbg also NEED libc/libelf -> libc
  # slice cross-dep. Single ABI, so $ORIGIN covers its siblings in lib/.
  rtld = mkIllumosComponent {
    name = "rtld";
    originParts = [ "$ORIGIN" ];
    files = [
      "lib/ld.so.1"          # aarch64 runtime linker (.interp target)
      "lib/librtld.so.1"     # NEEDED by ld.so.1
      "lib/libld.so.4"       # NEEDED by ld.so.1
      "lib/liblddbg.so.4"    # NEEDED by libld/ld.so.1
    ];
    depRunpaths = libcLibDirs; # librtld/libld -> libc/libelf from the libc slice
  };

  # ld — the Solaris link-editor. usr/bin/ld + the support libs it (and libld)
  # NEED: libld/liblddbg/libumem in lib/, libldstab (mapfile stabbing) in
  # usr/lib/. libelf + libc from the libc slice (cross-component RUNPATH).
  # usr/bin/ld reaches lib/ via $ORIGIN/../../lib; libldstab in usr/lib via
  # $out/usr/lib (selfLibDirs).
  ld = mkIllumosComponent {
    name = "ld";
    originParts = [ "$ORIGIN" "$ORIGIN/../../lib" ];
    files = [
      "usr/bin/ld"
      "lib/libld.so.4"
      "lib/liblddbg.so.4"
      "lib/libumem.so.1"
      "usr/lib/libldstab.so.1"
    ];
    selfLibDirs = [ "usr/lib" ]; # libldstab not reachable via $ORIGIN
    depRunpaths = libcLibDirs;   # libelf + libc from the libc slice
  };

  # sys — the kernel. armv8 platform unix + aarch64 genunix + the aarch64 kernel
  # module tree. Kernel objects are NOT userland ELF (no SONAME/NEEDED/RUNPATH),
  # so the relocation loop skips them and CTF survives cp -a verbatim.
  # unix IS at platform/armv8/kernel/aarch64/unix (confirmed in the restored
  # proto); genunix at kernel/aarch64/genunix.
  sys = mkIllumosComponent {
    name = "sys";
    originParts = [ "$ORIGIN" ]; # cosmetic: kernel ELF has no RUNPATH so the
                                 # relocation loop skips every object anyway.
    files = [
      "platform/armv8/kernel"   # unix + platform kernel modules
      "kernel"                  # genunix + shared kernel module tree
    ];
    # deps=[] : the kernel does not link userland libc. Nothing to relocate.
  };

  # systemPath — compose the world into one symlink-farm tree (design §4.2).
  # Plain derivation (no nixpkgs buildEnv) that symlink-merges the component
  # store paths with the runtime /usr,/lib,/sbin,/kernel,/platform layout.
  # aarch64 sanity paths (armv8 unix + aarch64 genunix, no amd64).
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
      [ -e "$out/lib/libc.so.1" ]                          || { echo "FATAL: no libc in systemPath" >&2; exit 1; }
      [ -e "$out/lib/ld.so.1" ]                            || { echo "FATAL: no rtld in systemPath" >&2; exit 1; }
      [ -e "$out/usr/bin/ld" ]                             || { echo "FATAL: no ld in systemPath" >&2; exit 1; }
      [ -e "$out/platform/armv8/kernel/aarch64/unix" ]     || { echo "FATAL: no unix in systemPath" >&2; exit 1; }
      [ -e "$out/kernel/aarch64/genunix" ]                 || { echo "FATAL: no genunix in systemPath" >&2; exit 1; }
    '' ];
  };
in
{
  inherit gate libc rtld ld sys systemPath;
}
