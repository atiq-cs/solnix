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
      # meson's symbolextractor.py (shared-lib symbol lists, for relink avoidance) prepends the OI host's /usr/gnu/bin to PATH to find GNU
      # nm/readelf on SunOS (upstream text; gate2 B13). A solnix host has no /usr/gnu: drop the prefix, so it uses PATH as is (gnu_syms
      # falls back to dummy_syms when no GNU nm is found, which only costs relinks), as NixOS patches meson's host paths.
      meson = { build = let a = ''cp -r mesonbuild meson.py "$out/lib/meson/"''; b = builtins.replaceStrings [ a ] [ (a + "\n"
          + ''f="$out/lib/meson/mesonbuild/scripts/symbolextractor.py"; grep -q "'/usr/gnu/bin:' + origpath" "$f" || { echo "FATAL: meson symbolextractor anchor" >&2; exit 1; }''
          + "\n" + ''sed -i "s|'/usr/gnu/bin:' + origpath|origpath|" "$f"; ! grep -q /usr/gnu "$f" || { echo "FATAL: meson still names /usr/gnu" >&2; exit 1; }'') ] args.build; in
        if b == args.build then throw "a64r meson: anchor" else b; };
      # xkeyboard-config's rules/ needs python >= 3.11: x86 links the OI host's /usr/bin/python3.14; here the store python3 (3.13, b2)
      xkeyboard-config = { build = let a = "ln -sf /usr/bin/python3.14 "; b = builtins.replaceStrings [ a ] [ "ln -sf ${homePkgs.cliSet.python3}/bin/python3 " ] args.build; in
        if b == args.build then throw "a64r xkeyboard-config: anchor" else b; };
      # libxkbcommon's parser needs a yacc: x86 takes the OI host's /usr/bin/bison; here a64h's store bison (as tmux/gdbm/nix)
      libxkbcommon = { nativeTools = (args.nativeTools or [ ]) ++ [ final.bison ]; };
      # dbus's in-build check runs dbus-run-session, which execs `dbus-daemon` from PATH: on x86 that found the OI host's /usr/bin one
      # (the x86 builder PATH is the host's). On the store-only PATH there is none ("failed to execute ... dbus-daemon", dixa): name
      # the daemon just built, so the check tests this dbus and not the host's.
      dbus = { build = let a = ''"$out/bin/dbus-run-session" -- ''; b = builtins.replaceStrings [ a ] [ ''"$out/bin/dbus-run-session" --dbus-daemon="$out/bin/dbus-daemon" -- '' ] args.build; in
        if b == args.build then throw "a64r dbus: anchor" else b; };
      # openssh links base-src's own zlib + openssl (both ABIs, for x86's 32-bit PAM world): one of each per set on aarch64 (srcPkgs', served)
      # and `install -s` runs `strip` from PATH (x86: the world's illumos strip); the store-only PATH has none (dixa). --disable-strip, as
      # nixpkgs' openssh; mk-src-pkg's gstrip --strip-debug pass still runs.
      # and sshd links the proto's libpam + libcrypt (+ libcontract, PAM's NEEDs), which aarch64's gate-libs-home lacks (x86: the world):
      # a gate-libs set of those for openssh alone (as dbus' libbsm), so no other row moves.
      openssh = { deps = [ homePkgs.world sshWorld srcPkgs.zlib srcPkgs.openssl ]; build = let a = "--with-mantype=man --without-rpath";
          b = builtins.replaceStrings [ a ] [ (a + " --disable-strip") ] args.build; in if b == args.build then throw "a64r openssh: anchor" else b; };
      # neomutt's autosetup requires a `strip` on PATH (cc-check-tools ar ranlib strip) but never runs it (Makefile.autosetup has no
      # STRIP): the store `true`, so the check passes without a host tool.
      # Its hcache/hcachever.sh hashes struct text with `openssl md5 -r` (x86: the OI host's /usr/bin/openssl on PATH), else, on SunOS,
      # `digest -a md5` from PATH: neither is on the store PATH, so HCACHEVER came out "0x" (dixa). coreutils' md5sum (in the farm)
      # prints the same digest first, so the version constant is the same value.
      neomutt = { build = "export STRIP=true\n"
        + "grep -q 'prog=\"digest -a md5\"' hcache/hcachever.sh || { echo 'FATAL: neomutt md5prog anchor' >&2; exit 1; }\n"
        + "sed -i 's|if openssl=$(command -v openssl); then|if false; then|; s|prog=\"digest -a md5\"|prog=md5sum|' hcache/hcachever.sh\n" + args.build
        # libexec/neomutt/smime_keys (S/MIME key helper) ships #!/usr/bin/perl -w (gate2 B9): /usr/bin/env perl, as a64h's git hook sample
        # (-w becomes `use warnings;` on line 2: env passes one argument at most)
        + "\nf=$out/libexec/neomutt/smime_keys; head -1 $f | grep -qx '#! /usr/bin/perl -w' || { echo 'FATAL: smime_keys #! anchor' >&2; exit 1; }\n"
        + "chmod u+w $f; sed -i '1s|^#! /usr/bin/perl -w$|#!/usr/bin/env perl\\nuse warnings;|' $f\n"
        + "head -1 $f | grep -qx '#!/usr/bin/env perl' && sed -n 2p $f | grep -qx 'use warnings;' || { echo 'FATAL: smime_keys #!' >&2; exit 1; }\n"; };
      # lynx's `lynx -V` table (cfg_defs.h) is config.cache verbatim, so the absolute pkg-config and install paths configure cached (the
      # build-tools farm here) became runtime references of bin/lynx (measured: the farm in its closure). Bare names, as the recipe's
      # other ac_cv_path_* pins; the in-build check below fails a lynx that still names the farm.
      # The recipe's own `! strings ... | grep` seed-tools check cannot fail here: no strings(1) on the store PATH ("command not found",
      # dixa log), so the pipeline is always empty. grep -a on the binary instead, for the seed tools and the farm.
      lynx = { build = let a = ''! strings "$out/bin/lynx" | grep -qE "/nix/store/[a-z0-9]{32}-solnix-seed-build-tools" \''; b = builtins.replaceStrings [ a ]
          [ ''! grep -aqE "/nix/store/[a-z0-9]{32}-solnix-seed-build-tools" "$out/bin/lynx" \'' ] args.build; in
        # configure itself needs an absolute pkg-config ("expected a pathname"), so the cache entries are de-baked AFTER configure,
        # before make writes cfg_defs.h from config.cache (only the -V table reads them).
        if b == args.build then throw "a64r lynx: strings anchor" else
          let c = ''gmake -j8; gmake install sysconfdir="$out/etc"''; d = builtins.replaceStrings [ c ] [ (''sed -i "s@$(echo $PATH | tr ':' '\n' | grep -- -solnix-a64-build-tools/bin | head -1)/@@g" config.cache''
            + "\n" + ''! grep -q -- -solnix-a64-build-tools config.cache || { echo "FATAL: lynx config.cache names the farm" >&2; exit 1; }'' + "\n" + c) ] b; in
          if d == b then throw "a64r lynx: gmake anchor" else d
        + "\n! grep -aq -- '-solnix-a64-build-tools' \"$out/bin/lynx\" || { echo 'FATAL: lynx names the build-tools farm' >&2; exit 1; }\n"; };
      # screen links the proto's libcrypt + libutempter (x86: the world), which gate-libs-home lacks: its own gate-libs set, as openssh.
      screen = { deps = args.deps ++ [ screenWorld ]; };
      # base-src's libxml2 links base-src's own zlib, built for both ABIs (x86 SMF is 32-bit): on aarch64 one zlib per set (srcPkgs',
      # the served one) and LP64 only, as the set's other libraries.
      libxml2 = { deps = [ srcPkgs.zlib ]; abis = [ "64" ]; };
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
      # libgit2: cmake found the host's /usr/lib/libz.so + /usr/include ("Found ZLIB: /usr/lib/libz.so", gate L5; also /usr/lib/libpcre.so,
      # unused: REGEX_BACKEND=builtin). mk-src-pkg's env CMAKE_PREFIX_PATH is ';'-joined, which cmake splits on ':' on Unix, so it names
      # no dir and the default /usr prefix wins (measured on dixa, cmake 4.1.2). Name the store zlib, as the recipe names openssl, and
      # ignore the host prefixes (/ too: else /lib/libz.so); the cache check fails a build that still found a host library.
      libgit2 = { build = let a = "-DUSE_BUNDLED_ZLIB=OFF "; b = builtins.replaceStrings [ a ] [ (a + "-DZLIB_INCLUDE_DIR:PATH=${srcPkgs.zlib}/include "
          + "-DZLIB_LIBRARY:FILEPATH=${srcPkgs.zlib}/lib/libz.so -DCMAKE_IGNORE_PREFIX_PATH='/;/usr;/usr/local;/opt' ") ] args.build; in
        if b == args.build then throw "a64s libgit2: zlib anchor" else b
          + "\ngrep -qx 'ZLIB_LIBRARY:FILEPATH=${srcPkgs.zlib}/lib/libz.so' CMakeCache.txt || { echo 'FATAL: libgit2 zlib is not the store zlib' >&2; exit 1; }\n"
          + "! grep -E '^[A-Za-z0-9_]+:(FILEPATH|PATH)=/(usr|lib|opt)/' CMakeCache.txt | grep -v '^CMAKE_INSTALL_' || { echo 'FATAL: libgit2 cmake found a host path' >&2; exit 1; }\n"; };   # CMAKE_INSTALL_OLDINCLUDEDIR=/usr/include is GNUInstallDirs' default, not a find
      # bdwgc: gcconfig.h has no illumos aarch64 (NOSYS): ./bdwgc-aarch64-illumos.patch (its header has the why and the measurement).
      # A GC that builds but loses roots is worse than none, so its own suite runs here, before install (nixpkgs' checkPhase:
      # doCheck = true): gctest, staticrootstest, threadleaktest and the rest, all 16 must PASS (also under --check).
      bdwgc = { build = let a = "gmake -j8; gmake install"; b = builtins.replaceStrings [ a ] [ ("gmake -j8\n"
          + "gmake -j8 check >&2 || { cat test-suite.log >&2; echo 'FATAL: bdwgc gmake check failed' >&2; exit 1; }\n"
          + "grep -Eq '^# PASS: +16$' test-suite.log && grep -Eq '^# (FAIL|ERROR|XPASS): +0$' test-suite.log && [ \"$(grep -Ec '^# (FAIL|ERROR|XPASS): +0$' test-suite.log)\" = 3 ] "
          + "|| { cat test-suite.log >&2; echo 'FATAL: bdwgc test count is not 16 PASS / 0 FAIL' >&2; exit 1; }\ngmake install") ] args.build; in
        if b == args.build then throw "a64s bdwgc: gmake anchor" else "patch -p1 < ${./bdwgc-aarch64-illumos.patch} >&2\n" + b; };
      # nspr: _solaris.h/_solaris.cfg have no aarch64 arm (./nspr-aarch64-illumos.patch), and _pth.h's fixed SOLARIS thread priority
      # range makes PR_CreateThread(PR_PRIORITY_HIGH) fail on illumos libc (../patches/nspr/0001-illumos-thread-priority-range.patch: arch-
      # independent; x86 takes it in wave6). LP64 only, and no --enable-64bit (it adds -m64, which the aarch64 gcc rejects). NSPR's own suite (pr/tests
      # runtests.sh, 101 programs; nixpkgs runs none) must pass: without the priority patch its `switch` test hangs (measured on dixa).
      nspr = { abis = [ "64" ]; build = let a = "cd nspr\n"; b = builtins.replaceStrings [ "E=\"\"; [ \"$ABI\" = 64 ] && E=--enable-64bit\n" ] [ "E=\"\"\n" ] args.build; in
        if b == args.build then throw "a64s nspr: --enable-64bit anchor" else
          let c = builtins.replaceStrings [ a ] [ ("patch -p1 < ${./nspr-aarch64-illumos.patch} >&2\npatch -p1 < ${../patches/nspr/0001-illumos-thread-priority-range.patch} >&2\n" + a) ] b; in
          if c == b then throw "a64s nspr: cd anchor" else c + "\nr=0; ( cd pr/tests && gmake -j16 >&2 && TEST_TIMEOUT=300 sh ./runtests.sh ../../dist > $W/nspr-tests.out 2>&1 ) || r=$?\n"
            + "cat $W/nspr-tests.out >&2; n=$(grep -c 'Passed$' $W/nspr-tests.out || true); f=$(grep -c 'FAILED$' $W/nspr-tests.out || true)\n"
            + "[ $r = 0 ] && [ $f = 0 ] && [ $n -ge 100 ] || { echo \"FATAL: nspr tests rc=$r passed=$n failed=$f\" >&2; exit 1; }\n"; };
      # nss: coreconf/SunOS5.mk knows sparc and i86pc only (./nss-aarch64-illumos.patch: armv8 -> CPU_ARCH aarch64, no -m64); LP64
      # only; the set's zlib and an aarch64 libc-extra (base-src's is an x86 drv: lib + lib/amd64). freebl's own known-answer tests
      # (bltest -T over every line of tests/cipher/cipher.txt) and a certutil self-signed -V run in the build, as nixpkgs' nss
      # runs its test suite.
      nss = { abis = [ "64" ]; deps = map (d: if (d.name or "") == "illumos-libc-extra" then nssLibcExtra else if (d.pname or "") == "zlib" then srcPkgs.zlib else d) args.deps; build = let a = "sed -i \"s,^RPATH = -R '\\$\\$ORIGIN'$,RPATH =,\" nss/coreconf/SunOS5.mk\n";
          b0 = builtins.replaceStrings [ a ] [ ("patch -p1 < ${./nss-aarch64-illumos.patch} >&2\n" + a) ] args.build;
          # ZLIB_LIBS names base-src's own zlib (x86's, both ABIs): the set's one zlib instead (srcPkgs', served), as libxml2/openssh take
          # it by deps. The old path is dropped from the string context too (replaceStrings keeps it), so it is no input of nss.
          z = builtins.match ".*ZLIB_LIBS=\"-L(/nix/store/[a-z0-9]{32}-zlib-[^/]*)/.*" b0; old = builtins.head z;
          oldDrv = builtins.filter (k: builtins.match ".*-zlib-.*[.]drv" k != null && k != srcPkgs.zlib.drvPath) (builtins.attrNames (builtins.getContext b0));
          b = if z == null || builtins.length oldDrv != 1 then throw "a64s nss: ZLIB_LIBS anchor" else
            builtins.appendContext (builtins.replaceStrings [ old ] [ "${srcPkgs.zlib}" ] (builtins.unsafeDiscardStringContext b0))
              (builtins.removeAttrs (builtins.getContext b0) oldDrv // builtins.getContext "${srcPkgs.zlib}"); in
        if b0 == args.build then throw "a64s nss: RPATH anchor" else b + "\n" + ''
          export LD_LIBRARY_PATH=$PWD/$O/lib; T=$PWD/nss/cmd/bltest; p=0; f=0
          while read -r e m _; do case "$e" in ""|\#*) continue;; esac; m=$(echo $m | sed 's/_-/ -/g'); r=0
            "$O/bin/bltest" -T -m $m -d $T > $W/bltest.out 2>&1 || r=$?
            if [ "$r" = "$e" ]; then p=$((p+1)); else f=$((f+1)); echo "FAIL bltest -T -m $m: rc=$r want $e" >&2; tail -3 $W/bltest.out >&2; fi
          done < nss/tests/cipher/cipher.txt
          echo "bltest: $p PASS, $f FAIL" >&2; [ $f = 0 ] && [ $p -ge 50 ] || { echo "FATAL: nss bltest $p PASS $f FAIL" >&2; exit 1; }
          D=$W/certdb; mkdir -p $D; echo a64s > $W/pw; head -c 64 /dev/urandom > $W/noise
          "$out/bin/certutil" -N -d $D -f $W/pw && "$out/bin/certutil" -S -d $D -f $W/pw -z $W/noise -n a64s -s CN=a64s -x -t CT,, -v 1 >&2 \
            && "$out/bin/certutil" -V -d $D -n a64s -u V -f $W/pw > $W/cv.out 2>&1 || { cat $W/cv.out >&2; echo "FATAL: nss certutil" >&2; exit 1; }
          grep -q 'certificate is valid' $W/cv.out || { cat $W/cv.out >&2; echo "FATAL: nss certutil -V" >&2; exit 1; }
          unset LD_LIBRARY_PATH
        ''; };
      # gmp: the x86 text pins --build=x86_64-pc-solaris2.11 after lp64Fix's aarch64 --build (the last one wins): drop it.
      gmp6 = { build = let b = builtins.replaceStrings [ "--build=x86_64-pc-solaris2.11 " ] [ "" ] args.build; in
        if b == args.build then throw "a64r gmp6: --build anchor" else b; };
      # builtins/psize.sh times a pipe fill ('psize.aux | sleep 3') and falls back to 512 when that comes back empty: on dixa 2 of 3
      # builds got 512, one 16384 (--check differs in bin/bash). Pin the fallback, which the served stage0 bash ships (safe for here-docs).
      bash = { build = "printf '#!/bin/sh\\necho \"#define PIPESIZE 512\"\\n' > builtins/psize.sh\n" + args.build; };
    }.${args.pname} or { };
  };
  final = import ./a64h-pkgs.nix { inherit (srcPkgs) mkSrcPkg; };
  sshWorld = srcPkgs.mkGateLibs "illumos-gate-libs-ssh" "libpam.so.1 libcrypt.so.1 libcontract.so.1";   # openssh's gate libs (perPkg)
  # nss links -lthread -lkstat -lposix4 (coreconf OS_LIBS): base-src's libcExtra (x86, lib + lib/amd64) for aarch64, LP64 lib/ only.
  # libthread is a filter on libc and libposix4 is librt (the libc slice has it): one copy of each per process, as on x86.
  nssLibcExtra = derivation (a64.plain {
    name = "illumos-libc-extra"; inherit system; gate = gate'; libc = libc;
    builder = "/usr/bin/bash";
    args = [ "-c" ''
      set -eu; export PATH=/usr/gnu/bin:/usr/bin
      mkdir -p $out/lib
      for l in libthread.so.1 libkstat.so.1; do cp $gate/lib/$l $out/lib/; done
      ln -s libthread.so.1 $out/lib/libthread.so; ln -s libkstat.so.1 $out/lib/libkstat.so
      ln -s $libc/lib/librt.so.1 $out/lib/libposix4.so
      for f in $out/lib/*.so.1; do [ -L "$f" ] && continue; chmod u+w "$f"; /usr/bin/elfedit -e "dyn:runpath $libc/lib" "$f"; done
    '' ];
  });
  screenWorld = srcPkgs.mkGateLibs "illumos-gate-libs-screen" "libcrypt.so.1 libutempter.so.1";   # screen's (perPkg)
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
  illumos-build-tools = a64.illumosTools; cc-store-names = a64.ccNames; sh-store = a64.shAlias; solnix-a64-build-tools = a64.buildToolsFarm;
  illumos-libc-extra = nssLibcExtra; }   # nss's -lthread -lkstat -lposix4 (a64s b4), its own row
  # x86-served recipes on the store-only aarch64 set (a64r): the same recipe files (./a64r-pkgs.nix)
  // import ./a64r-pkgs.nix { inherit srcPkgs homePkgs a64 final system sshWorld screenWorld; }) // {
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
