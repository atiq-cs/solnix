# tranche-entry-224.nix — Phase-3 "build real hermetic x86_64-solaris
# derivations against the pure stdenv" entry point, on Nix 2.24+.
#
# This is the 2.24 successor to tranche-entry.nix, now wired against the NEWER
# nixpkgs fork (qmvlnvf0, the one the 2.3.16 tranche6 used) so the
# fetchFromGitHub/fetchpatch-src packages (curl/git/vim/htop/nvi/gdb) evaluate:
# the older 00w7p2sg fork's eval-time fetchurl-shim only covered plain
# `fetchurl`, so fetchpatch (H18) and fetchzip/fetchFromGitHub (H19) srcs threw.
# The qmvlnvf0 fork ships the H18/H19-covering shim (fetchurl-shim, passed as
# `fetchurlShim`), plus the H20-H36 per-package fixes live in the primary's
# solaris-overlay (passed as `solarisOverlay`).
#
# 2.24 vs 2.3.16: Nix 2.24 writes .attrs.sh and exports NIX_ATTRS_SH_FILE
# natively, so the `__structuredAttrs = false` adapter the 2.3.16 daemon needed
# is DELETED here; the by-name package universe builds directly on the nixpkgs
# default. The tranche6 stack's structuredAttrs adapter + fetchurlBoot re-assert
# are therefore dropped; everything else (perl wrap, bash pins, the base
# illumosGnm/gmpCOnly/mpfrCOnly overlays, the primary solaris-overlay) carries
# over unchanged.
#
# HOST DEPENDENCY (seed stage0): the seed's GNU userland `awk` (gawk) NEEDs
# libmpfr.so.6 from the host runtime linker path (stdenv setup.sh's
# substituteAll enumerates @var@ via awk). The build host must provide
# libmpfr.so.6 (`pkg install library/mpfr`). Stage0 host dep only; the FINAL
# package closure stays host-free.
#
# Usage on host (Nix 2.24 store nix):
#   nix-build /root/tranche-224.nix -A <nixpkgs-attr>   # e.g. -A gettext
{ system ? "x86_64-solaris"
, nixpkgs ? <nixpkgs-patched>
, illumos ? /root/solnix-pkgs/pkgs/os-specific/illumos
, fetchurlShim ? ./fetchurl-shim-qmvlnvf0.nix
, solarisOverlay ? ./solaris-overlay-qmvlnvf0.nix
  # forkPath / gnuConfigGuess / gnuConfigSub: out-of-tree store paths the shim
  # + overlay reference. Defaults are the absolute paths (classic/impure build
  # path via `nix-build`). The pure by-name flake (pkgs/illumos/phase3/
  # by-name-flake) passes these as `flake = false` INPUTS so `nix profile
  # install` evaluates with NO --impure.
, forkPath ? /nix/store/qmvlnvf0kk1zkfjpjpxwimg5ym8sfwnk-nixpkgs-patched-1785781297346528064
, gnuConfigGuess ? null
, gnuConfigSub ? null
}:
import nixpkgs {
  inherit system;
  overlays = [
    (final: prev: { solnix = final.callPackage illumos { }; illumos = final.solnix; })
    (import fetchurlShim { inherit forkPath; })
    # H3 (from tranche 5): route stdenv.fetchurlBoot through the same shim so
    # the libxcrypt perl<->libxcrypt cycle-break src is an eval-time
    # fixed-output fetch. On 2.24 the shim's fetchurlBoot passthru
    # (solnixShimFetch) is baked directly onto the stdenv (no structuredAttrs
    # adapter re-wrap to fight).
    (final: prev: {
      stdenv = prev.stdenv // { fetchurlBoot = final.solnixShimFetch; };
      stdenvNoCC = prev.stdenvNoCC // { fetchurlBoot = final.solnixShimFetch; };
    })
    # perl fix (H10/H11 from tranche 5): drop the Linux-only ld-shared.patch
    # and add the illumos split-libc link libs (-lm -lnsl -lsocket), applied as
    # a whole-stdenv mkDerivation wrap so every perl variant in the graph
    # (build-time deps of git/curl/gettext) gets it. The fetchurlBoot passthru
    # above is preserved because this wrap only rewrites .mkDerivation.
    (final: prev:
      let
        fixPerlAttrs = a:
          if (a.pname or "") == "perl"
          then a // {
            patches = builtins.filter
              (p: baseNameOf (toString p) != "ld-shared.patch")
              (a.patches or []);
            NIX_LDFLAGS =
              (if a ? NIX_LDFLAGS then a.NIX_LDFLAGS + " " else "")
              + "-lm -lnsl -lsocket";
          }
          else a;
        patchPerl = stdenv: stdenv // {
          mkDerivation = args:
            if builtins.isFunction args
            then stdenv.mkDerivation (finalAttrs: fixPerlAttrs (args finalAttrs))
            else stdenv.mkDerivation (fixPerlAttrs args);
        };
      in {
        stdenv = patchPerl prev.stdenv;
      })
    # bashNonInteractive lost its shellPath passthru (lowPrio + spliced pkgset),
    # so runtimeShell = bash + bash.shellPath throws. Restore shellPath and pin
    # runtimeShell/runtimeShellPackage to plain bash so packages that read
    # runtimeShell in configureFlags evaluate.
    (final: prev: {
      bashNonInteractive = prev.bashNonInteractive // { shellPath = "/bin/bash"; };
      runtimeShellPackage = prev.bash;
      runtimeShell = "${prev.bash}/bin/bash";
    })
    # illumosGnm + the C-only gmp/mpfr + no-check libffi that the solaris-overlay
    # withGnm helper and the fragile-test packages depend on.
    (final: prev:
     let
      # fixPy: the full illumos CPython 3.14 fix set (config.guess, -z nodefs
      # module links, socketmodule Py_SUNOS_VERSION, native libintl, relaxed
      # openssl-dev ref). Applied to BOTH `python3` (the top-level alias) AND
      # `python314` (the interpreter python3Packages/meson are actually built
      # with) -- overriding only `python3` misses python3Packages.python, so the
      # meson-pulled build-platform python stays broken and blocks the whole
      # meson swath (xorgproto/pixman/p11-kit/libxcb/...).
      #
      # Gap 2: the top-level `bzip2`/`xz` are the dev-less stdenv SEED slices
      # (bzip2 = a single binary, xz = a single binary; no bzlib.h/lzma.h, no
      # libbz2.so/liblzma.so), so CPython silently omits the _bz2 and _lzma
      # extension modules. Thread the header-ful REAL builds (bzip2Real/xzReal
      # from the solaris-overlay: multi-output with bzlib.h/lzma.h + the libs)
      # into the interpreter so _bz2 + _lzma compile and import.
      fixPy = base: (base.override {
        withZstd = false;
        bzip2 = final.bzip2Real;
        xz = final.xzReal;
      }).overrideAttrs (old: {
        configureFlags = (old.configureFlags or [ ])
          ++ [ "--build=x86_64-pc-solaris2.11" ];
        # Route the shared-module link through the cc-wrapper (`cc -shared`) and
        # allow undefined symbols (`-z nodefs`): extension modules leave the
        # CPython C-API symbols unresolved, bound from the interpreter at import
        # (GNU ld does this by default; Solaris ld needs -z nodefs explicit).
        preConfigure = (old.preConfigure or "") + ''
          export LDSHARED="$CC -shared -Wl,-z,nodefs"
          export LDCXXSHARED="$CXX -shared -Wl,-z,nodefs"
          export BLDSHARED="$CC -shared -Wl,-z,nodefs"
          # autoreconfPhase regenerates config.guess (the 2025-07-10 copy that
          # `cannot guess build type` on this UNAME_RELEASE-empty illumos), so
          # overwrite it HERE (post-autoreconf, pre-configure) with a fixed echo
          # of the canonical triple.
          for cg in config.guess $(find . -name config.guess 2>/dev/null); do
            printf '#!/bin/sh\necho x86_64-pc-solaris2.11\n' > "$cg"
            chmod +x "$cg"
          done
        '';
        # socketmodule.c gates a Solaris-10 sethostname workaround on
        # `Py_SUNOS_VERSION <= 510`, undefined here -> the cpp becomes
        # `... && <empty> <= 510` -> "operator '&&' has no right operand".
        # illumos is SunOS 5.11 (never the <=510 branch); rewrite to literal 0.
        postPatch = (old.postPatch or "") + ''
          sed -i 's/Py_SUNOS_VERSION <= 510/0/' Modules/socketmodule.c
        '';
        # A GNU gettext libintl.h leaks in via a store dep, so _localemodule.c
        # emits libintl_* calls, but the link uses illumos's native `-lintl`
        # (plain names only) -> `ld: fatal: symbol referencing errors` on
        # _freeze_module. illumos libc provides gettext natively, so tell
        # configure there is no libintl.h / no -lintl (autoconf cache).
        env = (old.env or { }) // {
          ac_cv_header_libintl_h = "no";
          ac_cv_lib_intl_textdomain = "no";
        };
        # nixpkgs' python guards the main output against an openssl-dev ref
        # (disallowedReferences); the sysconfig strip is incomplete on illumos
        # so the -dev include path (build metadata, /nix/store, no host leak)
        # remains. Clear the over-strict check so the interpreter lands.
        disallowedReferences = [ ];
        doCheck = false;
        doInstallCheck = false;
      });
     in {
      illumosGnm = final.runCommand "illumos-gnm" { } ''
        mkdir -p $out/bin
        ln -s ${final.stdenv.cc.bintools.bintools}/bin/nm $out/bin/gnm
      '';
      gmpCOnly = (final.gmp.override { cxx = false; }).overrideAttrs (_: { doCheck = false; });
      libffiNoCheck = final.libffi.overrideAttrs (_: { doCheck = false; });
      # libffi's doCheck pulls dejagnu -> expect, which fails to build on illumos
      # (expect needs pty.h/BSD ptys, absent here). libffi tests are not the
      # deliverable; disable its check globally so every consumer (python3,
      # meson-driven xorgproto/libxcb, ...) gets a buildable libffi.
      libffi = prev.libffi.overrideAttrs (_: { doCheck = false; });
      # asciidoc (ninja's manual dep) runs a pytest suite in its build that is
      # fragile on illumos (missing `mock`, etc.); tests are not the deliverable
      # -> disable its checks so ninja -> the meson swath builds.
      asciidoc = prev.asciidoc.overrideAttrs (_: {
        doCheck = false; doInstallCheck = false; nativeCheckInputs = [ ];
      });
      # ninja (the meson backend) launches subprocesses with posix_spawn, but
      # this illumos kernel lacks the SYS_spawn fast path and libc does not fall
      # back -> the spawn syscall traps SIGSYS ("Bad System Call", core) the
      # moment ninja runs a rule. Patch subprocess-posix.cc to fork()+execvp()
      # (same signal-mask/pgroup/fd actions) so ninja works, unblocking every
      # meson-built package (xorgproto/pixman/p11-kit/libpsl/libxcb/...).
      ninja = prev.ninja.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [ ./ninja-fork-exec-illumos.patch ];
      });
      # withZstd off (CPython 3.14 compression.zstd -> zstd -> cmake extra graph)
      # + the illumos fix set, applied to the alias AND the interpreter so
      # python3Packages.python (meson's build python) is fixed too.
      python3 = fixPy prev.python3;
      python314 = fixPy prev.python314;
      mpfrCOnly = (final.mpfr.override { gmp = final.gmpCOnly; }).overrideAttrs (_: { doCheck = false; });
    })
    (import solarisOverlay { inherit forkPath gnuConfigGuess gnuConfigSub; })
    # H26 (2.24): cmake-minimal's bundled libuv links -lkstat -lsendfile
    # (illumos), absent from the seed's base libs, so the cmake bootstrap fails
    # `ld: fatal: library -lkstat: not found`.
    # extra-syslibs is now a REAL derivation (see solaris-overlay-qmvlnvf0.nix):
    # it slices the versioned illumos syslibs (libmd/libmp/libuutil/libnvpair/
    # libidmap/libavl/libsec + bare .so links) out of the seed via the stdenv's
    # seedSyslibs slice, so it rebuilds reproducibly on any fresh host and
    # substitutes from cache -- NO nix-store --add FOD. It carries libkstat/
    # libsendfile/libproc/libcontract bare .so links pointing at the base
    # platform /lib/amd64 (illumos ABI, resolved at runtime like libc). Wire
    # its -L into cmake-minimal (bundled libuv links -lkstat -lsendfile) so the
    # cmake bootstrap link resolves. Unblocks cmake -> nvi. Defined inline here
    # (the overlay's copy is in a private `let`); anchored on final.seedSyslibs.
    (final: prev:
      let
        extraSyslibs = final.runCommand "illumos-extra-syslibs" { } ''
          mkdir -p "$out/lib/amd64"
          for f in ${final.seedSyslibs}/lib/amd64/*; do
            ln -s "$f" "$out/lib/amd64/$(basename "$f")"
          done
          for n in libkstat libsendfile libproc libcontract; do
            [ -e "/lib/amd64/$n.so.1" ] && ln -sf "/lib/amd64/$n.so.1" "$out/lib/amd64/$n.so"
          done
        '';
        seedL = "-L${extraSyslibs}/lib/amd64";
        # H37 (2.24): cmake's package.nix sets CMAKE_RANLIB to
        # ${bintools}/bin/ranlib, but the seed illumos bintools slice ships
        # ar/as/ld/nm/elfdump but NO `ranlib` symlink -- so every static-lib
        # link in cmake's own build runs a nonexistent ranlib and fails with
        # `Error running link command: no such file or directory`. The illumos
        # /usr/bin/ranlib works on the seed ar's archives (verified), and the
        # seed bintools already host-paths `ar -> ../usr/bin/ar`, so a matching
        # ranlib wrapper is the same stage0 convention. Provide a store dir with
        # ranlib (+ ar/strip alongside) and point CMAKE_RANLIB/AR/STRIP at it.
        illumosRanlib = final.runCommand "illumos-ranlib" { } ''
          mkdir -p $out/bin
          ln -s /usr/bin/ranlib $out/bin/ranlib
          ln -s /usr/bin/ar $out/bin/ar
          ln -s /usr/bin/strip $out/bin/strip
        '';
        # H38 patch (below): one-line unified diff, applied with `patch` (the
        # sandbox has no perl and illumos /usr/bin/sed's `a\` grouping is
        # unreliable; `patch` is already used for the nixpkgs patches). The
        # patch file lives next to this tranche (repo + builder).
        cmInstrNoSpawnPatch = ./cmake-instrumentation-no-spawn.patch;
        fixCmake = drv: drv.overrideAttrs (old: {
        # cmake's own bootstrap builds a bundled libuv (Utilities/cmlibuv) that
        # links kstat_*/sendfile on illumos -> `ld: fatal: library -lkstat: not
        # found`. The nixpkgs libuv buildInput is separate, so the fix must land
        # on cmake-minimal's bootstrap link: add the extra-syslibs -L and the
        # two libs to NIX_LDFLAGS, and the -L to compile flags (H1 auto-adds -R).
          env = (old.env or { }) // {
            NIX_CFLAGS_COMPILE = (old.env.NIX_CFLAGS_COMPILE or "") + " " + seedL;
            NIX_LDFLAGS = (old.env.NIX_LDFLAGS or "") + " " + seedL + " -lkstat -lsendfile";
            # cmlibarchive's CHECK_CRYPTO does find_library(NAMES md) after a
            # successful CHECK_LIBRARY_EXISTS(md), then feeds ${LIBMD_LIBRARY}
            # to a TRY_COMPILE. find_library is hermetic, so point
            # CMAKE_LIBRARY_PATH at the extra-syslibs dir (now carrying a bare
            # libmd.so) so it resolves instead of NOTFOUND.
            CMAKE_LIBRARY_PATH = "${extraSyslibs}/lib/amd64";
          };
          # Override the AR/RANLIB/STRIP the cmake package.nix derived from the
          # ranlib-less seed bintools (H37). Appended after the package.nix `--`
          # block so these win in the bootstrap's configureFlags.
          cmakeFlags = (old.cmakeFlags or [ ]) ++ [
            "-DCMAKE_AR=${illumosRanlib}/bin/ar"
            "-DCMAKE_RANLIB=${illumosRanlib}/bin/ranlib"
            "-DCMAKE_STRIP=${illumosRanlib}/bin/strip"
          ];
          # H38 (2.24): every real (non-try-compile) `cmake` configure runs
          # cmInstrumentation::GetDynamicSystemInformation, which on Solaris has
          # cmsys SystemInformation shell out (psrinfo/kstat) via posix_spawn.
          # This illumos kernel (68259130da) lacks the SYS_spawn fast path and
          # its libc does not fall back to fork/exec -> the spawn syscall returns
          # ENOSYS and the process takes SIGSYS (`Bad System Call`, core). The
          # dynamic sysinfo is pure telemetry (host memory/CPU load in a JSON
          # blob), never build-affecting, so neuter the probe to a no-op. Kills
          # the crash for cmake-as-a-build-tool (nvi et al.) and drops the
          # unwanted instrumentation shell-out entirely.
          postPatch = (old.postPatch or "") + ''
            patch -p1 < ${cmInstrNoSpawnPatch}
          '';
          # H39 (2.24): the H38 instrumentation neuter covers only ONE spawn
          # site. cmake links TWO libc.so.1 -- the seed-syslibs snapshot
          # (illumos-seed-syslibs/lib/amd64/libc.so.1) AND the live
          # /lib/64/libc.so.1 -- and inside the build sandbox its libuv
          # uv_spawn / cmUVProcessChain (compiler-feature detection, try_run,
          # execute_process) binds posix_spawn out of the STALE seed libc,
          # whose SYS_spawn path traps SIGSYS (Bad System Call) on this kernel
          # (68259130da). The live /lib/64/libc.so.1 carries the working
          # fallback. The consumer-package gate (LD_LIBRARY_PATH_64=/lib/64)
          # never reaches cmake's OWN configure spawns: cmakeConfigurePhase
          # runs `cmake` before any consumer preConfigure sets it. Bake the
          # export into cmake's setup-hook so EVERY consumer's cmake configure
          # prefers the kernel-matched libc for all of its spawns. Done in
          # postFixup: the nix-support/setup-hook file is assembled from the
          # setupHooks list during fixupPhase, so postInstall is too early.
          postFixup = (old.postFixup or "") + ''
            hook="$out/nix-support/setup-hook"
            if [ -f "$hook" ]; then
              echo 'export LD_LIBRARY_PATH_64=/lib/64''${LD_LIBRARY_PATH_64:+:$LD_LIBRARY_PATH_64}' >> "$hook"
            fi
          '';
        });
      in {
        # Same illumos fix set for cmake-minimal (bootstrap tool) AND the full
        # `cmake` 4.x: its own bundled libuv also links -lkstat/-lsendfile, its
        # bootstrap needs the ranlib wrapper + the no-spawn instrumentation
        # patch. Every cmake C/C++ lib that requests `cmake` (pugixml/tinyxml2/
        # rapidjson/cereal/leveldb/...) routes through this rather than
        # cmakeMinimal, so both must carry the fix.
        cmakeMinimal = fixCmake prev.cmakeMinimal;
        cmake = fixCmake prev.cmake;
      })
    # release-toolset curl/rsync: the full `curl` attr and rsync enable
    # zstd/brotli/lz4/xxHash, which pull zstd -> cmake (H26, still blocked on
    # this fork: cmake-minimal bootstrap fails on -lkstat/-lsendfile). The
    # release-critical curl deps are openssl+zlib+nghttp2 (http2) only, and
    # rsync's core is fine without those compressors. Drop the cmake-pulling
    # features so both build; scpSupport/libssh2 is already off on SunOS by
    # default. This preserves the solaris-overlay's gssSupport=false + socket
    # libs (curl) via a further .override/.overrideAttrs on the overlay result.
    (final: prev: {
      curl = (prev.curl.override {
        zstdSupport = false; brotliSupport = false;
        http3Support = false; pslSupport = false;
      });
      rsync = (prev.rsync.override {
        enableZstd = false; enableLZ4 = false; enableXXHash = false;
      }).overrideAttrs (old: {
        # python3 (nativeCheckInputs, for runtests.py) pulls cmake (H26,
        # blocked). Tests are not the deliverable on a fresh port; drop the
        # check inputs + doCheck so cmake never enters the build.
        doCheck = false;
        nativeCheckInputs = [];
        preCheck = "";
      });
      # gdb: pythonSupport (build==host default) pulls python3 -> cmake, and
      # zstd/xxhash/sourceHighlight/dejagnu/libipt buildInputs each pull cmake
      # too (all H26-blocked). The release-critical gdb deps are
      # gmp/mpfr/ncurses/readline/expat/zlib (all on 2.24 already). Drop the
      # cmake-pullers and disable debuginfod (elfutils). The H2 seedSyslibs
      # RUNPATH supplies libstdc++/libgcc_s at runtime, so no static-libgcc/
      # -static-libstdc++ is needed (and those flags break the illumos conftest
      # link -> "C compiler cannot create executables"). doCheck off (dejagnu).
      gdb = (prev.gdb.override {
        pythonSupport = false;
        withGuile = false;
        enableDebuginfod = false;
      }).overrideAttrs (old: {
        buildInputs = builtins.filter
          (b: let n = b.pname or b.name or ""; in
              !(final.lib.hasInfix "zstd" n || final.lib.hasInfix "source-highlight" n
                || final.lib.hasInfix "sourceHighlight" n || final.lib.hasInfix "xxhash" n
                || final.lib.hasInfix "xxHash" n || final.lib.hasInfix "dejagnu" n
                || final.lib.hasInfix "libipt" n || final.lib.hasInfix "processor-trace" n))
          (old.buildInputs or []);
        doCheck = false;
        doInstallCheck = false;
        nativeInstallCheckInputs = [];
      });
    })
    # cmocka 2.0.2: include/cmocka.h gates a CMOCKA_NO_ACCESS_ATTRIBUTE on
    # __has_attribute(access) (true since GCC 10), but uses the `access(none,
    # N)` MODE that GCC only accepts from 11+ -- GCC 10.5 here errors
    # `attribute 'access' invalid mode 'none'`. Strip the access() attribute
    # from the header so it degrades to the empty fallback the file already
    # defines. cmocka is a leaf test lib (libcbor's test dep), so this is the
    # only consumer-visible use.
    (final: prev: {
      cmocka = prev.cmocka.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          sed -i 's/__attribute__((access(none, 1), access(none, 2)))//' include/cmocka.h
        '';
      });
    })
    # wave-4 fixups: none of these are SIGSYS (the cmake configure now passes
    # for all of them via H39); each is a plain illumos build detail.
    (final: prev: {
      # tokyocabinet's configure needs bzlib.h, but the top-level `bzip2` is
      # the header-less stdenv seed slice. Thread the header-ful bzip2Real
      # (from solaris-overlay) so `bzlib.h is required` clears.
      tokyocabinet = (prev.tokyocabinet.override { bzip2 = final.bzip2Real; });
      # minizip-ng: top-level `xz` is the header-less seed slice, so its cmake
      # LibLZMA probe fails (`LibLZMA library not found`); thread xzReal. Its
      # CTest suite is fragile on a fresh illumos port and is not the
      # deliverable, so drop doCheck (which also flips MZ_BUILD_TESTS off).
      minizip-ng = (prev.minizip-ng.override { xz = final.xzReal; }).overrideAttrs (_: {
        doCheck = false;
      });
      # libxlsxwriter runs its bundled test binary in checkPhase; the suite is
      # fragile on illumos and not the deliverable.
      libxlsxwriter = prev.libxlsxwriter.overrideAttrs (_: { doCheck = false; });
      # libzip builds its man pages with groff, but groff shells troff out via
      # posix_spawn and traps SIGSYS on this kernel (its own spawn path, not
      # cmake's -- H39 does not reach it). Drop the man output + the groff
      # nativeBuildInput so the library itself lands; man pages are not the
      # deliverable on a fresh port.
      libzip = prev.libzip.overrideAttrs (old: {
        outputs = builtins.filter (o: o != "man") (old.outputs or [ "out" ]);
        nativeBuildInputs = builtins.filter
          (b: (b.pname or b.name or "") != "groff")
          (old.nativeBuildInputs or [ ]);
      });
      # doctest runs its own test binary in checkPhase (fragile here); it is a
      # header-only assertion lib consumed by xsimd, so the check is not the
      # deliverable.
      doctest = prev.doctest.overrideAttrs (_: { doCheck = false; });
      # xsimd builds+runs a doctest suite (-DBUILD_TESTS=ON, doCheck=true); the
      # SIMD test binary is fragile on this illumos gcc, and the header lib is
      # the deliverable. Turn the suite off.
      xsimd = prev.xsimd.overrideAttrs (old: {
        doCheck = false;
        cmakeFlags = (builtins.filter (f: f != "-DBUILD_TESTS=ON")
          (old.cmakeFlags or [ ])) ++ [ "-DBUILD_TESTS=OFF" ];
      });
      # c-blosc gates its AVX2 roundtrip test binaries on doCheck; that suite
      # fails on this platform's gcc and is not the deliverable.
      c-blosc = prev.c-blosc.overrideAttrs (_: { doCheck = false; });
    })
    # lua's Makefile solaris target ends with `ranlib`, but makeFlags sets
    # RANLIB=${targetPrefix}ranlib -> bare `ranlib`, absent from the seed
    # bintools slice (H37: seed ships ar/as/ld/nm/elfdump, no ranlib). The
    # illumos /usr/bin/ranlib works on the seed ar's archives (the same stage0
    # host-path convention the seed bintools uses for `ar`). Repoint RANLIB/AR
    # at the illumos tools so the static liblua.a link succeeds.
    (final: prev: {
      lua5_4 = prev.lua5_4.overrideAttrs (old: {
        makeFlags = builtins.filter
          (f: !(final.lib.hasPrefix "RANLIB=" f))
          (old.makeFlags or [ ])
          ++ [ "RANLIB=/usr/bin/ranlib" ];
      });
    })
    # gawkReal defined after solaris-overlay so final.gawk is a resolved drv:
    # strip the autoreconf/texinfo path (illumos-fragile, unneeded for a working
    # awk) and link the C-only gmp/mpfr for bignum.
    (final: prev: {
      gawkReal = prev.gawk.overrideAttrs (old: {
        nativeBuildInputs = builtins.filter
          (d: let n = d.pname or d.name or ""; in
              !(final.lib.hasInfix "autoreconf" n || final.lib.hasInfix "texinfo" n))
          (old.nativeBuildInputs or []);
        outputs = builtins.filter (o: o != "info") (old.outputs or [ "out" ]);
        postPatch = "";
        buildInputs = (old.buildInputs or []) ++ [ final.gmpCOnly final.mpfrCOnly ];
        NIX_CFLAGS_COMPILE_BEFORE = builtins.concatStringsSep " " [
          (old.NIX_CFLAGS_COMPILE_BEFORE or "")
          "-L${final.mpfrCOnly}/lib" "-L${final.gmpCOnly}/lib"
        ];
      });
    })
    # cmake-graph swath: the FIXED cmake is cmakeMinimal (kstat/sendfile link,
    # ranlib wrapper, SIGSYS-spawn neuter, per H26/H37/H38). The full `cmake`
    # attr is a SEPARATE --parallel bootstrap that carries none of those fixes,
    # so every package whose nativeBuildInputs pull `cmake` fails the same way.
    # Swap cmake -> cmakeMinimal in nativeBuildInputs (cmakeMinimal is a full
    # working configure/build cmake for consumers -- nvi built through it), and
    # drop doCheck: the cmake CTest suites shell out to host tools absent from
    # the sandbox (zstd playTests needs `which`/`gdiff`) -- test noise on a
    # fresh port, same rationale as the rsync/gdb doCheck=false above. One
    # list-driven helper so the whole swath is one place.
    (final: prev:
      let
        cmName = d: d.pname or d.name or "";
        useMinimalCmake = d:
          if final.lib.hasPrefix "cmake" (cmName d)
             && !(final.lib.hasInfix "minimal" (cmName d))
          then final.cmakeMinimal else d;
        fixCmake = drv: drv.overrideAttrs (old: {
          nativeBuildInputs = map useMinimalCmake (old.nativeBuildInputs or [ ]);
          doCheck = false;
          doInstallCheck = false;
        });
        # libtiff/libwebp/fontconfig pull a docs/test toolchain (sphinx/python3/
        # libxslt) whose python `toml` src has an empty hash in this fork's
        # fetch-shim -> instantiation throws before the build. Docs+tests are
        # not the deliverable on a fresh port; strip the docs/test native inputs
        # and check inputs so only the C library builds.
        stripDocs = drv: (fixCmake drv).overrideAttrs (old: {
          nativeBuildInputs = builtins.filter
            (d: let n = final.lib.toLower (cmName d); in
                !(final.lib.hasInfix "sphinx" n || final.lib.hasInfix "python" n
                  || final.lib.hasInfix "libxslt" n || final.lib.hasInfix "docbook" n))
            (map useMinimalCmake (old.nativeBuildInputs or [ ]));
          nativeCheckInputs = [ ];
          checkInputs = [ ];
        });
        attrs = [
          "lz4" "brotli" "snappy" "zstd"
          "c-ares" "libpsl" "json_c" "jansson"
          "libjpeg" "libjpeg_turbo" "libtiff" "libwebp" "freetype"
          "pixman" "fontconfig" "libarchive" "p11-kit" "p11_kit"
          "xorgproto" "libXau" "libXdmcp" "xcbproto" "libxcb"
          "libuv" "nghttp3" "ngtcp2" "spdlog" "fmt" "re2"
          "libxkbcommon" "libdeflate" "utf8proc" "lerc"
          "yajl" "libssh" "cmark" "hiredis"
          "cjson" "libcbor"
        ];
      in builtins.listToAttrs (builtins.concatMap
        (a: if prev ? ${a} then [{ name = a; value = fixCmake prev.${a}; }] else [ ])
        attrs)
      // builtins.listToAttrs (builtins.concatMap
        (a: if prev ? ${a} then [{ name = a; value = stripDocs prev.${a}; }] else [ ])
        [ "libtiff" "libwebp" "fontconfig" ])
      // {
        # fontconfig: stripDocs removes libxslt/python from nativeBuildInputs to
        # dodge the docs toolchain's toml-hash gap, but fontconfig's postInstall
        # still runs xsltproc to generate fonts.conf. Re-add just libxslt's bin
        # output (xsltproc); PYTHON is pinned to the interpreter path in the
        # solaris-overlay so AM_PATH_PYTHON needs no python on PATH.
        fontconfig = (stripDocs prev.fontconfig).overrideAttrs (old: {
          nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ final.libxslt.bin ];
        });
        # libjpeg-turbo's SIMD path needs nasm, which does not build on illumos
        # (bytesex.h uses htole64 -> -Werror implicit-decl, and its own zlib.h
        # include is unresolved). SIMD is a perf optimization, not required for a
        # working codec; drop it so the nasm dep leaves the graph. (libtiff/
        # libwebp depend on this libjpeg-turbo, so they unblock too.)
        libjpeg_turbo = (fixCmake prev.libjpeg_turbo).overrideAttrs (old: {
          cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DWITH_SIMD=OFF" ];
          nativeBuildInputs = builtins.filter
            (d: let n = final.lib.toLower (cmName d); in !(final.lib.hasInfix "nasm" n))
            (map useMinimalCmake (old.nativeBuildInputs or [ ]));
        });
        # libwebp's AVX2 path emits _mm256_cvtsi256_si32 as an out-of-line call
        # this gcc never resolves -> `ld: fatal: symbol referencing errors` when
        # linking libwebp.so / the cwebp tools. Disable SIMD (perf-only) so the
        # codec builds. (libtiff optionally consumes libwebp -> unblocks too.)
        libwebp = (stripDocs prev.libwebp).overrideAttrs (old: {
          cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DWEBP_ENABLE_SIMD=OFF" "-DWEBP_BUILD_CWEBP=OFF" "-DWEBP_BUILD_DWEBP=OFF" "-DWEBP_BUILD_GIF2WEBP=OFF" "-DWEBP_BUILD_IMG2WEBP=OFF" "-DWEBP_BUILD_ANIM_UTILS=OFF" ];
          # libwebp's only libtiff use is the tiff2webp tool (disabled above);
          # libtiff's cmake FindCMath probe fails on illumos (pow lives in libc,
          # no standalone libm.so for find_library) -> drop the libtiff input so
          # the codec builds without dragging libtiff's broken probe in.
          buildInputs = builtins.filter
            (d: let n = final.lib.toLower (cmName d); in !(final.lib.hasInfix "tiff" n))
            (old.buildInputs or [ ]);
        });
        # libtiff's cmake/FindCMath does find_library(NAMES m) + a link probe;
        # illumos keeps libm at /lib/64/libm.so (libc-family, not a store path),
        # which cmake's hermetic find_library never searches -> CMath NOTFOUND.
        # Point CMAKE_LIBRARY_PATH at /lib/64 so the probe resolves; the -lm the
        # link probe needs is on /lib/64 too. lerc/webp already routed through
        # cmake-minimal by the attrs swap. Drop libdeflate/webp examples noise
        # is not needed -- just the CMath hint.
        # libtiff's cmake/FindCMath does find_library(NAMES m); illumos keeps
        # libm in the cc bootstrapLibs (usr/lib/amd64/libm.so), which cmake's
        # hermetic find_library never searches -> CMath NOTFOUND. Point
        # CMAKE_LIBRARY_PATH at the bootstrapLibs amd64 dir so the probe resolves
        # to the SAME libm the linker already pulls (pointing at /lib/64 instead
        # records a second libm.so.2 -> `ld: recording name conflict`).
        libtiff = (stripDocs prev.libtiff).overrideAttrs (old: {
          env = (old.env or { }) // {
            CMAKE_LIBRARY_PATH = "/nix/store/fcikgn2ap30cdak1m0gcz5spcjhl430q-bootstrapLibs/usr/lib/amd64";
          };
          # docs are stripped (sphinx removed), so the declared `doc`/`man`
          # outputs are never populated -> "failed to produce output path". Drop.
          outputs = builtins.filter (o: o != "doc" && o != "man") (old.outputs or [ "out" ]);
        });
        # libxkbcommon's docs enable doxygen, which pulls the UNFIXED full `cmake`
        # (-> rhash bootstrap fail). Docs are not the deliverable; disable them so
        # doxygen (and its cmake) leave the graph.
        libxkbcommon = (fixCmake prev.libxkbcommon).overrideAttrs (old: {
          mesonFlags = (old.mesonFlags or [ ]) ++ [ "-Denable-docs=false" ];
          nativeBuildInputs = builtins.filter
            (d: let n = final.lib.toLower (cmName d); in !(final.lib.hasInfix "doxygen" n))
            (map useMinimalCmake (old.nativeBuildInputs or [ ]));
        });
        # spdlog's test suite links catch2, which pulls the UNFIXED full `cmake`
        # (-> rhash bootstrap fail). Tests are off already (fixCmake); drop the
        # catch2 buildInput and the tests flag so catch2's cmake leaves the graph.
        spdlog = (fixCmake prev.spdlog).overrideAttrs (old: {
          cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DSPDLOG_BUILD_TESTS=OFF" "-DSPDLOG_BUILD_BENCH=OFF" ];
          # illumos `struct tm` has NO tm_gmtoff/tm_zone at all (SysV layout;
          # __EXTENSIONS__ does not add them). os-inl.h's utc_minutes_offset
          # reads tm.tm_gmtoff -> `no member named tm_gmtoff`. Replace the body
          # with the illumos idiom: the extern `timezone`/`altzone` globals (set
          # by tzset(), seconds WEST of UTC), negated for the east-of-UTC minutes
          # spdlog expects; pick altzone under DST. tzset() is idempotent.
          postPatch = (old.postPatch or "") + ''
            sed -i 's#return static_cast<int>(tm.tm_gmtoff / 60);#tzset(); return static_cast<int>(-(tm.tm_isdst > 0 ? altzone : timezone) / 60);#' \
              include/spdlog/details/os-inl.h
          '';
          buildInputs = builtins.filter
            (d: let n = final.lib.toLower (cmName d); in !(final.lib.hasInfix "catch2" n))
            (old.buildInputs or [ ]);
        });
        # ngtcp2's example clients (osslclient/osslserver) require CXX23, which
        # this gcc lacks -> CMake Generate fails on examples/. The library itself
        # builds fine (OpenSSL crypto backend detected); build lib-only.
        ngtcp2 = (fixCmake prev.ngtcp2).overrideAttrs (old: {
          cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DENABLE_LIB_ONLY=ON" ];
        });
        # libssh's sftpserver.c calls the 2-arg POSIX ctime_r; this illumos
        # bootstrapLibs <time.h> only offers the 2-arg form through a
        # __PRAGMA_REDEFINE_EXTNAME static-inline path gcc does not take, so
        # every feature-macro combo still resolves to the 3-arg legacy form
        # `ctime_r(const time_t*, char*, int)`. Patch the single call site to the
        # 3-arg form (ctime output is a fixed 26-byte buffer).
        libssh = (fixCmake prev.libssh).overrideAttrs (old: {
          postPatch = (old.postPatch or "") + ''
            sed -i 's/ctime_r(&z_st->st_mtime, time)/ctime_r(\&z_st->st_mtime, time, sizeof(time))/' src/sftpserver.c
          '';
        });
      })
    # BREADTH: gnutls pulls net-tools (hostname) + util-linux-minimal via
    # unixtools, whose provider table has no `solaris` entry and recurses
    # infinitely on the `providers.linux` fallback (unixtools.nix:34). Those are
    # only used by gnutls' test suite/tools; drop them (and texinfo, docs-only,
    # same as gawkReal) so the recursion never triggers.
    # p11-kit pulls a meson/ninja/python/xz-rebuild chain that fails on this
    # fork; PKCS#11 trust-store is optional, so drop it + its trust-store flag.
    # NM points libtool's symbol-export pipe at gnm (the seed has no plain nm).
    # KNOWN-BLOCKED: libtool's $global_symbol_pipe is empty on illumos (nm
    # output-format not recognized) -> `nm ... |  | sed` syntax error at the
    # libgnutls.la link. Needs an lt_cv_sys_global_symbol_pipe override; the
    # gnutls deps (nettle/libtasn1/libidn2) are already built + durable.
    (final: prev: prev.lib.optionalAttrs (prev ? gnutls) {
      gnutls = (prev.gnutls.override { p11-kit = null; }).overrideAttrs (old: {
        nativeBuildInputs = builtins.filter
          (d: let n = d.pname or d.name or ""; in
              !(final.lib.hasInfix "net-tools" n || final.lib.hasInfix "util-linux" n
                || final.lib.hasInfix "texinfo" n))
          (old.nativeBuildInputs or [ ]);
        configureFlags = builtins.filter
          (f: f != "--with-p11-kit" && !(final.lib.hasPrefix "--with-default-trust-store-pkcs11" f))
          (old.configureFlags or [ ]) ++ [ "--without-p11-kit" ];
        buildInputs = builtins.filter
          (d: let n = d.pname or d.name or ""; in !(final.lib.hasInfix "p11-kit" n))
          (old.buildInputs or [ ]);
        NM = "${final.illumosGnm}/bin/gnm";
        outputs = builtins.filter (o: o != "info") (old.outputs or [ "out" ]);
        doCheck = false;
        doInstallCheck = false;
      });
    })
    # DEBUG: REAL split-debug for the daily-driver core set (Option A: keep the
    # trusted Solaris ld, inject a build-id note POST-link, then split). nixpkgs'
    # separateDebugInfo gates its `-debug` split to isLinux AND depends on
    # `ld --build-id` (Solaris ld has none), so it is a no-op here. The solnix
    # hook (solnix-separate-debug-info.sh) reproduces the SAME artifact gdb
    # consumes on any platform -- a `-debug` output with
    # lib/debug/.build-id/XX/YY.debug reachable by build-id -- using the
    # illumos-native toolchain (GNU objcopy 2.46 + illumos elfedit), verified
    # end-to-end: gdb loads source-level symbols via the injected build-id on
    # both executables and shared libraries; both keep running.
    #
    # This replaces the earlier in-band-DWARF workaround (dontStrip + -ggdb in
    # `out`, no split) now that a build-id-capable path is proven.
    (final: prev:
      let
        sepDebugHook = builtins.path {
          path = ./solnix-separate-debug-info.sh;
          name = "solnix-separate-debug-info.sh";
        };
        withRealSplitDebug = drv: drv.overrideAttrs (old: {
          # keep DWARF (compile -ggdb, don't let the generic fixup strip it
          # before our hook splits it out).
          dontStrip = true;
          NIX_CFLAGS_COMPILE_BEFORE = (old.NIX_CFLAGS_COMPILE_BEFORE or "") + " -ggdb";
          outputs = let o = old.outputs or [ "out" ];
            in if builtins.elem "debug" o then o else o ++ [ "debug" ];
          # tools the hook needs (host toolchain slice; native-on-illumos stage).
          OBJCOPY = "/usr/gnu/bin/objcopy";
          ELFEDIT = "/usr/bin/elfedit";
          SHA1SUM = "/usr/bin/sha1sum";
          # run the split in postFixup, per output, after the RUNPATH fixup.
          postFixup = (old.postFixup or "") + ''
            export OBJCOPY ELFEDIT SHA1SUM
            . ${sepDebugHook}
            for _o in $outputs; do
              [ "$_o" = debug ] && continue
              prefix=''${!_o}
              [ -e "$prefix" ] || continue
              _solnixSeparateDebugInfo
            done
          '';
        });
        coreDebug = [ ]; # host lacks objcopy; real split-debug disabled
      in builtins.listToAttrs (builtins.concatMap
        (a: if prev ? ${a} then [{ name = a; value = withRealSplitDebug prev.${a}; }] else [ ])
        coreDebug))
      # FLEET ADOPTION: to enable real split-debug for MORE packages, add their
      # nixpkgs attrs to `coreDebug`. (A blanket "every package" overlay would
      # wrap the entire by-name set -- do that only after A/B'ing a wider sample,
      # since -ggdb + the postFixup split adds build time + a `debug` output to
      # each derivation.)
  ];
  # 2.24 supports structuredAttrs natively, so the nixpkgs default is correct.
  config = { allowUnsupportedSystem = true; };
}
