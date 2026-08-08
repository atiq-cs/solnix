# solaris-overlay.nix — the "reuse nixpkgs" half of Phase 2 (roadmap C2).
#
# A nixpkgs overlay (final: prev: {...}) that takes the UPSTREAM nixpkgs
# expression for a package and layers the Solaris/illumos portability fixes we
# discovered during the wave builds on top of it via `overrideAttrs`. The goal
# is to build CLASS A/B packages (see nixpkgs-map.tsv) FROM nixpkgs with the
# Phase-1 x86_64-solaris stdenv, rather than re-deriving them from scratch.
#
#   CLASS A/B  -> nixpkgs expression + this overlay (portability patches)
#   CLASS C    -> the C1 recipe-codegen overlay (custom mkDerivation stubs)
#
# The fixes here are HARVESTED from three sources, all in-repo:
#   * scripts/oi-clib.sh              — GNULIBFIX, LDVERSCRIPT_STRIP, CXXMATHNS
#   * pkgs/illumos/packages.nix       — gnulibFix, tputsFix, illumosExt,
#                                       -lnsl/-lsocket LDFLAGS, libcFallbackFix
#   * artifacts/x86-wave42/failures.txt + the editors agent's findings
#                                     — BIND -zrelax=transtls, libuv errno.h
#                                       shadow, nvi u_int8_t, neovim struct queue
#
# Guard: the fixes only make sense on x86_64-solaris (GNU triple
# *-solaris2.11). On any other stdenv this overlay is a no-op, so it's safe to
# add unconditionally to `overlays`.
#
# ADDING A PACKAGE: pick the shared snippet(s) that match the failure family,
# then add one `<attr> = onSolaris prev.<attr> (old: { ... });` entry below.
# Prefer a shared snippet over a bespoke fix — most illumos build failures fall
# into a handful of families (gnulib const, socket libs, GNU ld options,
# gcc-14 strictness, C++ math namespace).

# forkPath: the patched-nixpkgs source tree (bzip2/xz/htop package.nix are
# callPackage'd out of it). gnuConfigGuess/gnuConfigSub: the content-addressed
# gnu-config FODs (config.guess/config.sub). Defaults keep the classic/impure
# build path (`nix-build`) working via builtins.storePath; the pure by-name
# flake passes these as `flake = false` INPUTS so eval needs no --impure.
{ forkPath ? /nix/store/qmvlnvf0kk1zkfjpjpxwimg5ym8sfwnk-nixpkgs-patched-1785781297346528064
, gnuConfigGuess ? null
, gnuConfigSub ? null
}:
final: prev:

let
  inherit (final) lib;

  # config.guess/config.sub sources: a pure-eval flake passes them as inputs;
  # the classic path leaves them null and falls back to builtins.storePath.
  configGuessSrc =
    if gnuConfigGuess != null then gnuConfigGuess
    else builtins.storePath /nix/store/vq0j27nvpks679djbiykl8ikdyj6z5a9-config.guess-948ae97;
  configSubSrc =
    if gnuConfigSub != null then gnuConfigSub
    else builtins.storePath /nix/store/1p61qjvlqmwrqab3zp5yh3z8rf3mvjmz-config.sub-948ae97;

  # Only x86_64-solaris (and any *-solaris) needs these fixes. Elsewhere every
  # override below collapses to the untouched upstream drv.
  isSolaris = (prev.stdenv.hostPlatform.parsed.kernel.name or "") == "solaris";

  # onSolaris drv f  -> (drv.overrideAttrs f) on illumos, else drv untouched.
  onSolaris = drv: f: if isSolaris then drv.overrideAttrs f else drv;

  # ---- shared portability snippets (mirrors packages.nix families) --------

  # F1 gnulib const fix: illumos libc declares `const char *getlocalename_l`;
  # gnulib redeclares it non-const -> conflicting-types. const-qualify gnulib's
  # copy across every vintage of the file. Idempotent, safe-if-absent.
  gnulibFix = ''
    for f in $(find . \( -name 'localename*.c' -o -name 'localename*.h' \
                       -o -name 'getlocalename_l*.c' -o -name 'getlocalename_l*.h' \
                       -o -name 'setlocale_null*.c' \) 2>/dev/null); do
      sed -i 's/extern char \* *getlocalename_l/extern const char *getlocalename_l/;s/^char \* *getlocalename_l/const char *getlocalename_l/' "$f" || true
    done
  '';

  # feature-test macros: expose strcasecmp/POSIX syms hidden behind
  # __EXTENSIONS__ / _XOPEN_SOURCE on Solaris libc.
  illumosExtFlags = "-D__EXTENSIONS__ -D_XOPEN_SOURCE=600 -D_XOPEN_SOURCE_EXTENDED=1";

  # socket/name-service split libc: socket() is in -lsocket, gethostbyname() in
  # -lnsl (illumos split them out of libc). Anything doing sockets/resolver
  # needs these appended to the link. Mirrors the many `-lnsl -lsocket` entries
  # in packages.nix.
  socketLibs = "-lnsl -lsocket";

  # gcc-14 promoted several C89-era warnings to hard errors (implicit function
  # decls, incompatible pointer types). -fcommon placates multiple-def of
  # terminfo globals. Applied as a CFLAGS relaxation, not a source patch.
  gcc14Relax = "-fcommon -Wno-error=incompatible-pointer-types -Wno-error=implicit-function-declaration";

  # helper: append flags to env.NIX_CFLAGS_COMPILE (the wrapper-honored knob),
  # preserving anything upstream already set.
  addCFlags = old: extra:
    { env = (old.env or { }) // {
        NIX_CFLAGS_COMPILE =
          lib.concatStringsSep " "
            (lib.filter (s: s != "")
              [ (old.env.NIX_CFLAGS_COMPILE or "") extra ]);
      };
    };

  # helper: append to NIX_LDFLAGS (link-time libs like -lnsl -lsocket).
  addLdFlags = old: extra:
    { env = (old.env or { }) // {
        NIX_LDFLAGS =
          lib.concatStringsSep " "
            (lib.filter (s: s != "")
              [ (old.env.NIX_LDFLAGS or "") extra ]);
      };
    };

  # H7 helper: point libtool's NM at the GNU-format nm. Solaris /usr/bin/nm has
  # an output format libtool's configure `global_symbol_pipe` probe cannot
  # parse -> empty symbol list -> `nm ... | | sed` syntax error at link. gnm
  # (GNU binutils nm, seed-sourced via the stdenv `illumosGnm` slice) emits the
  # `<addr> T <sym>` format libtool expects. Set both NM (configure reads it)
  # and export it into the environment so the generated libtool honours it.
  gnm = "${final.illumosGnm or (throw "illumosGnm not in package set")}/bin/gnm";
  withGnm = old:
    { NM = gnm;
      preConfigure = (old.preConfigure or "") + ''
        export NM=${gnm}
      '';
    };

  # H10 (tranche 5): drop obsolete/non-applying patches by basename. nixpkgs
  # adds patches that no longer apply to a newer upstream (e.g. perl's
  # ld-shared.patch targets hints/solaris_2.sh at a context 5.42.0 rewrote).
  dropPatchesNamed = names: old:
    { patches = builtins.filter
        (p: !(builtins.elem (baseNameOf (toString p)) names))
        (old.patches or []); };

  # H10+H11 perl fix as a single overrideAttrs function (drop dead ld-shared
  # patch + add libm/socket libs to the link). Reused on the perl5 base recipe
  # AND the top-level perl so all `.override` variants inherit it.
  perlFix = old:
    (dropPatchesNamed [ "ld-shared.patch" ] old)
    // (addLdFlags old "-lm ${socketLibs}");

  # H15 (tranche 6): the top-level `bzip2` is the stdenv bootstrap SEED slice
  # (single-output, NO dev), and the final stdenv stage re-pins it via
  # `inherit (prevStage) ... bzip2` so a top-level overlay cannot replace it.
  # Build the REAL multi-output nixpkgs bzip2 (bin/dev/out/man, autoreconfHook)
  # under a distinct name and thread its dev/out into the packages that read
  # `pkgs.bzip2.dev` -- notably the Compress-Raw-Bzip2 perl module (git/wget
  # -> libwww -> HTTP-Message). Only on illumos.
  bzip2Real = final.callPackage
    (forkPath + "/pkgs/tools/compression/bzip2/default.nix")
    { };

  # xzReal (Gap 2): the top-level `xz` is the stdenv bootstrap SEED slice (a
  # single binary from usr/gnu/bin/xz, NO headers/lib), and the final stdenv
  # re-pins it via `inherit (prevStage) ... xz`, so consumers that need
  # lzma.h + liblzma.so + the .pc (notably CPython's _lzma module) fail. Build
  # the REAL multi-output nixpkgs xz (bin/dev/lib/man, carries lzma.h and
  # liblzma.so + liblzma.pc) under a distinct name and thread it into python3
  # (see fixPy in tranche-entry-224.nix). Only on illumos.
  xzReal = (final.callPackage
    (forkPath + "/pkgs/by-name/xz/xz/package.nix")
    { }).overrideAttrs (o: {
      # xz's package.nix pins preConfigure = "CONFIG_SHELL=/bin/sh". On illumos
      # /bin/sh is ksh, whose builtin `print` makes libtool's echo probe bake
      # ECHO='print -r --' into the generated libtool; the actual compile rules
      # then run under bash (no `print`) -> `libtool: print: command not found`
      # and every liblzma .lo fails. Point CONFIG_SHELL at the build bash so the
      # libtool echo probe picks a POSIX echo. Unblocks xzReal -> python3 _lzma
      # -> the meson/ninja/doxygen swath.
      preConfigure = "CONFIG_SHELL=${final.stdenv.shell}";
    });

  # illumos-extra-syslibs: a REAL derivation (rebuildable + substitutable on any
  # host), NOT a nix-store --add'd FOD. It assembles the versioned illumos
  # system libs (libmd/libmp/libuutil/libnvpair/libidmap/libavl/libsec + their
  # bare `.so -> .so.N` link-editor links) by slicing them out of the seed via
  # the stdenv's `seedSyslibs` slice (illumos-seed-syslibs), which itself is
  # seed-sourced + host-free. Those libs are exactly the set CMake's hermetic
  # find_library(NAMES <n>) needs (cmlibarchive's LIBMD_LIBRARY probe) and the
  # -l<name> autotools/gettext link lines reference; the seed already carries
  # them under usr/gnu/lib/amd64 (the ldd-closure of the GNU userland), so no
  # host /lib ref is needed.
  #
  # libkstat/libsendfile are illumos BASE-PLATFORM libs (they live in the
  # platform /lib/amd64, part of the stable ABI like libc/libm -- never a
  # from-source Nix build). They are not in the seed slice, so a bare
  # `libkstat.so -> /lib/amd64/libkstat.so.1` link is added for the link-editor
  # `-l` probe (cmake's bundled libuv links -lkstat -lsendfile); the runtime
  # loader resolves the platform .so.1 the same class as libc-family, so the
  # closure stays host-free (the link target is a platform path, not a store
  # dep). Consumers wire it via NIX_CFLAGS_COMPILE -L (the H1 cc-wrapper pass
  # auto-adds the matching -R).
  extraSyslibs = final.runCommand "illumos-extra-syslibs" { } ''
    mkdir -p "$out/lib/amd64"
    # seed-sourced versioned syslibs + their bare .so links (host-free).
    for f in ${final.seedSyslibs}/lib/amd64/*; do
      ln -s "$f" "$out/lib/amd64/$(basename "$f")"
    done
    # base-platform link-editor stubs for the libs the seed slice lacks
    # (platform ABI at /lib/amd64, resolved at runtime like libc).
    for n in libkstat libsendfile libproc libcontract; do
      [ -e "/lib/amd64/$n.so.1" ] && ln -sf "/lib/amd64/$n.so.1" "$out/lib/amd64/$n.so"
    done
    # bare libm.so link for `-lm` / find_library(NAMES m): the seed slice carries
    # only libm.so.2 (no bare .so), so link-editor -lm probes miss it. Point a
    # bare .so at the platform libm (libc-family ABI, resolved at runtime).
    [ -e "/lib/amd64/libm.so.2" ] && ln -sf "/lib/amd64/libm.so.2" "$out/lib/amd64/libm.so"
  '';


  # ---- merged Lineage-B helper (GATE 2 withGnmPipe) --------------------
  # GATE 2 helper (withGnmPipe): libtool's configure probe for
  # lt_cv_sys_global_symbol_pipe parses the OUTPUT of the Solaris /usr/bin/nm,
  # which libtool cannot match -> the cache var comes out EMPTY. At .la link
  # time libtool's export_symbols_cmds runs
  #   $NM $libobjs | $global_symbol_pipe | $SED 's/.* //' | sort | uniq > $exp
  # so with an EMPTY pipe it becomes `nm ... |  | sed` -> `syntax error near
  # unexpected token |`. NM=gnm alone does NOT fix it (the empty PROBE result
  # is cached before NM is consulted). The correct value is a PURE FILTER that
  # reads gnm's output on stdin (libtool already prepends `$NM $libobjs`, and
  # NM=gnm here) -- it must NOT re-invoke nm/`gnm -B $lib`, else the object
  # stream is piped into a second nm that reads the wrong input and yields an
  # EMPTY .exp (dropping the lib's exported symbols -> `ld: undefined symbol`
  # in every consumer tool). Set both NM=gnm and the pure Solaris-ELF sed
  # filter. Systemic TLS/i18n blocker: libidn/gsasl and any package whose .la
  # link builds an export-symbols list.
  withGnmPipe = old:
    { NM = gnm;
      preConfigure = (old.preConfigure or "") + ''
        export NM=${gnm}
        export lt_cv_sys_global_symbol_pipe="sed -n -e 's/^.*[	 ]\([ABCDGIRSTW][ABCDGIRSTW]*\)[	 ][	 ]*\([_A-Za-z][_A-Za-z0-9]*\)$/\1 \2/p'"
      '';
    };

in
{
  # Expose the header-ful bzip2/xz so downstream tranche overlays (fixPy in
  # tranche-entry-224.nix) can thread them into python3 for _bz2/_lzma (Gap 2).
  inherit bzip2Real xzReal;

  # gnu-config: its config.guess/config.sub come from `fetchurl` against
  # git.savannah.gnu.org, which is unreachable from illumos build hosts (every
  # cgit endpoint times out). The fetchurl-shim turns that into an eval-time
  # `builtins.fetchurl` that hangs the whole evaluation. The two scripts are
  # content-addressed FODs already seeded into the store from cache.nixos.org
  # (identical hash regardless of source): vq0j27nv config.guess-948ae97,
  # 1p61qjvl config.sub-948ae97. Point gnu-config's sources at those store paths
  # so eval never touches savannah. updateAutotoolsGnuConfigScriptsHook (pulled
  # by every autotools package) needs this.
  gnu-config = onSolaris prev.gnu-config (old: {
    unpackPhase = ''
      runHook preUnpack
      cp ${configGuessSrc} ./config.guess
      cp ${configSubSrc} ./config.sub
      chmod +w ./config.sub ./config.guess
      runHook postUnpack
    '';
  });

  # rhash (a cmake build-dep on illumos): its non-autotools configure detects
  # the target OS by splitting --target on '-' and matching field 2/3. This
  # stdenv's hostPlatform.config is `x86_64-unknown-solaris` (no `2.11` suffix),
  # so field 3 = `solaris` matches neither `sunos` nor `solaris2.*` in
  # set_target_os -> `Unknown target OS` die. Add a bare `solaris)` alt to that
  # case line. Unblocks the full `cmake` (4.x) -> every cmake C/C++ lib that
  # pulls `cmake` (not cmakeMinimal): pugixml/tinyxml2/rapidjson/cereal/...
  # plotutils: plotter.h unconditionally #includes X11/Xlib.h unless configured
  # --without-x. No X11 on this headless illumos port, so build the non-X
  # libplot/graph/plot tools only.
  plotutils = onSolaris prev.plotutils (old: {
    configureFlags = (old.configureFlags or [ ]) ++ [ "--without-x" ];
  });

  # nlohmann_json / yaml-cpp: their CMake test harness (JSON_BuildTests /
  # YAML_CPP_BUILD_TESTS) runs execute_process/find_program probes that shell
  # out via posix_spawn -> SIGSYS on this illumos kernel. Header-only libs; the
  # tests are not the deliverable. Disable the test build so no spawn happens.
  nlohmann_json = onSolaris prev.nlohmann_json (old: {
    doCheck = false;
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DJSON_BuildTests=OFF" ];
  });

  yaml-cpp = onSolaris prev.yaml-cpp (old: {
    doCheck = false;
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DYAML_CPP_BUILD_TESTS=OFF" ];
  });

  rhash = onSolaris prev.rhash (old: {
    postPatch = (old.postPatch or "") + ''
      sed -i 's/sunos|solaris2[.]\*)/sunos|solaris|solaris2.*)/' configure
    '';
  });

  # ======================================================================
  # KNOWN-FIX packages. Keyed by nixpkgs attr (the CLASS A/B target from
  # nixpkgs-map.tsv). ~18 entries seeded from documented wave findings.
  # ======================================================================

  # --- pkg-config bundled glib: res_query needs -lresolv (illumos) ------
  # pkg-config --with-internal-glib runs a sub-configure for glib; glib probes
  # AC_CHECK_LIB(resolv, res_query). On illumos res_query lives in libresolv
  # (and needs the split socket/name-service libs), so the probe fails
  # `res_query: not found` and aborts `./configure failed for glib`. Thread
  # the resolver + split libc libs into the link. (H1 already lets the earlier
  # conftests exec; this is the separate resolver-lib gap behind it.)
  # The `pkg-config` attr is a THIN WRAPPER (pkg-config-wrapper); the real
  # glib-based build is `pkg-config-unwrapped`. Overrides for the actual
  # compile/link (resolver libs, glib -lthread) must land on the unwrapped one.
  pkg-config-unwrapped = onSolaris prev.pkg-config-unwrapped (old:
    (addLdFlags old "-lresolv ${socketLibs}") // {
      # H6c: pkg-config's bundled glib configure emits `-lthread` on Solaris
      # (G_THREAD_LIBS). On modern illumos libthread was folded into libc and
      # there is no standalone libthread.so; the pthread symbols are already
      # pulled via -lpthread/libc, so -lthread is redundant. Strip it from the
      # generated glib build files (a libthread.so shim SONAME-conflicts with
      # libpthread). Also collapse the duplicate libiconv.so the auto-runpath
      # re-adds (illumos ld makes a repeated shared-object inclusion fatal).
      # glib's configure sets G_THREAD_LIBS="-lpthread -lthread" on Solaris
      # (a Sun Studio -mt relic). The bundled glib is sub-configured DURING
      # make, so patch its configure source up front: keep -lpthread, drop the
      # redundant -lthread (folded into libc on illumos; no standalone
      # libthread.so, and a shim SONAME-conflicts with libpthread).
      postPatch = (old.postPatch or "") + ''
        # Patch only the GENERATED configure (touching configure.ac would
        # trip maintainer-mode autoreconf, which the seed lacks). touch after
        # so it stays newer than configure.ac.
        if [ -e glib/configure ]; then
          sed -i 's/-lpthread -lthread/-lpthread/g' glib/configure
          touch glib/configure
        fi
      '';
    });

  # --- socket/name-service split (-lnsl -lsocket) -----------------------
  # curl: does sockets + resolver; needs the split libc libs.
  # H29 (tranche 6): curl's `gssSupport` (default true on unix) pulls libkrb5,
  # which has an unresolved illumos C port bug in addr.c (s6_addr macro clash).
  # GSSAPI/Kerberos is optional for curl; disable it so curl builds without
  # krb5. Same for curlMinimal (git's libcurl). `.override` for the arg, then
  # the socket-lib overrideAttrs. Unblocks curl -> git.
  curl = if isSolaris
    then (prev.curl.override { gssSupport = false; })
           .overrideAttrs (old: addLdFlags old socketLibs // { LIBS = socketLibs; } // withGnm old)
    else prev.curl;
  curlMinimal = if isSolaris
    then (prev.curlMinimal.override { gssSupport = false; })
           .overrideAttrs (old: addLdFlags old socketLibs // { LIBS = socketLibs; } // withGnm old)
    else prev.curlMinimal;

  # H28 (tranche 6): krb5 declares `libFolders = [ "util" ... ]` and uses it as
  # a bash ARRAY in postConfigure (`find "${libFolders[@]}"`). That array only
  # materialises under structuredAttrs; with __structuredAttrs = false (this
  # whole port) `libFolders` becomes one space-joined string, so
  # `"${libFolders[@]}"` is a single arg -> `find: 'util include lib
  # build-tools': No such file`. Redefine it as a real bash array at the top of
  # postConfigure. Unblocks krb5 -> curl/curlMinimal.
  krb5 = onSolaris prev.krb5 (old: {
    postConfigure = ''
      libFolders=(util include lib build-tools)
    '' + (old.postConfigure or "");
  });

  # H27 (tranche 6): libedit (pulled by openssh + krb5) includes ncurses'
  # <termcap.h>, which declares tgetstr/tgetflag/tgetnum with `const char *`
  # args, while illumos' own <term.h>/<termcap.h> (on the default include path)
  # declare them with plain `char *` -> `conflicting types` hard error. ncurses'
  # termcap.h guards those redeclarations behind `#if !defined(NCURSES_TERM_H_incl)`;
  # define that macro so ncurses skips them and only illumos' decls remain
  # (libedit passes char*, so the non-const prototypes are fine). Unblocks
  # openssh + krb5. Only on illumos.
  libedit = onSolaris prev.libedit (old:
    addCFlags old "-DNCURSES_TERM_H_incl=1");

  # H31 (tranche 6): libxslt links xsltproc against a `libxslt.syms` version
  # script that exports `xslHandleDebugger`/`xsltSetDebuggerCallbacks`, but
  # those are only compiled when the XSLT debugger is enabled. With it off the
  # symbols are undefined and the native Solaris ld treats a version-script
  # symbol with no definition as fatal (`ld: fatal: symbol referencing
  # errors`). Enable the debugger so the symbols exist. (cf. H8/H12: GNU
  # version-script vs Solaris ld on a fresh port.)
  libxslt = onSolaris prev.libxslt (old: {
    configureFlags = (old.configureFlags or []) ++ [ "--with-debugger" ];
  });

  # H24 (tranche 6): byacc hardcodes `doCheck = true` and its in-tree test
  # suite (btyacc varsyntax cases) fails on illumos. byacc is a build tool for
  # krb5 (-> curl/cmake). The generator itself works; skip its test suite.
  byacc = onSolaris prev.byacc (old: { doCheck = false; });

  # H25 (tranche 6): nghttp2's `enableApp` (default true off-Windows) builds the
  # C++ nghttpx/nghttp tools, whose network.h uses std::variant/Sockaddr and
  # fails to compile on illumos (C++17 + BSD-sockaddr assumptions). curl only
  # needs the libnghttp2 C library; build just that. `.override` for the arg.
  nghttp2 = if isSolaris then prev.nghttp2.override { enableApp = false; } else prev.nghttp2;

  # H15b (tranche 6): `unzip` compiles with -DUSE_BZIP2 and includes bzlib.h
  # from its `bzip2` buildInput -- which is the dev-less seed slice, so it fails
  # `bzlib.h: No such file or directory`. unzip is pulled as a build tool by
  # sqlite (test data) and by fetchzip's postFetch (libxml2/libxslt/... source
  # unpack). Swap its bzip2 buildInputs for the real multi-output bzip2 so the
  # header resolves. (Only the buildInput; the seed bzip2 stays elsewhere.)
  unzip = onSolaris prev.unzip (old: {
    nativeBuildInputs = [ bzip2Real ];
    buildInputs = [ bzip2Real ] ++ builtins.filter
      (b: (b.pname or b.name or "") != "bzip2") (old.buildInputs or []);
  });

  # H23 (tranche 6): gnutls (pulled by gnupg) sets doCheck true on illumos
  # (build==host), and its check inputs include `net-tools`, whose unixtools
  # splice eval hits an infinite recursion in this nixpkgs vintage. The test
  # suite is not the deliverable on a fresh port; disable doCheck so net-tools
  # is never pulled. Unblocks gnupg -> gnutls.
  gnutls = onSolaris prev.gnutls (old: { doCheck = false; }
    // (withGnm old)
    // {
      # gnutls' bundled libtool is regenerated by autoreconf AFTER preConfigure,
      # losing the NM export -> the main-dir libtool probes bare Solaris `nm`
      # (empty global_symbol_pipe -> `nm | | sed` syntax error linking
      # libgnutls.la). Pass NM as a configure variable so config.status bakes
      # the GNU-format nm into every generated libtool, including the recursion.
      configureFlags = (old.configureFlags or []) ++ [ "NM=${gnm}" ];
    });

  # H48 (wave 8): the pkg-config-wrapper setup-hook ships an UNSUBSTITUTED
  # placeholder -- `export PKG_CONFIG=@targetPrefix@@baseBinName@` -- because
  # makeSetupHook's substitution did not replace @targetPrefix@/@baseBinName@
  # on this fork. Every strictDeps consumer then reads PKG_CONFIG as the
  # literal string, `@targetPrefix@@baseBinName@: command not found`, and its
  # configure concludes "pkg-config not found" (blocks gnutls -> gnupg, the
  # postgres lz4/zstd probes, flac's graphviz dep, memcached's sasl dep, ...).
  # For a native build targetPrefix="" and baseBinName="pkg-config", so patch
  # the installed setup-hook to export the real binary name. Broad unblock.
  pkg-config = onSolaris prev.pkg-config (old: {
    postFixup = (old.postFixup or "") + ''
      for h in $out/nix-support/setup-hook; do
        [ -f "$h" ] || continue
        sed -i 's/@targetPrefix@@baseBinName@/pkg-config/g' "$h"
      done
    '';
  });

  # H49 (wave 8): libusb1's withDocs defaults true (build==host), pulling
  # doxygen -- which fails to compile on illumos (`-fno-fat-lto-objects are
  # supported only with linker plugin`; gcc LTO needs a linker plugin the seed
  # ld lacks). API docs are optional; disable them so doxygen is never built.
  # Unblocks gnupg (scdaemon -> libusb1) and any other libusb1 consumer.
  libusb1 = if isSolaris then prev.libusb1.override { withDocs = false; } else prev.libusb1;

  # H46 (wave 8): libgcrypt 1.12.2 builds + links clean on illumos, but its
  # `make check` suite trips (`gcrypt: No such file or directory` in
  # check-TESTS -- a test harness path assumption). The library is the
  # deliverable and is already cached at a prior hash; skip the test suite on
  # this fresh rebuild (same policy as openssl/gnutls). Unblocks gnupg.
  libgcrypt = onSolaris prev.libgcrypt (old: { doCheck = false; });

  # H20 (tranche 6): git's `rustSupport` defaults to
  # `lib.meta.availableOn hostPlatform rustc` (true), pulling cargo -> cargo-
  # bootstrap -> an LLVM `bintools` that is not ported (`bintools-wrapper`
  # assertion: coreutils/gnugrep null). Rust is optional for git (a couple of
  # experimental builtins); disable it on a fresh illumos port. `.override`
  # (not overrideAttrs) since rustSupport is a package-function arg.
  # H32 (tranche 6): git wants cmake transitively -- via `zlib-ng` (built with
  # cmake) and the sendEmail perl modules (IO-Socket-SSL/Net-SMTP-SSL pull cmake
  # through their check deps). cmake is blocked on illumos (H26, -lkstat/
  # -lsendfile seed gap). Drop sendEmail, and swap the hardcoded zlib-ng for
  # plain zlib (cmake-free) + drop the ZLIB_NG makeflag. Also rustSupport off
  # (H20), curlMinimal (avoid brotli->cmake), no manual/python (man-db/python3
  # -> cmake). Lands git on illumos without cmake.
  git = if isSolaris then (prev.git.override {
    rustSupport = false; curl = final.curlMinimal; withManual = false;
    pythonSupport = false; sendEmailSupport = false;
  }).overrideAttrs (old: {
    buildInputs = builtins.filter
      (b: (b.pname or b.name or "") != "zlib-ng") (old.buildInputs or [])
      ++ [ final.zlib ];
    # H35: with NO_TCLTK the gitk/git-gui progs are never built, but git's
    # guiSupport=false postInstall does a bare `rm "$out/$prog"` on them ->
    # `rm: cannot remove .../gitk: No such file`. Make the rm tolerant.
    postInstall = builtins.replaceStrings
      [ ''rm "$out/$prog"'' ] [ ''rm -f "$out/$prog"'' ]
      (old.postInstall or "");
    # H36: git's install-time test suite (thousands of cases) is not the
    # deliverable on a fresh port and hits illumos-specific fs/net cases; the
    # binary is already built + installed. Skip installCheck.
    doInstallCheck = false;
    makeFlags = builtins.filter (f: f != "ZLIB_NG=1") (old.makeFlags or [])
      # H33: git's final link leaves libintl_gettext/bindtextdomain/... undefined
      # -- gettext's -lintl is not on the link line and NIX_LDFLAGS is bypassed
      # on illumos (gcc execs host ld, H1). git i18n is optional; build with
      # NO_GETTEXT=1 so it uses the built-in no-op gettext and drops -lintl.
      # H34: the git-gui/templates subdir Makefiles recurse via `$(MAKE)`, which
      # GNU make expands to the bare name `make`; in the sub-shell PATH the
      # Solaris `/usr/bin/make` shadows the seed gnumake, and it chokes on git's
      # GNU-make `shared.mak` (`Fatal error in reader: Unexpected end of line`).
      # Pin MAKE to the absolute gnumake path so every recursion stays GNU make;
      # NO_TCLTK=1 also drops the optional git-gui.
      ++ [ "NO_GETTEXT=1" "NO_TCLTK=1" "MAKE=${final.gnumake}/bin/make" ];
  }) else prev.git;

  # H22 (tranche 6): htop's `systemdSupport ? lib.meta.availableOn hostPlatform
  # systemdLibs` (and `sensorsSupport`) force evaluation of systemd/lm_sensors
  # -> llvmPackages.clang -> the unported LLVM bintools (assertion). A plain
  # `.override { systemdSupport = false; }` does NOT suppress it: htop is a
  # spliced-pkgset value, and the splice recomputes the arg DEFAULTS (the
  # availableOn call) before the override merge. Bypass the splice entirely by
  # callPackage-ing htop's package.nix with explicit false/null args, so
  # availableOn/systemd/lm_sensors are never touched. htop dlopen's what it
  # needs at runtime. Only on illumos.
  htop = if isSolaris
    then (final.callPackage
      (forkPath + "/pkgs/by-name/ht/htop/package.nix")
      { systemdSupport = false; systemdLibs = null; sensorsSupport = false; lm_sensors = null; })
      .overrideAttrs (old:
        # H26b: htop configure needs kstat_open() -> -lkstat, from extraSyslibs.
        addCFlags old "-L${extraSyslibs}/lib/amd64")
    else prev.htop;

  # wget: resolver + sockets.
  wget = onSolaris prev.wget (old: addLdFlags old socketLibs);

  # openssh / socket clients: gethostbyname + socket.
  # H21 (tranche 6): withFIDO/withSecurityKey default true on unix, pulling
  # libfido2 -> udev-check-hook -> udevadm (a Linux/systemd path that drags in
  # the unported LLVM bintools -> assertion). FIDO/U2F is optional; disable it
  # on illumos. `.override` for the package-function args, then the socket-lib
  # overrideAttrs on top.
  openssh = if isSolaris
    then (prev.openssh.override { withFIDO = false; withSecurityKey = false; })
           .overrideAttrs (old: addLdFlags old "${socketLibs} -lresolv" // {
             # H30: openssh's check phase pulls `libredirect`, which fails to
             # compile on illumos (`sys/xattr.h: No such file` -- a Linux-only
             # header). The test harness is not the deliverable on a fresh
             # port; disable checks so libredirect is never built.
             doCheck = false;
             doInstallCheck = false;
             # libredirect is still referenced via nativeCheckInputs even with
             # doCheck off in this nixpkgs vintage; drop the check inputs so the
             # unbuildable libredirect (sys/xattr.h) never enters the closure.
             nativeCheckInputs = [];
             # openssh's preCheck string interpolates ${libredirect}/lib/...
             # directly, so even with doCheck off libredirect stays in the
             # closure -- and it won't compile on illumos. Blank the preCheck.
             preCheck = "";
           })
    else prev.openssh;

  # rsync, socat, netcat-family: raw sockets.
  rsync = onSolaris prev.rsync (old: addLdFlags old socketLibs);
  socat = onSolaris prev.socat (old: addLdFlags old socketLibs);
  # whois: getservbyname/gethostbyname live in the split libc (-lsocket -lnsl).
  whois = onSolaris prev.whois (old: addLdFlags old socketLibs);

  # mkpasswd (built from the whois src): config.h auto-defines
  # HAVE_SOLARIS_CRYPT_GENSALT for `__SVR4 && __sun`, whose crypt_gensalt is the
  # 2-arg Solaris-native form — but we link libxcrypt (the 4-arg Linux form), so
  # mkpasswd.c's Solaris branch fails `too few arguments to crypt_gensalt`. We
  # use libxcrypt, so flip config.h to the Linux path (+ split-libc socket libs
  # for the shared whois objects mkpasswd links).
  mkpasswd = onSolaris prev.mkpasswd (old: addLdFlags old socketLibs // {
    postPatch = (old.postPatch or "") + ''
      sed -i 's/# define HAVE_SOLARIS_CRYPT_GENSALT/# define HAVE_LINUX_CRYPT_GENSALT/' config.h
    '';
  });

  # tmux / smartmontools: both default a buildInput on
  # `lib.meta.availableOn stdenv.hostPlatform systemdLibs`, which FORCES eval of
  # the illumos `systemdLibs` derivation — that throws the cc/bintools-wrapper
  # `bintools != null` assertion (systemd's stdenv variant has a null bintools
  # on this fork), aborting eval before availableOn can return false. systemd is
  # Linux-only, so cut it: tmux via its `withSystemd`/`withUtempter` args (never
  # evaluates systemdLibs), smartmontools by nulling the conditional buildInput.
  tmux = onSolaris (prev.tmux.override { withSystemd = false; withUtempter = false; }) (old:
    addLdFlags old socketLibs);
  smartmontools = onSolaris prev.smartmontools (old: {
    buildInputs = [ ];
  });

  # hostname-debian (a smartmontools drivedb-fetch build-dep): gethostbyname/
  # getnameinfo (-lsocket -lnsl) AND hstrerror (-lresolv) live in the illumos
  # split libc/resolver.
  hostname-debian = onSolaris prev.hostname-debian (old: addLdFlags old "${socketLibs} -lresolv");

  # screen: hardcodes --enable-pam + a `pam` buildInput; nixpkgs `openpam` fails
  # to compile on illumos (PATH_MAX undeclared without <limits.h>). illumos has
  # native PAM but the build doesn't need it — drop PAM (screen still is the
  # terminal multiplexer, the parity function). Remove --enable-pam + the pam
  # buildInput.
  screen = onSolaris prev.screen (old: withGnm old // {
    configureFlags = builtins.filter (f: f != "--enable-pam") (old.configureFlags or [ ]);
    buildInputs = builtins.filter
      (b: let n = b.pname or b.name or ""; in n != "openpam" && n != "pam" && !(lib.hasInfix "pam" n))
      (old.buildInputs or [ ]);
  });

  # dos2unix: upstream waterlan.home.xs4all.nl now serves an HTML error page for
  # the 7.5.5 tarball (dead host). Point src at the sourceforge mirror — verified
  # to hash-match the genuine nixpkgs 7.5.5 SRI. Also disable NLS: dos2unix's
  # bundled gettext emits libintl_gettext/_textdomain/_bindtextdomain calls, but
  # illumos libc provides native gettext (plain names) with no libintl_* symbols
  # -> undefined at link. The parity role (line-ending conversion) needs no NLS.
  dos2unix = onSolaris prev.dos2unix (old: {
    src = final.fetchurl {
      url = "https://downloads.sourceforge.net/project/dos2unix/dos2unix/7.5.5/dos2unix-7.5.5.tar.gz";
      sha256 = "sha256-dfaSuEhMjCRXmi/9h98WuclCjtlUl+M5OiHRugaXrDM=";
    };
    makeFlags = (old.makeFlags or [ ]) ++ [ "ENABLE_NLS=" ];
    # Drop the gettext buildInput: its libintl.h uses `_INTL_ASM(libintl_*)`
    # (asm symbol-rename) that illumos gcc rejects (`expected identifier before
    # __asm__`), and with NLS off the header is not needed anyway.
    buildInputs = builtins.filter
      (b: (b.pname or b.name or "") != "gettext") (old.buildInputs or [ ]);
    nativeBuildInputs = builtins.filter
      (b: (b.pname or b.name or "") != "gettext") (old.nativeBuildInputs or [ ]);
  });

  # w3m: the parity role is the text browser for the manual — no graphics/X11.
  # graphicsSupport defaults on (!isDarwin) and drags imlib2 -> freetype-2.14.3,
  # whose only src is download.savannah.gnu.org (502 from illumos). Drop
  # graphics + X11: text w3m still browses the manual, and the freetype/imlib2/
  # libx11 chain (+ the 502) is gone. Also point its `man` input (w3m's runtime
  # MAN env) at the built mandoc instead of man-db: man-db's build needs groff,
  # which dies `troff: Bad system call` on illumos. mandoc is the solnix manual
  # renderer anyway (host-free, in the registry).
  w3m = onSolaris (prev.w3m.override {
    graphicsSupport = false;
    x11Support = false;
    man = final.mandoc;
  }) (old: addLdFlags old socketLibs);

  # --- gnulib const-qualify (GNU coreutils / textutils family) ----------
  coreutils = onSolaris prev.coreutils (old:
    { postPatch = (old.postPatch or "") + gnulibFix; });
  gnugrep = onSolaris prev.gnugrep (old:
    { postPatch = (old.postPatch or "") + gnulibFix; });
  gnused = onSolaris prev.gnused (old:
    { postPatch = (old.postPatch or "") + gnulibFix; });
  gawk = onSolaris prev.gawk (old:
    { postPatch = (old.postPatch or "") + gnulibFix; });
  diffutils = onSolaris prev.diffutils (old:
    { postPatch = (old.postPatch or "") + gnulibFix; });
  gettext = onSolaris prev.gettext (old:
    { postPatch = (old.postPatch or "") + gnulibFix;
      # H7: gettext builds libintl.so via libtool -> needs the GNU-format nm.
      # (Previously this entry pinned LDFLAGS=-lm to dodge the H6 seed-lib gap;
      # H6 is now fixed in the stdenv -- the seedSyslibs -L makes -lmd -lmp
      # -lnvpair -luutil -lidmap -lavl -lsec resolve -- so the blanket illumos
      # LDFLAGS from upstream gettext/default.nix links cleanly and the pin is
      # dropped.)
    } // withGnm old);

  # --- PS-GLIB: make GNU gettext WIN over the seed libintl -----------------
  # The stdenv cc-wrapper bakes `-L${seedSyslibs}/lib/amd64` into cc-cflags,
  # which the wrapper PREPENDS into NIX_CFLAGS_COMPILE (add-flags.sh) -> it
  # lands in `extraAfter`, on the gcc line ahead of any buildInput -L. That
  # seed slice carries `libintl.so -> usr/gnu/lib/amd64/libintl.so.1`, the
  # illumos GNU-userland libintl, which exports PLAIN `gettext` and NO
  # `libintl_gettext`. GNU gettext's own libintl.so.8 exports `libintl_gettext`
  # and its <libintl.h> macro-renames gettext -> libintl_gettext. glib includes
  # that header (ggettext.c) and calls libintl_gettext, but `-lintl` resolves to
  # the SEED libintl first -> `libintl_gettext` UNDEFINED at link.
  #
  # FIX (targeted, no stage0 rebuild): put GNU gettext's -L and -isystem on
  # NIX_CFLAGS_COMPILE_BEFORE. The wrapper routes *_BEFORE into `extraBefore`,
  # which precedes both the user params AND extraAfter (the seed -L) on the gcc
  # command line -> gcc's left-to-right -L search finds GNU libintl.so.8 first,
  # and the matching -isystem puts GNU <libintl.h> ahead of the seed include so
  # header and lib agree (both libintl_gettext). Also thread the illumos socket/
  # resolver libs: gio's DNS code links res_query/gethostbyname (H1 bypasses
  # NIX_LDFLAGS on the compile+link one-shots, so -l<...> also rides on _BEFORE).
  #
  # Introspection + documentation are dropped: withIntrospection pulls
  # gobject-introspection (a glib consumer -> bootstrap cycle) and -Ddocumentation
  # pulls gi-docgen + a large python3.14 sphinx/pytest/babel docs chain. Neither
  # is core to the GTK/font subtree the payoff needs; the shared libs + headers
  # are what harfbuzz/pango/graphene link against. sysprof is disabled too:
  # nixpkgs only guards `-Dsysprof=disabled` behind isFreeBSD, but its
  # libsysprof-capture buildInput is equally Linux-only (O_BINARY/byteswap.h/
  # mkostemp) and fails on illumos -- disable the option AND drop the buildInput.
  # xattr off: illumos has no Linux getxattr/attr/xattr.h. tests off: the test
  # helper getpwuid-preload.c wraps getpwnam_r/getpwuid_r as POSIX `int`, but
  # illumos declares the legacy `struct passwd *` form -> conflicting types.
  glib = onSolaris (prev.glib.override { withIntrospection = false; }) (old: {
    NIX_CFLAGS_COMPILE_BEFORE =
      (old.NIX_CFLAGS_COMPILE_BEFORE or "")
      + " -L${final.gettext}/lib -isystem ${final.gettext}/include"
      + " -lnsl -lsocket -lresolv";
    mesonFlags = (old.mesonFlags or [ ]) ++ [ "-Ddocumentation=false" "-Dsysprof=disabled" "-Dxattr=false" "-Dtests=false" ];
    buildInputs = builtins.filter
      (b: (b.pname or b.name or "") != "libsysprof-capture") (old.buildInputs or [ ]);
    # -Ddocumentation=false leaves the declared `devdoc` output unpopulated ->
    # "failed to produce output path". Drop it (the libs/dev/bin outputs stay).
    outputs = builtins.filter (o: o != "devdoc") (old.outputs or [ "out" ]);
  });

  # PS-GLIB payoff subtree. Build the CORE (glib -> harfbuzz, graphene) with
  # introspection OFF: withIntrospection pulls gobject-introspection, which
  # needs cairo -> the whole X11 graph (libx11/libxcb/libxrender), plus gtk-doc.
  # None of that is needed for the shared libs + headers downstream text/font
  # code links against. harfbuzz: withCairo already defaults false; keep it off.
  # doCheck off: harfbuzz's own test suite needs a python-env. withGraphite2 off:
  # graphite2 carries python3.withPackages(fonttools) + cmake in its
  # nativeBuildInputs (build-time, not just checks) -> the fonttools/pytest
  # python swath + the fork-unfixed cmake. The Graphite backend is an optional,
  # rarely-used shaper; HarfBuzz's OpenType core shapes without it.
  harfbuzz = onSolaris (prev.harfbuzz.override {
    withIntrospection = false;
    withGraphite2 = false;
  }) (old: { doCheck = false; });

  # zeromq: pulled by fontforge (-> dejavu_fonts -> fontconfig). libzmq.so links
  # fine, but the perf tools (bin/proxy_thr, benchmark_*) leave the illumos
  # socket calls (getsockname/accept/__xnet_bind/getaddrinfo) undefined -- the
  # -lnsl/-lsocket split libs are not on their link line. Thread socketLibs via
  # NIX_LDFLAGS (the correct illumos fix, applies to every link here).
  zeromq = onSolaris prev.zeromq (old: addLdFlags old socketLibs);

  # fontforge: pulled by dejavu_fonts -> fontconfig. Its FindMathLib.cmake does
  # check_function_exists(pow) with no -lm (illumos libm is separate, so pow is
  # NOT built-in -> MathLib_IS_BUILT_IN=FALSE), then find_library(NAMES m),
  # which under cmake's hermetic mode does not see the platform /lib/amd64/
  # libm.so -> MathLib_OK empty -> configure error. Pre-set MathLib_LIBRARIES to
  # the full store path of the extra-syslibs bare libm.so (a symlink to the
  # platform libm, host-free by the same convention as libkstat/libsendfile):
  # a full path skips find_library AND links cleanly (a bare `m` makes cmake
  # treat it as a target, `-lm` gets mangled to `../../-lm`).
  fontforge = onSolaris prev.fontforge (old:
    (addCFlags old "-L${extraSyslibs}/lib/amd64") // {
      cmakeFlags = (old.cmakeFlags or [ ]) ++ [
        "-DMathLib_LIBRARIES=${extraSyslibs}/lib/amd64/libm.so"
      ];
      # On startup fontforge writes $HOME/.config/fontforge. This host has no
      # build sandbox, so HOME=/homeless-shelter persists on the real FS and the
      # Nix builder's purity guard aborts any consumer build (dejavu_fonts runs
      # `#!/usr/bin/env fontforge` scripts). Wrap the binary to point HOME at a
      # per-invocation temp dir so nothing lands in /homeless-shelter.
      postInstall = (old.postInstall or "") + ''
        if [ -e "$out/bin/fontforge" ]; then
          mv "$out/bin/fontforge" "$out/bin/.fontforge-real"
          cat > "$out/bin/fontforge" <<EOF
#!${final.stdenv.shell}
export HOME="\''${TMPDIR:-/tmp}/fontforge-home"
mkdir -p "\$HOME"
exec "$out/bin/.fontforge-real" "\$@"
EOF
          chmod +x "$out/bin/fontforge"
        fi
      '';
    });

  # fontconfig: freetype+expat already build. Its configure's AM_PATH_PYTHON
  # probe returns "none" (its version-list search does not recognise python
  # 3.14) -- pin PYTHON to the interpreter so the search is skipped (3.14 >= 3
  # passes the min check). The xsltproc (libxslt.bin) the postInstall needs is
  # re-added in the tranche's post-stripDocs block. Unblocks cairo/pango.
  fontconfig = onSolaris prev.fontconfig (old: {
    PYTHON = "${final.python3}/bin/python3";
  });

  # cairo: drop the xlib/xcb backends (x11Support/xcbSupport off) so the libx11/
  # libxcb/libxrender/libxext X graph leaves the build -- cairo still renders to
  # image/PDF/PS/SVG surfaces (all pango needs). gobjectSupport stays on so
  # cairo-gobject is available to pango. Its deps (fontconfig/freetype/pixman/
  # glib) are all built. ctime_r fix: cairo's 2-arg fallback is skipped because
  # meson detects HAVE_CTIME_R, but illumos ctime_r is the 3-arg form
  # ctime_r(const time_t*, char*, int); patch the single 2-arg call in the PS
  # surface (ctime_buf is a fixed 26-byte buffer). Same pattern as libssh.
  cairo = onSolaris (prev.cairo.override {
    x11Support = false;
    xcbSupport = false;
  }) (old: {
    postPatch = (old.postPatch or "") + ''
      sed -i 's/ctime_r (&now, ctime_buf)/ctime_r (\&now, ctime_buf, 26)/' src/cairo-ps-surface.c
    '';
  });

  # pango: introspection off drops gi-docgen + gobject-introspection + the
  # devdoc output; x11Support off drops libxft -> the libx11/libxcb X graph.
  # pango still shapes/lays out text via harfbuzz + fontconfig + cairo (all
  # built) -- the Xft backend is only for legacy X font rendering.
  pango = onSolaris (prev.pango.override {
    withIntrospection = false;
    x11Support = false;
  }) (old: { });

  # graphene: pure SIMD geometry math -- no fonts/X. Introspection off drops
  # gobject-introspection + gtk-doc's cairo pull. graphene has no -Dtests option
  # (its meson always builds tests when mutest is present), so mutest is fixed
  # below rather than dropped. -D__EXTENSIONS__: graphene's meson probes for an
  # aligned-malloc (memalign/posix_memalign); illumos declares both in <stdlib.h>
  # only under the extension namespace, so the probes fail without it.
  graphene = onSolaris (prev.graphene.override {
    withIntrospection = false;
  }) (old: addCFlags old "-D__EXTENSIONS__");

  # mutest (graphene's test framework): update_term_size() uses struct winsize
  # / TIOCGWINSZ. On illumos both live in <sys/termios.h> behind
  # `!__XOPEN_OR_POSIX || __EXTENSIONS__`, and mutest only includes <sys/ioctl.h>
  # (which does NOT pull sys/termios.h here). Enable the extension namespace and
  # force-include the header so the tty-size probe sees the type + ioctl.
  mutest = onSolaris prev.mutest (old:
    addCFlags old "-D__EXTENSIONS__ -include sys/termios.h");

  # meson's installCheckPhase runs its full run_project_tests.py suite; 5 of
  # ~500 cases fail on illumos for host-harness reasons, not meson defects: `ld
  # --version` returncode probe (illumos ld exits nonzero on --version),
  # get_supported_function_arguments / constructor_priority (gcc-attr probes),
  # and a `FILE is in stdio.h` assert. The meson binary itself works (it drives
  # glib/pango/etc. fine). Tests are not the deliverable on a fresh port; drop
  # doInstallCheck so meson builds and unblocks the whole meson swath (glib ->
  # harfbuzz/pango/graphene).
  meson = onSolaris prev.meson (old: { doInstallCheck = false; installCheckPhase = "true"; });

  # --- BIND: strip Solaris -zrelax=transtls that illumos ld rejects -----
  # BIND's configure injects `-zrelax=transtls` into LDFLAGS on SunOS; illumos
  # ld ('ld: fatal: flags processing errors') doesn't accept it in the atomic
  # probe (artifacts/x86-wave42/failures.txt). Scrub it from the generated
  # build files before compiling; also thread the split libc libs.
  bind = onSolaris prev.bind (old:
    (addLdFlags old socketLibs) // {
      postPatch = (old.postPatch or "") + ''
        grep -rl -- '-zrelax=transtls' . 2>/dev/null | while read -r f; do
          sed -i 's/-zrelax=transtls//g' "$f" || true
        done
      '';
    });

  # --- libuv: errno.h shadow -include fix -------------------------------
  # illumos exposes a per-thread errno via a macro that shadows libuv's own
  # `int errno` uses; force-include <errno.h> first so the macro is defined
  # before libuv's translation units reference the symbol.
  libuv = onSolaris prev.libuv (old:
    addCFlags old "-include errno.h");

  # --- nvi: pre-standard u_int8_t typedefs ------------------------------
  # nvi assumes BSD u_intN_t typedefs; illumos <sys/types.h> only defines them
  # under __EXTENSIONS__. Define the u_intN_t names onto the C99 uintN_t types
  # (and enable __EXTENSIONS__) so nvi's headers compile.
  nvi = onSolaris prev.nvi (old:
    addCFlags old
      ("${illumosExtFlags} -Du_int8_t=uint8_t -Du_int16_t=uint16_t "
       + "-Du_int32_t=uint32_t -Du_int64_t=uint64_t"));

  # --- neovim: STREAMS `struct queue` collision -------------------------
  # illumos <sys/stream.h> (pulled in transitively) defines `struct queue`,
  # colliding with neovim's own `struct queue`. Rename neovim's type to
  # `nvim_queue` throughout the tree before building.
  neovim-unwrapped = onSolaris prev.neovim-unwrapped (old:
    { postPatch = (old.postPatch or "") + ''
        grep -rl --include='*.c' --include='*.h' -- 'struct queue' src 2>/dev/null | while read -r f; do
          sed -i 's/struct queue\b/struct nvim_queue/g' "$f" || true
        done
      '';
    });

  # --- H7 libtool NM: packages whose link step drives libtool (build a .so via
  # libtool -> global_symbol_pipe) need the GNU-format nm. -------------------
  libidn2 = onSolaris prev.libidn2 (old: withGnm old);
  libgpg-error = onSolaris prev.libgpg-error (old: withGnm old);
  # libpipeline (man-db dep, pulled by w3m/colordiff man-page install): its
  # libtool link hits the same empty global_symbol_pipe (`nm | | sed`). GNU nm.
  libpipeline = onSolaris prev.libpipeline (old: withGnm old);

  # H7 (tranche 5): more libtool-driven .so builds whose Solaris /usr/bin/nm
  # probe yields an empty global_symbol_pipe (`nm ... | | sed`). Route NM at the
  # GNU-format illumosGnm, same as tranche-3's libidn2/libgpg-error/gettext.
  libtasn1 = onSolaris prev.libtasn1 (old: withGnm old);
  libassuan = onSolaris prev.libassuan (old: withGnm old);
  npth = onSolaris prev.npth (old: withGnm old);
  libssh2 = onSolaris prev.libssh2 (old: withGnm old);

  # H7 (tranche 6): more libtool-driven .so builds needing GNU-format nm.
  # ldns (openssh's DNSSEC lib) links libldns.la with -export-symbols-regex,
  # tripping the empty Solaris-nm global_symbol_pipe.
  ldns = onSolaris prev.ldns (old: withGnm old);

  # gdbm: builds + links clean; its `make check` trips ONE flaky test
  # (`gdbm_close error`) on illumos (test harness assumes a close() errno
  # illumos reports differently). The library itself is fine, so skip the
  # in-tree test suite on this fresh port rather than patch the test.
  gdbm = onSolaris prev.gdbm (old: { doCheck = false; });

  # H9: gzipped patch decompression. `libpng` applies its apng patch as a
  # .gz via `gunzip`, which the pure seed stdenv does not carry on PATH ->
  # `gunzip: command not found` in patchPhase. Our gzip build only installs
  # `gzip` (the illumos gzip build skipped the gunzip/zcat wrapper symlinks),
  # so provide a `gunzip` (= `gzip -d`) shim on nativeBuildInputs. Any package
  # with gzipped patches needs this; promote to stdenv default if it recurs.
  libpng = onSolaris prev.libpng (old:
    { nativeBuildInputs = (old.nativeBuildInputs or []) ++ [
        (final.runCommand "gunzip-shim" { } ''
          mkdir -p $out/bin
          printf '#!/bin/sh\nexec %s/bin/gzip -d "$@"\n' ${final.gzip} > $out/bin/gunzip
          chmod +x $out/bin/gunzip
        '')
      ]; });

  # H10/H11 (tranche 5): perl on illumos needs its obsolete `ld-shared.patch`
  # dropped (fails to apply to 5.42.0) and `-lm -lnsl -lsocket` on the link
  # (miniperl references cos/exp/log/... + socketpair). Because
  # `overrideAttrs` here does NOT survive the `.override` calls that spawn perl
  # variants (perlOnBuild etc.), the actual fix lives in the STDENV mkDerivation
  # wrapper in tranche5.nix (scoped to pname == "perl"), which reaches every
  # variant. No perl entry needed here.

  # H16 (tranche 5): openssl builds + links fully (perl-driven Configure runs,
  # libssl/libcrypto compile with `-lsocket -lnsl -ldl`), but its test suite's
  # QUIC multistream tests are timing-sensitive and time out under load on this
  # builder (`ossl_time_compare(ossl_time_now(), op_deadline) <= 0 failed`,
  # "network BIO I/O error"). These are flaky perf/timing tests, not a crypto
  # defect; skip the test suite (standard constrained-builder practice) so the
  # library installs. openssl gates a large fraction of the remaining swath.
  openssl = onSolaris prev.openssl (old: { doCheck = false; });

  # H14 (tranche 5): the LocaleGettext perl module's Makefile.PL probe links
  # `$cc conftest.c -lintl` with NO `-L`, relying on the buildInput's libdir
  # being on the link path. Under strictDeps it is not, so with gettext's
  # libintl.h on the include path `gettext` macro-expands to `libintl_gettext`
  # and the probe fails `Undefined symbol libintl_gettext` -> "gettext function
  # not found". NIX_LDFLAGS does NOT help here: on illumos gcc execs the host
  # ld directly (the H1 bypass), so the ld-wrapper's NIX_LDFLAGS -L is never
  # seen. Put `-L` on NIX_CFLAGS_COMPILE instead -- the cc-wrapper adds that to
  # every gcc invocation, so gcc passes -L straight to its own link (H1 auto-
  # adds the matching -R for runtime). Unblocks help2man -> bison/flex/libtool
  # -> autoreconfHook and the whole build-tool swath (bc, cpio, ...).
  perlPackages = if isSolaris then prev.perlPackages.overrideScope (pfinal: pprev: {
    LocaleGettext = pprev.LocaleGettext.overrideAttrs (old: {
      # The probe does `$cc conftest.c -lintl` with no -L. The cc-wrapper only
      # applies NIX_CFLAGS_COMPILE's -L to compile steps, not this compile+link
      # one-shot, and NIX_LDFLAGS is bypassed (illumos gcc execs host ld
      # directly, H1). Makefile.PL honors $ENV{CC}, but the stdenv setup exports
      # CC=gcc AFTER our drv attr, so we must set it in preConfigure (post-setup,
      # pre-Makefile.PL). Baking the -L into CC makes the probe's link find
      # libintl_gettext. Unblocks help2man -> bison/flex/libtool ->
      # autoreconfHook and the whole build-tool swath (bc, cpio, ...).
      preConfigure = (old.preConfigure or "") + ''
        export CC="gcc -L${final.gettext}/lib"
      '';
    });
    # H15 (tranche 6): point Compress-Raw-Bzip2 at the REAL multi-output bzip2
    # (the top-level `pkgs.bzip2` is the dev-less seed slice, unfixable from a
    # top-level overlay because the final stdenv stage re-pins it). Done via
    # overrideScope so the perl-set INTERNAL self-reference is replaced too --
    # a plain `prev.perlPackages // {...}` only swaps the outer attr, not the
    # `self.CompressRawBzip2` that sibling modules (HTTP-Message ->
    # propagatedBuildInputs) pull. Unblocks git/wget's perl (libwww ->
    # HTTP-Message -> Compress-Raw-Bzip2).
    CompressRawBzip2 = pprev.CompressRawBzip2.overrideAttrs (old: {
      env = (old.env or {}) // {
        BUILD_BZIP2 = false;
        BZIP2_LIB = "${bzip2Real.out}/lib";
        BZIP2_INCLUDE = "${bzip2Real.dev}/include";
      };
    });
  }) else prev.perlPackages;

  # H12 (tranche 5): libxcrypt's AX_CHECK_VSCRIPT probe picks `-Wl,-M` as the
  # "Solaris version-script flag", but the map it then generates
  # (gen-libcrypt-map -> libcrypt.map) is GNU version-script syntax, which the
  # native Solaris ld rejects under -M (`ld: fatal: ./libcrypt.map: 1: expected
  # a '=', ':', '|', or '@'` -- Solaris mapfiles use a different grammar).
  # Symbol versioning is cosmetic on a fresh port (cf. H8/ncurses); disable it
  # so the .so links with the native ld. This libxcrypt is the perl<->libxcrypt
  # cycle-break target, so the fix reaches both the crypt lib and perl.
  libxcrypt = onSolaris prev.libxcrypt (old: {
    configureFlags = (old.configureFlags or []) ++ [ "--disable-symvers" ];
    # H13: test/explicit-bzero fails on illumos (explicit_bzero is macro'd to
    # memset_s, which the illumos libc does not provide the C11-Annex-K way the
    # scrub test expects, so the buffer-zeroed assertion fails). The library
    # builds/links fine; skip the platform-sensitive runtime test suite (1 of
    # 52 fails, 19 already skip) rather than patch libc feature detection.
    doCheck = false;
  });

  # --- gcc-14 strictness relaxation (implicit decls / pointer types) ----
  # These build clean everywhere but trip gcc-14's promoted-to-error warnings
  # on illumos' older headers. Downgrade to warnings rather than patch sources.
  less = onSolaris prev.less (old: addCFlags old gcc14Relax);
  file = onSolaris prev.file (old: addCFlags old gcc14Relax);
  ncurses = onSolaris prev.ncurses (old:
    (addCFlags old "${gcc14Relax} -DNCURSES_WIDECHAR=1") // {
      # H8: ncurses `--with-versioned-syms` emits gcc `-Wl,--version-script`
      # (a GNU-ld spelling) straight to collect2, which execs the host Solaris
      # ld directly (the H1 bypass) so the ld-solaris translation never runs ->
      # `ld: fatal: unrecognized option '--version-script'`. Symbol versioning
      # is cosmetic on a fresh port; drop the flag so the shared libs link with
      # the native Solaris ld.
      configureFlags = builtins.filter (f: f != "--with-versioned-syms")
        (old.configureFlags or []);
    });

  # H40 (wave 8): gnupg's non-minimal buildInputs include openldap (LDAP
  # keyserver support), which drags in systemd via a version-check branch ->
  # llvmPackages.clang -> the unported LLVM bintools-wrapper (null
  # bintools/coreutils/gnugrep assertion), aborting eval before openldap even
  # builds. LDAP keyserver is optional; drop openldap from the graph and
  # --disable-ldap. Also disable the intel TPM2 backend (tpm2-tss is a
  # Linux/udev path) via withTpm2Tss=false. The deps libgcrypt/libgpg-error/
  # libassuan/libksba/npth/gnutls/sqlite/bzip2/readline/libusb1 are all ported.
  gnupg = if isSolaris
    then (prev.gnupg.override { withTpm2Tss = false; }).overrideAttrs (old: {
      buildInputs = builtins.filter
        (b: let n = (b.pname or b.name or ""); in n != "openldap" && n != "libusb1" && n != "libusb")
        (old.buildInputs or []);
      # openldap (LDAP keyserver, drags systemd->clang) and libusb1 (scdaemon
      # smartcard; its illumos configure fails `clock_gettime() is required`)
      # are both optional. Drop them + --disable-ldap; gnupg core
      # (encrypt/sign/verify/keygen/agent) is the deliverable.
      configureFlags = (old.configureFlags or []) ++ [ "--disable-ldap" ];
    })
    else prev.gnupg;

  # H41 (wave 8): postgresql's optional feature args default to Linux-only
  # deps whose bare eval trips the unported clang/systemd bintools assertion
  # (systemdSupport via availableOn systemdLibs; pamSupport via linux-pam;
  # numaSupport/uringSupport via numactl/liburing) or drag in an ICU/kerberos
  # closure we defer (icuSupport/gssSupport). Also jitSupport pulls llvm.
  # Turn all of them off via the package-function args (never evaluates the
  # availableOn defaults). Keeps zlib/readline/openssl/libxml2/lz4/zstd, all
  # ported. The core server + client + libpq is the deliverable.
  postgresql = if isSolaris
    then (prev.postgresql.override {
      systemdSupport = false; pamSupport = false; gssSupport = false;
      icuSupport = false; jitSupport = false; numaSupport = false;
      uringSupport = false; curlSupport = false;
      # generic.nix builds under an LLVM stdenv (`overrideCC llvmPackages.stdenv`)
      # whenever the host cc is not clang, purely to enable -flto -- forcing the
      # unported LLVM toolchain (bintools-wrapper null assertion). Feed it a
      # stdenv that merely REPORTS cc.isClang=true so the branch takes the
      # plain-stdenv path; the actual compiler stays our gcc stdenv. -flto is
      # not the deliverable on a fresh port.
      stdenv = final.stdenv // {
        cc = final.stdenv.cc // { isClang = true; };
      };
    }).overrideAttrs (old: {
      # outputChecks.disallowedRequisites still lists llvmPackages.llvm.*
      # unconditionally; drop the purity checks so they do not re-force LLVM.
      outputChecks = { };
      # The `world`/`install-world` targets + install-time regression harness
      # (temp-install -> initdb) are not the deliverable and initdb hits an
      # illumos syscall it does not implement (`Bad System Call`, SIGSYS).
      # Build/install the plain targets and skip the check phases.
      buildFlags = [ "all" ];
      installTargets = [ "install" ];
      doCheck = false;
      doInstallCheck = false;
      # The `install` target produces no docs, leaving the (still-declared, so
      # remove-references-to -t "$doc" stays valid) doc output empty ->
      # "failed to produce output doc". Drop a minimal file so the output
      # exists.
      # generic.nix pins CFLAGS with -flto; gcc LTO objects on illumos embed
      # the -dev include paths into the shared lib (the seed ld has no LTO
      # plugin to strip them), creating a lib<->dev reference cycle Nix aborts
      # on. Drop -flto (keep the gc-sections size flags) so outputs partition
      # cleanly.
      env = (old.env or { }) // {
        CFLAGS = "-fdata-sections -ffunction-sections";
      };
      postInstall = (old.postInstall or "") + ''
        # break the lib<->dev reference cycle Nix aborts on: scrub any -dev
        # store-path refs embedded in the shared libs (illumos rpath residue).
        # remove-references-to is already a nativeBuildInput.
        if [ -n "''${lib:-}" ] && [ -d "$lib/lib" ]; then
          find "$lib/lib" -type f \( -name '*.so*' -o -name '*.a' \) \
            -exec remove-references-to -t "$dev" -t "$out" {} + 2>/dev/null || true
        fi
        # also scrub -dev refs from every out binary/lib (pgxs/pg_config
        # residue) so the out<->dev cycle is broken too.
        for d in "$out/bin" "$out/lib"; do
          [ -d "$d" ] && find "$d" -type f \
            -exec remove-references-to -t "$dev" {} + 2>/dev/null || true
        done
        mkdir -p "$doc/share/doc/postgresql"
        echo "Documentation is not built in this port (SGML doc toolchain disabled)." \
          > "$doc/share/doc/postgresql/README"
        mkdir -p "$man/share/man/man1"
        echo ".\" man pages are not built in this port (SGML doc toolchain disabled)." \
          > "$man/share/man/man1/postgresql-port.1"
      '';
      # Keep the declared outputs (incl. doc): generic.nix's postInstall runs
      # `remove-references-to -t "$dev" -t "$doc" -t "$man"`, so dropping the
      # doc output would leave -t empty ("-t argument must be a Nix store
      # path"). The `all`/`install` targets simply leave doc empty, which is
      # fine. Just strip the doc toolchain from nativeBuildInputs.
      nativeBuildInputs = builtins.filter
        (b: let n = (b.pname or b.name or ""); in
            n != "libxslt" && n != "docbook-xsl-nons"
         && n != "docbook-xml" && n != "docbook_xml_dtd_45")
        (old.nativeBuildInputs or []);
      # lz4/zstd support is version-gated (no override arg) and its
      # PKG_CHECK_MODULES probe cannot locate the built liblz4/libzstd on this
      # seed (`pkg-config script could not be found`), blocking configure.
      # Toast compression via lz4/zstd is optional; drop the flags + the
      # buildInputs so configure never runs the probe.
      configureFlags = builtins.filter
        (f: f != "--with-lz4" && f != "--with-zstd"
         && f != "--with-uuid=e2fs") (old.configureFlags or []);
      buildInputs = builtins.filter
        (b: let n = (b.pname or b.name or ""); in n != "lz4" && n != "zstd")
        (old.buildInputs or []);
    })
    else prev.postgresql;

  # H42 (wave 8): redis's withSystemd defaults to `availableOn systemd`, whose
  # eval trips the unported systemd/clang bintools assertion. systemd is
  # Linux-only; disable it via the arg. tlsSupport (openssl) + jemalloc stay.
  redis = if isSolaris
    then (prev.redis.override { withSystemd = false; useSystemJemalloc = false; }).overrideAttrs (old: {
      # jemalloc fails to build on illumos (`cannot determine return type of
      # strerror_r`); useSystemJemalloc=false drops the dep, and redis'
      # Makefile then needs MALLOC=libc so it does not try its vendored
      # jemalloc either.
      makeFlags = (old.makeFlags or []) ++ [ "MALLOC=libc" ];
    })
    else prev.redis;

  # H44 (wave 8): memcached's buildInputs include cyrus_sasl, which pulls
  # openpam (a `pkg-config not found or too old` build failure on this seed).
  # SASL auth is optional; drop cyrus_sasl from the graph. libevent (the real
  # dep) stays. Also add the split-libc socket libs (memcached does sockets).
  memcached = if isSolaris
    then (prev.memcached.overrideAttrs (old: (addLdFlags old socketLibs) // {
      buildInputs = builtins.filter
        (b: (b.pname or b.name or "") != "cyrus-sasl"
         && (b.pname or b.name or "") != "cyrus_sasl") (old.buildInputs or []);
    }))
    else prev.memcached;

  # H45 (wave 8): libvorbis' XIPH_PATH_OGG configure macro compiles AND RUNS a
  # `-logg` test program; the compile needs -L (H1 bypasses NIX_LDFLAGS) and
  # the run needs libogg.so on the runtime linker path. -L alone leaves the
  # test binary unable to load libogg -> "must have Ogg installed!". Pass
  # libogg's include/lib dirs explicitly via the macro's own
  # --with-ogg-includes/--with-ogg-libraries flags (no runtime probe), and add
  # -L for the compile. libogg's lib is in its default output, headers in dev.
  libvorbis = onSolaris prev.libvorbis (old:
    (addCFlags old "-L${final.libogg}/lib") // {
      configureFlags = (old.configureFlags or []) ++ [
        "--with-ogg-includes=${final.libogg.dev}/include"
        "--with-ogg-libraries=${final.libogg}/lib"
      ];
    });

  # H47 (wave 8): flac's nativeBuildInputs pull doxygen + graphviz for the API
  # docs; graphviz -> pango -> libthai fails its `pkg-config not found`
  # configure on this seed, blocking flac. The codec libs + tools are the
  # deliverable; drop the doc toolchain, disable the doxygen docs cmake target,
  # drop the (now-empty) doc output, and skip the platform-sensitive check
  # suite. Keeps cmake + libogg (both ported).
  flac = onSolaris prev.flac (old: {
    nativeBuildInputs = builtins.filter
      (b: let n = (b.pname or b.name or ""); in n != "doxygen" && n != "graphviz")
      (old.nativeBuildInputs or []);
    cmakeFlags = (old.cmakeFlags or []) ++ [ "-DBUILD_DOCS=OFF" "-DINSTALL_MANPAGES=OFF" ];
    # flac is cmake-built (no autotools remove-references-to -t $doc). With docs
    # + manpages off, the doc and man outputs are empty -> "failed to produce
    # output". Manpages are pandoc-generated (pandoc = haskell, not on this
    # port). Drop both split outputs; keep bin/dev/out.
    outputs = builtins.filter (o: o != "doc" && o != "man") (old.outputs or [ "out" ]);
    doCheck = false;
    doInstallCheck = false;
  });

  # H43 (wave 8): openvpn's useSystemd defaults to `availableOn systemd` (same
  # assertion). Disable it. openvpn also lists linux-pam unconditionally; drop
  # it from buildInputs (PLUGIN auth-pam is optional) so the Linux-only pam
  # never enters the closure. Keeps lz4/lzo/openssl, all ported.
  openvpn = if isSolaris
    then (prev.openvpn.override { useSystemd = false; }).overrideAttrs (old: {
      buildInputs = builtins.filter
        (b: (b.pname or b.name or "") != "linux-pam"
         && (b.pname or b.name or "") != "pam") (old.buildInputs or []);
      configureFlags = (old.configureFlags or []) ++ [ "--disable-plugin-auth-pam" ];
    })
    else prev.openvpn;

  # NOTE: this is the seed set (~18 packages with documented fixes). Extend by
  # matching a build failure to a shared snippet above and adding one
  # `<attr> = onSolaris prev.<attr> (old: ...)` entry. When a fix recurs across
  # 3+ packages, promote it to a shared snippet (like gnulibFix / socketLibs).

  # ==== merged Lineage-B package overrides (cmake/icu/boost + toolchain) ====

  # p11-kit (meson): common/message.c uses locale_t/strerror_l (illumos gates
  # these behind __EXTENSIONS__ / <xlocale.h>), and common/path.c calls the
  # 5-arg POSIX getpwuid_r, which illumos only declares when
  # _POSIX_PTHREAD_SEMANTICS is defined (otherwise the 4-arg Solaris form ->
  # "too many arguments"). Thread both illumos porting macros in. The link then
  # needs -lsocket/-lnsl (rpc-transport.c uses socket/connect/socketpair -
  # illumos split these out of libc). libintl_dgettext is unresolved because a
  # GNU libintl.h leaked in but illumos gettext is native (in libc, no GNU
  # -lintl); NIX_CFLAGS thread the socket libs, and configure is told there is
  # no GNU libintl so it uses the native symbols. p11-kit is needed by gnutls.
  p11-kit = if isSolaris
    then prev.p11-kit.overrideAttrs (old: {
      env = (old.env or { }) // {
        NIX_CFLAGS_COMPILE = (old.env.NIX_CFLAGS_COMPILE or "")
          + " -D__EXTENSIONS__ -D_POSIX_PTHREAD_SEMANTICS";
        NIX_LDFLAGS = (old.env.NIX_LDFLAGS or "") + " -lsocket -lnsl";
      };
      mesonFlags = (old.mesonFlags or [ ]) ++ [ "-Dnls=false" ];
    })
    else prev.p11-kit;
  # cscope's `emacsSupport` defaults true, pulling emacs-30.2 -> the clang/bpf
  # bintools-wrapper that is null on illumos (assert coreutils/gnugrep). The
  # emacs integration (xcscope.el) is optional; disable it so cscope builds
  # with just ncurses.

  # cscope's `emacsSupport` defaults true, pulling emacs-30.2 -> the clang/bpf
  # bintools-wrapper that is null on illumos (assert coreutils/gnugrep). The
  # emacs integration (xcscope.el) is optional; disable it so cscope builds
  # with just ncurses.
  cscope = if isSolaris
    then prev.cscope.override { emacsSupport = false; }
    else prev.cscope;

  # The `ctags` attr is exuberant-ctags, whose src is an SVN checkout pulling
  # subversion -> apr-util -> openldap -> the clang/bpf bintools (null on
  # illumos). universal-ctags is the maintained replacement and builds from a
  # plain tarball; alias ctags to it.

  # The `ctags` attr is exuberant-ctags, whose src is an SVN checkout pulling
  # subversion -> apr-util -> openldap -> the clang/bpf bintools (null on
  # illumos). universal-ctags is the maintained replacement and builds from a
  # plain tarball; alias ctags to it.
  ctags = if isSolaris then final.universal-ctags else prev.ctags;

  # universal-ctags builds fine but its checkPhase runs a man-page rst test
  # (man-test) that fails on illumos (rst2man/locale differences); the ctags
  # binary is the deliverable, not the man tests. Disable checks.

  # universal-ctags builds fine but its checkPhase runs a man-page rst test
  # (man-test) that fails on illumos (rst2man/locale differences); the ctags
  # binary is the deliverable, not the man tests. Disable checks.
  universal-ctags = if isSolaris
    then prev.universal-ctags.overrideAttrs (old: {
      doCheck = false; doInstallCheck = false;
    })
    else prev.universal-ctags;

  # H20 (tranche 6): git's `rustSupport` defaults to
  # `lib.meta.availableOn hostPlatform rustc` (true), pulling cargo -> cargo-
  # bootstrap -> an LLVM `bintools` that is not ported (`bintools-wrapper`
  # assertion: coreutils/gnugrep null). Rust is optional for git (a couple of
  # experimental builtins); disable it on a fresh illumos port. `.override`
  # (not overrideAttrs) since rustSupport is a package-function arg.
  # H32 (tranche 6): git wants cmake transitively -- via `zlib-ng` (built with
  # cmake) and the sendEmail perl modules (IO-Socket-SSL/Net-SMTP-SSL pull cmake
  # through their check deps). cmake is blocked on illumos (H26, -lkstat/
  # -lsendfile seed gap). Drop sendEmail, and swap the hardcoded zlib-ng for
  # plain zlib (cmake-free) + drop the ZLIB_NG makeflag. Also rustSupport off
  # (H20), curlMinimal (avoid brotli->cmake), no manual/python (man-db/python3
  # -> cmake). Lands git on illumos without cmake.

  # GATE 2: libidn (v1, pulled by gsasl) builds libidn.la via libtool, whose
  # export-symbols rule runs `nm ... | $global_symbol_pipe | sed ... > libidn.exp`.
  # The Solaris-nm probe leaves $global_symbol_pipe empty -> `nm |  | sed`
  # syntax error. withGnmPipe forces the GNU-nm pipe cache var so the .exp list
  # is generated. Unblocks gsasl (and the SASL/i18n consumers behind it).
  libidn = onSolaris prev.libidn (old: withGnmPipe old);
  # GATE 2 consumer proof: gsasl links libidn (the .exp-list package fixed
  # above) and is the SASL/i18n subtree head. Its default build pulls a FULL
  # krb5 for --with-gssapi-impl=mit, but krb5 has an UNRELATED illumos C-port
  # bug (addr.c s6_addr macro clash -- the same reason curl sets
  # gssSupport=false). GSSAPI is an optional gsasl mechanism; drop libkrb5 and
  # --disable-gssapi so gsasl builds against libidn alone, isolating the Gate 2
  # proof from the krb5 issue. doCheck off: the gsasl test suite runs the built
  # tool (spawns subprocesses -> the SYS_spawn/'Bad System Call' kernel gap,
  # Gate 3) and is not the deliverable.

  # GATE 2 consumer proof: gsasl links libidn (the .exp-list package fixed
  # above) and is the SASL/i18n subtree head. Its default build pulls a FULL
  # krb5 for --with-gssapi-impl=mit, but krb5 has an UNRELATED illumos C-port
  # bug (addr.c s6_addr macro clash -- the same reason curl sets
  # gssSupport=false). GSSAPI is an optional gsasl mechanism; drop libkrb5 and
  # --disable-gssapi so gsasl builds against libidn alone, isolating the Gate 2
  # proof from the krb5 issue. doCheck off: the gsasl test suite runs the built
  # tool (spawns subprocesses -> the SYS_spawn/'Bad System Call' kernel gap,
  # Gate 3) and is not the deliverable.
  gsasl = onSolaris prev.gsasl (old: withGnmPipe old // {
    buildInputs = builtins.filter
      (b: (b.pname or b.name or "") != "krb5" && (b.pname or b.name or "") != "libkrb5")
      (old.buildInputs or [ ]);
    configureFlags = (builtins.filter (f: f != "--with-gssapi-impl=mit") (old.configureFlags or [ ]))
      ++ [ "--disable-gssapi" ];
    doCheck = false;
  });

  # GATE 3: icu's pkgdata step spawns gcc to compile the packaged data object
  # (icudt*_dat.o -> libicudata.so). pkgdata's spawn goes through the seed
  # libc posix_spawn fast path -> SYS_spawn (syscall 143), which this build
  # host's kernel (illumos-68259130da) lacks -> ENOSYS -> SIGSYS -> `Bad System
  # Call` (make: packagedata). Exact same root cause as the cmake SYS_spawn gap
  # (Gate 1-E). Fix the same way: make the kernel-matched platform /lib/64 libc
  # (vforkx path) win at pkgdata-run-time via LD_LIBRARY_PATH_64. pkgdata has no
  # RPATH and relies on its Makefile's relative LD_LIBRARY_PATH for the icu
  # libs, and LD_LIBRARY_PATH_64 fully REPLACES the 64-bit search view -- so the
  # icu build lib dirs (absolute, from the `source` build root) must be listed
  # alongside /lib/64 or pkgdata can't find libicutu.so.78. /lib/64 is the
  # platform libc-family path (no store-closure change). Applies to `icu`
  # (icu4c) and its buildRootOnly sub-derivation.

  # GATE 3: icu's pkgdata step spawns gcc to compile the packaged data object
  # (icudt*_dat.o -> libicudata.so). pkgdata's spawn goes through the seed
  # libc posix_spawn fast path -> SYS_spawn (syscall 143), which this build
  # host's kernel (illumos-68259130da) lacks -> ENOSYS -> SIGSYS -> `Bad System
  # Call` (make: packagedata). Exact same root cause as the cmake SYS_spawn gap
  # (Gate 1-E). Fix the same way: make the kernel-matched platform /lib/64 libc
  # (vforkx path) win at pkgdata-run-time via LD_LIBRARY_PATH_64. pkgdata has no
  # RPATH and relies on its Makefile's relative LD_LIBRARY_PATH for the icu
  # libs, and LD_LIBRARY_PATH_64 fully REPLACES the 64-bit search view -- so the
  # icu build lib dirs (absolute, from the `source` build root) must be listed
  # alongside /lib/64 or pkgdata can't find libicutu.so.78. /lib/64 is the
  # platform libc-family path (no store-closure change). Applies to `icu`
  # (icu4c) and its buildRootOnly sub-derivation.
  icu = onSolaris prev.icu (old: {
    preBuild = (old.preBuild or "") + ''
      export LD_LIBRARY_PATH_64="/lib/64:$PWD/lib:$PWD/stubdata:$PWD/tools/ctestfw''${LD_LIBRARY_PATH_64:+:$LD_LIBRARY_PATH_64}"
    '';
  });

  # GATE 3: boost's b2 (bjam) engine spawns compile subprocesses via the seed
  # libc posix_spawn fast path -> SYS_spawn (syscall 143) -> ENOSYS -> SIGSYS
  # -> `Bad System Call` at `./b2 install`. Exact same SYS_spawn kernel gap as
  # cmake/icu (Gate 1-E / Gate 3). Fix: preBuild exports LD_LIBRARY_PATH_64 with
  # /lib/64 first so b2 (and every tool it spawns) uses the kernel-matched
  # platform libc (vforkx path). /lib/64 is the platform libc-family path (no
  # store-closure change). boost builds a version-matched b2 via
  # `boost-build.override { useBoost = self; }` (boost/default.nix makeBoost),
  # so the fix must be on the boost-build FUNCTION: overriding boost-build here
  # and re-asserting the env in its preBuild covers both the standalone
  # boost-build and the useBoost instance boost consumes. The boost derivation
  # itself also runs b2 (build+install), so mirror the export there too.

  # GATE 3: boost's b2 (bjam) engine spawns compile subprocesses via the seed
  # libc posix_spawn fast path -> SYS_spawn (syscall 143) -> ENOSYS -> SIGSYS
  # -> `Bad System Call` at `./b2 install`. Exact same SYS_spawn kernel gap as
  # cmake/icu (Gate 1-E / Gate 3). Fix: preBuild exports LD_LIBRARY_PATH_64 with
  # /lib/64 first so b2 (and every tool it spawns) uses the kernel-matched
  # platform libc (vforkx path). /lib/64 is the platform libc-family path (no
  # store-closure change). boost builds a version-matched b2 via
  # `boost-build.override { useBoost = self; }` (boost/default.nix makeBoost),
  # so the fix must be on the boost-build FUNCTION: overriding boost-build here
  # and re-asserting the env in its preBuild covers both the standalone
  # boost-build and the useBoost instance boost consumes. The boost derivation
  # itself also runs b2 (build+install), so mirror the export there too.
  boost-build = onSolaris prev.boost-build (old: {
    preBuild = (old.preBuild or "") + ''
      export LD_LIBRARY_PATH_64="/lib/64''${LD_LIBRARY_PATH_64:+:$LD_LIBRARY_PATH_64}"
    '';
    preInstall = (old.preInstall or "") + ''
      export LD_LIBRARY_PATH_64="/lib/64''${LD_LIBRARY_PATH_64:+:$LD_LIBRARY_PATH_64}"
    '';
  });

  boost = onSolaris (prev.boost.override { enableIcu = false; }) (old: {
    # boost.process links -lkvm and boost.fiber links -llgrp (Solaris Jamfile
    # lib lists), but neither platform lib exists on this illumos -> `ld: fatal:
    # library -lkvm/-llgrp: not found`. Those two libs are NOT the b2 gate (all
    # other ~28 boost libs build once the b2 SYS_spawn gap is fixed); drop them
    # from the target set. b2Args is a Nix-eval interpolation baked into the
    # buildPhase/installPhase, so we intercept the `b2` command itself with a
    # shell function (defined in preBuild, inherited by the same-shell
    # buildPhase/installPhase) that appends --without-fiber --without-process.
    # Same preBuild also pins LD_LIBRARY_PATH_64=/lib/64 so b2's spawns use the
    # kernel-matched platform libc (SYS_spawn gate, Gate 3).
    preBuild = (old.preBuild or "") + ''
      export LD_LIBRARY_PATH_64="/lib/64''${LD_LIBRARY_PATH_64:+:$LD_LIBRARY_PATH_64}"
      b2() { command b2 "$@" --without-fiber --without-process; }
    '';
    preInstall = (old.preInstall or "") + ''
      export LD_LIBRARY_PATH_64="/lib/64''${LD_LIBRARY_PATH_64:+:$LD_LIBRARY_PATH_64}"
      b2() { command b2 "$@" --without-fiber --without-process; }
    '';
  });

  # GATE 1 (cmake link gap behind rhash): once rhash's OS detection is fixed
  # (above), cmake's bundled cmlibrhash compiles, but cmake's bootstrap link
  # line is `gcc ... -lkstat -lsendfile ...` (its bundled cmlibuv uses
  # kstat_open/sendfile). Those are illumos base-platform libs at /lib/amd64,
  # not on the default link path -> `ld: fatal: library -lkstat: not found`.
  # extraSyslibs already carries the `libkstat.so`/`libsendfile.so` link-editor
  # stubs (-> /lib/amd64/*.so.1); thread its -L in via the cc-wrapper knob (the
  # H1 wrapper auto-adds the matching -R, so the runtime closure stays
  # host-free -- the stub targets the platform .so.1 the same class as libc).
  # Same wiring htop uses.
  #
  # Second gap: cmake hard-codes CMAKE_RANLIB/CMAKE_STRIP at
  # ${bintools}/bin/{ranlib,strip}, but the illumos seed bintools slice ships
  # only ar/as/ld/nm -- no ranlib, no strip. cmake's post-bootstrap `make`
  # then runs `ranlib libFOO.a` -> execve of a nonexistent file -> `Error
  # running link command: no such file or directory`. illumos `ar qc` already
  # writes the archive symbol index (verified: gnm -s shows the index), so
  # ranlib is a no-op here; strip is handled hermetically by fixupPhase. Point
  # both flags at a store-path no-op (coreutils `true`) so the archive step
  # succeeds host-free. Unblocks cmake -> double-conversion/cjson/libcbor/
  # mbedtls/zlib-ng/xxHash/abseil-cpp/json-glib.
  cmake = onSolaris prev.cmake (old:
    let base = old.env or { }; in
    { env = base // {
        NIX_CFLAGS_COMPILE = lib.concatStringsSep " "
          (lib.filter (s: s != "") [ (base.NIX_CFLAGS_COMPILE or "") "-L${extraSyslibs}/lib/amd64" ]);
        # illumos `ld` flags kstat_*/sendfile as undefined at the final program
        # link even though libuv.so records them as NEEDED (it does not chase a
        # NEEDED .so's own deps for symbol resolution). Add the libs directly to
        # cmake's own link line so ld resolves them (host-free: extraSyslibs
        # stubs -> /lib/amd64/*.so.1, H1 wrapper adds the matching -R).
        NIX_LDFLAGS = lib.concatStringsSep " "
          (lib.filter (s: s != "") [ (base.NIX_LDFLAGS or "")
            "-L${extraSyslibs}/lib/amd64 -lkstat -lsendfile -lnsl -lsocket" ]);
      };
      configureFlags = map
        (f:
          if lib.hasPrefix "-DCMAKE_RANLIB" f then "-DCMAKE_RANLIB=${final.coreutils}/bin/true"
          else if lib.hasPrefix "-DCMAKE_STRIP" f then "-DCMAKE_STRIP=${final.coreutils}/bin/true"
          else f)
        (old.configureFlags or [ ]);
      # SYS_spawn (syscall 143) mismatch: the seed libc.so.1
      # (illumos-seed-unpacked/usr/gnu/lib) is from a NEWER illumos than the
      # build host's running kernel (illumos-68259130da), and its posix_spawn
      # fast path issues SYS_spawn -- a syscall this kernel does not implement
      # -> ENOSYS -> SIGSYS -> `Bad System Call`, killing cmake the moment it
      # spawns a build tool (e.g. its `execute_process` cc/kstat probes). The
      # kernel-matched platform libc at /lib/64 uses the older vforkx path and
      # works (verified: LD_LIBRARY_PATH_64=/lib/64 -> cmake configure+ninja
      # build succeed). /lib/64 is the platform libc-family path (same class as
      # the libc.so.1/libkstat.so.1 already accepted from there), so preferring
      # it at cmake-run-time stays host-free -- no store-closure change. Export
      # it from cmake's setup-hook so every cmake-driven consumer build inherits
      # the kernel-matched libc. (NOTE: build-host kernel < seed illumos; the
      # proper long-term fix is a kernel with SYS_spawn or a seed rebuilt
      # against this kernel -- this env pin unblocks the cmake subtree now.)
      postFixup = (old.postFixup or "") + ''
        mkdir -p $out/nix-support
        touch $out/nix-support/setup-hook
        if ! grep -q LD_LIBRARY_PATH_64 $out/nix-support/setup-hook; then
          echo 'export LD_LIBRARY_PATH_64="''${LD_LIBRARY_PATH_64:+$LD_LIBRARY_PATH_64:}/lib/64"' >> $out/nix-support/setup-hook
        fi
      '';
    });

  # GATE 1: rhash's hand-rolled (non-autotools) configure OS-detection blocks
  # the whole cmake-built graph. nixpkgs passes --target=${stdenv.hostPlatform.config}
  # = x86_64-unknown-solaris. configure's set_target_os() splits on '-' and
  # tests component 3 (solaris) then component 2 (unknown) against a case whose
  # Solaris arm is `sunos|solaris2.*` -- bare `solaris` matches neither, so
  # TARGET_OS stays UNKNOWN -> `die "Unknown target OS"`. Add a `solaris*` arm
  # to the case so the illumos triple maps onto the existing SunOS code path
  # (rhash already fully supports SunOS/Solaris; only the triple was unknown).
  # test-full runs the built tool against a fixture set; keep doCheck off so a
  # test wrinkle can't re-block the cmake graph. Unblocks cmake -> the
  # double-conversion/cjson/libcbor/mbedtls/zlib-ng/xxHash/... subtree.

  # tomlplusplus: header-only; meson test suite has static_asserts that fail on
  # ill int types. Disable tests + install-check; the installed output is headers.
  tomlplusplus = onSolaris prev.tomlplusplus (old: {
    doCheck = false; doInstallCheck = false;
    mesonFlags = (old.mesonFlags or []) ++ [ "-Dbuild_tests=false" "-Dbuild_examples=false" ];
  });

  # mbedtls: nixpkgs hardcodes -fzero-init-padding-bits=unions (a gcc-15 flag);
  # the seed compiler is gcc-10.5 and rejects it. Drop that one cmakeFlag.

  # mbedtls: nixpkgs hardcodes -fzero-init-padding-bits=unions (a gcc-15 flag);
  # the seed compiler is gcc-10.5 and rejects it. Drop that one cmakeFlag.
  mbedtls = onSolaris prev.mbedtls (old: {
    doCheck = false;
    cmakeFlags = (builtins.filter
      (f: !(lib.hasInfix "zero-init-padding-bits" (toString f)))
      (old.cmakeFlags or [])) ++ [ "-DENABLE_TESTING=OFF" "-DENABLE_PROGRAMS=OFF" ];
    # nixpkgs picks scripts/config.pl for version<4.0, but mbedtls 3.6 already
    # ships only scripts/config.py -> the perl path 404s. Use config.py.
    postConfigure = ''
      python "$NIX_BUILD_TOP/source/scripts/config.py" set MBEDTLS_THREADING_C
      python "$NIX_BUILD_TOP/source/scripts/config.py" set MBEDTLS_THREADING_PTHREAD
    '';
  });

  # abseil-cpp: the seed g++ defaults to a pre-C++17 std; abseil requires >=17.

  # abseil-cpp: the seed g++ defaults to a pre-C++17 std; abseil requires >=17.
  abseil-cpp = onSolaris prev.abseil-cpp (old: {
    cmakeFlags = (old.cmakeFlags or []) ++ [ "-DCMAKE_CXX_STANDARD=17" ];
  });

  # spdlog: os-inl.h uses struct tm tm_gmtoff, which illumos only exposes under
  # __EXTENSIONS__. Define it so the header sees the BSD/SysV tm fields.

  # spdlog: os-inl.h uses struct tm tm_gmtoff, which illumos only exposes under
  # __EXTENSIONS__. Define it so the header sees the BSD/SysV tm fields.
  spdlog = onSolaris prev.spdlog (old: {
    cmakeFlags = (old.cmakeFlags or []) ++ [ "-DCMAKE_CXX_FLAGS=-D__EXTENSIONS__" ];
  });

  # wavpack: autotools/libtool package; the .la link uses -export-symbols-regex,
  # which triggers libtool empty global_symbol_pipe -> `nm | | sed` syntax error
  # (GATE 2). withGnmPipe supplies the Solaris-ELF nm pipe cache var.

  # wavpack: autotools/libtool package; the .la link uses -export-symbols-regex,
  # which triggers libtool empty global_symbol_pipe -> `nm | | sed` syntax error
  # (GATE 2). withGnmPipe supplies the Solaris-ELF nm pipe cache var.
  wavpack = onSolaris prev.wavpack (old: withGnmPipe old);

  # libcbor: only build-dep is cmocka (for tests); cmocka fails on gcc-10.5
  # (__attribute__((access(none))) is a gcc-11 addition). With tests off the
  # cmocka module is unneeded -> drop it from buildInputs and disable doCheck.

  # libcbor: only build-dep is cmocka (for tests); cmocka fails on gcc-10.5
  # (__attribute__((access(none))) is a gcc-11 addition). With tests off the
  # cmocka module is unneeded -> drop it from buildInputs and disable doCheck.
  libcbor = onSolaris prev.libcbor (old: {
    doCheck = false;
    buildInputs = [];
  });

  # zeromq: links network syscalls (__xnet_bind/setsockopt) that live in
  # libsocket/libnsl on illumos (split libc). Add socketLibs at link.

  # toml11: header-only C++; only build-dep is doctest (tests), which fails to
  # build. Disable doCheck so the doctest test dep is dropped.
  toml11 = onSolaris prev.toml11 (old: { doCheck = false; });

  # protobuf: library + protoc build fine (abseil consumer); the bundled test
  # protos fail to compile. Disable tests -> keep the shipped library/tools.

  # protobuf: library + protoc build fine (abseil consumer); the bundled test
  # protos fail to compile. Disable tests -> keep the shipped library/tools.
  protobuf = onSolaris prev.protobuf (old: {
    doCheck = false;
    cmakeFlags = (old.cmakeFlags or []) ++ [ "-Dprotobuf_BUILD_TESTS=OFF" ];
  });

  # capstone: disassembler lib builds fine; its bundled tests reference optarg
  # via a header clash. Turn tests off (the shipped output is lib+headers).

  # capstone: disassembler lib builds fine; its bundled tests reference optarg
  # via a header clash. Turn tests off (the shipped output is lib+headers).
  capstone = onSolaris prev.capstone (old: {
    doCheck = false;
    cmakeFlags = (old.cmakeFlags or []) ++ [ "-DCAPSTONE_BUILD_TESTS=OFF" "-DCAPSTONE_BUILD_CSTOOL=OFF" ];
  });

  # c-blosc: library builds; its tests need a platform aligned-alloc probe that
  # is not wired for illumos. doCheck off flips -DBUILD_TESTS=OFF in nixpkgs.

  # c-blosc: library builds; its tests need a platform aligned-alloc probe that
  # is not wired for illumos. doCheck off flips -DBUILD_TESTS=OFF in nixpkgs.
  c-blosc = onSolaris prev.c-blosc (old: { doCheck = false; });

  # NOTE: this is the seed set (~18 packages with documented fixes). Extend by
  # matching a build failure to a shared snippet above and adding one
  # `<attr> = onSolaris prev.<attr> (old: ...)` entry. When a fix recurs across
  # 3+ packages, promote it to a shared snippet (like gnulibFix / socketLibs).

  # iperf3: configure detects netinet/sctp.h and compiles the SCTP path, but
  # illumos keeps sctp_bindx/sctp_opt_info in libsctp under /usr/lib (not on
  # the store link path, and pulling it would break host-freedom). Turn SCTP
  # off so the shipped binary needs no host libsctp.

  # NOTE: this is the seed set (~18 packages with documented fixes). Extend by
  # matching a build failure to a shared snippet above and adding one
  # `<attr> = onSolaris prev.<attr> (old: ...)` entry. When a fix recurs across
  # 3+ packages, promote it to a shared snippet (like gnulibFix / socketLibs).

  # iperf3: configure detects netinet/sctp.h and compiles the SCTP path, but
  # illumos keeps sctp_bindx/sctp_opt_info in libsctp under /usr/lib (not on
  # the store link path, and pulling it would break host-freedom). Turn SCTP
  # off so the shipped binary needs no host libsctp.
  iperf3 = onSolaris prev.iperf3 (old: {
    configureFlags = (old.configureFlags or []) ++ [ "--without-sctp" ];
  });

  # p7zip: several sources call bzero() without including <strings.h> (illumos
  # does not pull it transitively like glibc). Force-include it at compile.

  # p7zip: several sources call bzero() without including <strings.h> (illumos
  # does not pull it transitively like glibc). Force-include it at compile.
  p7zip = onSolaris prev.p7zip (old: addCFlags old "-include strings.h");


  # pciutils: lib/sysdep.h errors out because BYTE_ORDER is only exposed under
  # __EXTENSIONS__ on illumos. Feature-test macros expose it (+ the XPG symbols).

  # pciutils: lib/sysdep.h errors out because BYTE_ORDER is only exposed under
  # __EXTENSIONS__ on illumos. Feature-test macros expose it (+ the XPG symbols).
  pciutils = onSolaris prev.pciutils (old: addCFlags old illumosExtFlags);

  # mtr: msg_control/msg_controllen on struct msghdr are XPG4.2 fields, hidden
  # unless __EXTENSIONS__/_XOPEN_SOURCE is set on illumos.

  # mtr: msg_control/msg_controllen on struct msghdr are XPG4.2 fields, hidden
  # unless __EXTENSIONS__/_XOPEN_SOURCE is set on illumos.
  mtr = onSolaris prev.mtr (old: addCFlags old illumosExtFlags);

}
