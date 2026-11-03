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

# gate: an already-built aarch64 proto store path (pass it; the default ingests the build
# host's proto dir). system: aarch64-solaris when built ON aarch64 (aa64nix, native);
# the old cross default (the x86 host's currentSystem) is kept for the slices-on-x86 path.
# stage: "final" = every recipe store-only (a64h; ./tools.nix: store PATH + path gate), its tools from the "seed" instance, which is
# this same set built the stage0 way (/usr/gnu, /opt/ooce, /opt/nixboot). NixOS's stdenv bootstrap in two stages; the seed's outs
# are the served aarch64 rows. gate/libc/ld/rtld/sys/gcc are shared bootstrap tools (one drv in both stages).
{ gate ? null, protoDir ? null, system ? builtins.currentSystem, stage ? "final" }:
let
  gate' = if gate != null then gate
          else import ./gate.nix ({ inherit system; } // (if protoDir == null then { } else { inherit protoDir; }));

  mkIllumosComponent = args: import ../mk-illumos-component.nix ({ gate = gate'; inherit system; } // args);

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
  # gcc FROM SOURCE on aarch64 (./gcc-src.nix): gcc.lib is the C++/unwind runtime.
  gcc = import ./gcc-src.nix { gate = gate'; libcSlice = libc; inherit ld system; };

  # nix 2.24.15 and its chain, from source with that gcc (./src.nix).
  seed = import ./. { gate = gate'; inherit system; stage = "seed"; };
  # the perl build tool is this set's own store-only perl (homePkgs.perl), not the seed's: the seed perl reads the stage0 PATH, where
  # dixa's devroot /usr/bin/perl is, and perl 5.42.2's recipe rejects a host perl5 (FATAL on dixa). tools.nix keeps perl off the tool
  # PATH of perl's own build closure (perl, gnupatch, zlib), so there is no cycle.
  a64 = if stage == "seed" then null else import ./tools.nix { gate = gate'; libcSlice = libc; inherit ld gcc seed system;
    perl = homePkgs.perl; } // {
    # per recipe: the build tools stage0 found in /usr/bin or /opt (dixa4 build logs: devroot bison, flex, autoconf-archive).
    perPkg = args: {
      boost = { nativeTools = [ final.bzip2-bin ]; };   # .tar.bz2
      tmux = { nativeTools = [ final.bison ]; };         # configure requires a yacc
      gdbm = { nativeTools = [ final.bison homePkgs.flex ]; };
      nix = { nativeTools = [ homePkgs.flex final.bison homePkgs.autoconf homePkgs.automake homePkgs.libtool ];
              aclocalDirs = map (p: "${p}/share/aclocal") [ final.autoconf-archive homePkgs.pkgconf homePkgs.libtool ]; };
      # configure bakes the absolute path of pr / m4 it found on PATH (the build-tools farm) into the ELF: name the store tool itself,
      # as nixpkgs does (diffutils PR_PROGRAM=coreutils/bin/pr; bison/flex run m4), so the reference is that tool, not the whole farm.
      diffutils = { build = "export PR_PROGRAM=${homePkgs.coreutils}/bin/pr\n" + args.build; };
      flex = { build = "export M4=${homePkgs.gnum4}/bin/m4\n" + args.build; };
      bison = { build = "export M4=${homePkgs.gnum4}/bin/m4\n" + args.build; };
      # xz's configure.ac forces POSIX_SHELL=/usr/xpg4/bin/sh on solaris* (for old Solaris' Bourne /bin/sh); on illumos /bin/sh is the
      # same ksh93 (both are links to it), and gate2 B9 rejects a /usr/xpg4 #! in the shipped xzgrep/xzdiff/xzless/xzmore.
      xz = { build = "export gl_cv_posix_shell=/bin/sh\n" + args.build + "\nhead -1 $out/bin/xzgrep | grep -qx '#!/bin/sh' || { echo 'FATAL: xzgrep #! is not /bin/sh' >&2; exit 1; }\n"; };
      # libgpg-error's configure.ac sets INSTALLSHELLPATH=/usr/xpg4/bin/sh for solaris* (no cache variable): gpgrt-config's #! (B9).
      libgpg-error = { build = args.build + "\nsed -i '1s|^#!/usr/xpg4/bin/sh$|#!/bin/sh|' $out/bin/gpgrt-config\n"
        + "head -1 $out/bin/gpgrt-config | grep -qx '#!/bin/sh' || { echo 'FATAL: gpgrt-config #! is not /bin/sh' >&2; exit 1; }\n"; };
      # git ships templates/hooks/fsmonitor-watchman.sample with a literal #!/usr/bin/perl (its Makefile rewrites only #!.../sh and @PERL_PATH@).
      # A sample hook, run only if a user enables it: /usr/bin/env perl (B9 allows env), so this NO_PERL git stays perl-free (nixpkgs: patchShebangs).
      git = { build = args.build + "\nf=$out/share/git-core/templates/hooks/fsmonitor-watchman.sample; chmod u+w $f\n"
        + "sed -i '1s|^#!/usr/bin/perl$|#!/usr/bin/env perl|' $f; head -1 $f | grep -qx '#!/usr/bin/env perl' || { echo 'FATAL: watchman sample #!' >&2; exit 1; }\n"; };
      # quilt runs awk at run time from --with-awk=${world}/usr/bin/nawk (x86: the whole userland); aarch64's world is gate libs only.
      quilt = { build = builtins.replaceStrings [ "${homePkgs.world}/usr/bin/nawk" ] [ "${a64.illumosTools}/bin/nawk" ] args.build; };
      # dixa's nix.conf has cores = 0 (all cores), so NIX_BUILD_CORES=0 and `gmake -j0` fails ("-j requires a positive integer"):
      # a fixed -j, as lp64Fix gives the other recipes (the job count does not reach the output). And mk-src-pkg deletes the .la FILES, which leaves libpng's lib/libpng.la -> libpng16.la link dangling (gate2 B6): drop it too.
      libpng = { build = let b = builtins.replaceStrings [ "-j\${NIX_BUILD_CORES:-8}" ] [ "-j24" ] args.build; in
        if b == args.build then throw "a64r libpng: -j anchor" else b + "\nrm -f \"$out/lib/libpng.la\"\n"; };
      # tzselect's #! is the Makefile's KSHELL (/bin/bash), which gate2 B9 rejects: /bin/sh, illumos' ksh93 (tzselect wants a POSIX
      # shell with ksh's select). NixOS patchShebangs it to the store bash instead; /bin/sh keeps tzdata reference-free.
      tzdata = { build = let b = builtins.replaceStrings [ "gmake -j8 CC=" ] [ "gmake -j8 KSHELL=/bin/sh CC=" ] args.build; in
        if b == args.build then throw "a64r tzdata: gmake anchor" else b + "\nhead -1 $out/bin/tzselect | grep -qx '#!/bin/sh' || { echo 'FATAL: tzselect #! is not /bin/sh' >&2; exit 1; }\n"; };
      # python3: imports during install and the in-build checks write timestamp-mode pyc (gate2 B10; --check differed on dixa). Ship
      # none, as the served x86 python3 (0 pyc; wave6's 3.13.18 recipe also rm's them first), and write none while checking.
      # _sysconfigdata named $W (abs_builddir, RUNSHARED: 7 hits on dixa): /no-such-path, as nixpkgs and wave6.
      python3 = { build = let a = ''      ln -sf python3 "$out/bin/python"''; b = builtins.replaceStrings [ a ]
          [ (''      find "$out" -type d -name __pycache__ -prune -exec rm -r {} +; export PYTHONDONTWRITEBYTECODE=1'' + "\n"
            # nixpkgs postInstall (and wave6's x86 3.13.18): the recorded build configuration must not name the build dir
            + ''      for f in "$out"/lib/python3.13/_sysconfigdata*.py "$out"/lib/python3.13/config-3.13*/Makefile; do chmod u+w "$f"; LC_ALL=C sed -i -e "s|$W|/no-such-path|g" "$f"; done''
            # check these two only: in the shipped (stripped) out they are the only files naming $W (measured, nav3ra6x); before
            # mk-src-pkg's strip, which runs after this, other files under lib/python3.13 still do (the first v4 build FAILed here).
            + "\n" + ''      ! grep -lF "$W" "$out"/lib/python3.13/_sysconfigdata*.py "$out"/lib/python3.13/config-3.13*/Makefile || { echo "FATAL: python3 sysconfig still names the build dir" >&2; exit 1; }'' + "\n" + a) ] args.build; in
        if b == args.build then throw "a64r python3: anchor" else b
          + "\n[ -z \"$(find $out -name '*.pyc' | head -1)\" ] || { echo 'FATAL: python3 ships pyc' >&2; exit 1; }\n"; };
      # texinfo: the served x86 texinfo has no perl XS (0 .so; its configure found it unbuildable there). On aarch64 configure builds XS
      # with perl's ccflags, which miss the arm64-gate flags (TLSDESC relocs, dixa), and with no store RUNPATH (the closure gate saw
      # /lib/libc.so.1). --disable-perl-xs: the pure-perl texi2any, as x86 ships.
      texinfo = { build = let b = builtins.replaceStrings [ "./configure --prefix=\"$out\" --disable-nls" ]   # perPkg sees the recipe text (pre-lp64Fix)
          [ "./configure --prefix=\"$out\" --disable-nls --disable-perl-xs" ] args.build; in
        if b == args.build then throw "a64r texinfo: configure anchor" else b; };
      # lsof's dproc.c defines ARCH64B (the isalist word of a 64-bit kernel) for sparc and x86 only: aarch64's isalist says aarch64.
      # and it links the proto's libctf -> libdwarf, which NEEDs libz (x86: the world has it): zlib as a dep (link path + RUNPATH).
      lsof = { deps = args.deps ++ [ srcPkgs.zlib ]; build = "sed -i 's|^#    if defined(__i386) \\|\\| defined(__amd64)$|#    if defined(__aarch64__)\\n#        define ARCH64B \"aarch64\"\\n#    elif defined(__i386) \\|\\| defined(__amd64)|' lib/dialects/sun/dproc.c\n"
        + "grep -q 'define ARCH64B \"aarch64\"' lib/dialects/sun/dproc.c || { echo 'FATAL: lsof ARCH64B anchor' >&2; exit 1; }\n" + args.build; };
      # gmp: the x86 text pins --build=x86_64-pc-solaris2.11 after lp64Fix's aarch64 --build (the last one wins): drop it.
      gmp6 = { build = let b = builtins.replaceStrings [ "--build=x86_64-pc-solaris2.11 " ] [ "" ] args.build; in
        if b == args.build then throw "a64r gmp6: --build anchor" else b; };
      # builtins/psize.sh times a pipe fill ('psize.aux | sleep 3') and falls back to 512 when that comes back empty: on dixa 2 of 3
      # builds got 512, one 16384 (--check differs in bin/bash). Pin the fallback, which the served stage0 bash ships (safe for here-docs).
      bash = { build = "printf '#!/bin/sh\\necho \"#define PIPESIZE 512\"\\n' > builtins/psize.sh\n" + args.build; };
    }.${args.pname} or { };
  };
  final = import ./a64h-pkgs.nix { inherit (srcPkgs) mkSrcPkg; };
  # one ncurses/readline/libiconv/less/sqlite per set, as NixOS has (the seed keeps its served duplicates): base-src's and cli's
  # copies are srcPkgs', and nixChain links the set's sqlite 3.50.4 (homePkgs.sqlite) instead of its own 3.46.1.
  shared = if stage == "seed" then { } else { inherit (srcPkgs) ncurses readline libiconv less; };
  srcPkgs = import ./src.nix { gate = gate'; libcSlice = libc; inherit gcc system a64;
    sharedChain = if stage == "seed" then { } else { inherit (homePkgs) sqlite; }; };

  # what a home needs (lib/home-manager-pkgs.nix + the headless C tier), from the x86 recipes (./home.nix).
  homePkgs = import ./home.nix { gate = gate'; libcSlice = libc; inherit gcc srcPkgs system shared; };

  systemPath = derivation {
    name = "system-path";
    inherit system;
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
homePkgs // (if stage == "seed" then { } else final // {
  # the build-only tools under their pnames (solnix-builder.sh drv_for finds an attr by pname, _ or camelCase)
  illumos-build-tools = a64.illumosTools; cc-store-names = a64.ccNames; sh-store = a64.shAlias; solnix-a64-build-tools = a64.buildToolsFarm; }
  # x86-served recipes on the store-only aarch64 set (a64r): the same recipe files (./a64r-pkgs.nix)
  // import ./a64r-pkgs.nix { inherit srcPkgs homePkgs a64 final system; }) // {
  gate = gate';
  inherit libc rtld ld sys systemPath gcc srcPkgs;
  inherit (srcPkgs) zlib openssl nixChain git tree ncurses less nano nvi htop top wget gateLibs bsdfetch gccWrapper readline bash;
  nix = srcPkgs.nixChain.nix;
  nixSrc = srcPkgs.nixChain.nix;
  inherit (srcPkgs.nixChain) curl xz;
  vi = srcPkgs.nvi;
  inherit homePkgs;
  # minimal /run/current-system for the aarch64 image (./system.nix; not the module toplevel).
  systemToplevel = import ./system.nix { pkgs = { inherit (srcPkgs) nixChain; nix = srcPkgs.nixChain.nix; };
                                         extraPaths = [ srcPkgs.nixChain.curl srcPkgs.git srcPkgs.tree srcPkgs.less srcPkgs.nano srcPkgs.nvi srcPkgs.htop srcPkgs.top srcPkgs.wget srcPkgs.bsdfetch srcPkgs.bash ]; inherit system; };
}
