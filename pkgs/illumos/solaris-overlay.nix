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

final: prev:

let
  inherit (final) lib;

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

in
{
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
      # H6c: pkg-config's bundled glib configure sets
      #   G_THREAD_LIBS="-lpthread -lthread" on Solaris (a Sun Studio -mt relic).
      # On modern illumos libthread was folded into libc and there is no
      # standalone libthread.so; the pthread symbols are already pulled via
      # -lpthread/libc, so -lthread is redundant and `ld: fatal: library
      # -lthread: not found`. glib is sub-configured DURING make, so patch its
      # GENERATED configure up front (touching configure.ac would trip
      # maintainer-mode autoreconf, which the seed lacks): keep -lpthread, drop
      # -lthread, then touch so it stays newer than configure.ac.
      postPatch = (old.postPatch or "") + ''
        if [ -e glib/configure ]; then
          sed -i 's/-lpthread -lthread/-lpthread/g' glib/configure
          touch glib/configure
        fi
      '';
    });

  # --- socket/name-service split (-lnsl -lsocket) -----------------------
  # curl: does sockets + resolver; needs the split libc libs.
  curl = onSolaris prev.curl (old:
    addLdFlags old socketLibs // { LIBS = socketLibs; });

  # wget: resolver + sockets.
  wget = onSolaris prev.wget (old: addLdFlags old socketLibs);

  # openssh / socket clients: gethostbyname + socket.
  openssh = onSolaris prev.openssh (old: addLdFlags old "${socketLibs} -lresolv");

  # rsync, socat, netcat-family: raw sockets.
  rsync = onSolaris prev.rsync (old: addLdFlags old socketLibs);
  socat = onSolaris prev.socat (old: addLdFlags old socketLibs);

  # --- gnulib const-qualify (GNU coreutils / textutils family) ----------
  coreutils = onSolaris prev.coreutils (old:
    { postPatch = (old.postPatch or "") + gnulibFix; });
  gnugrep = onSolaris prev.gnugrep (old:
    { postPatch = (old.postPatch or "") + gnulibFix; });
  gnused = onSolaris prev.gnused (old:
    { postPatch = (old.postPatch or "") + gnulibFix; });
  # H30 (gawkReal): the seed/wave gawk crashes at load because its RUNPATH is
  # the host /usr/gcc/14/lib/amd64 only and its closure has NO libmpfr.so.6 ->
  # `ld.so.1: awk: fatal: libmpfr.so.6: open failed` -> substituteAll's awk
  # emits nothing -> the cc-wrapper setup-hook keeps @wrapperName@/@suffixSalt@
  # unsubstituted -> EVERY fresh-host bootstrap dies. Fix: build the REAL gawk
  # with gmp/mpfr as store buildInputs AND their -L in NIX_CFLAGS_COMPILE_BEFORE
  # so the H1 cc-wrapper auto-runpath pass bakes /nix/store -R entries (ahead of
  # the host dir) into the RUNPATH -> host-free closure, loads without host libs.
  # Uses the C-only gmp (gmp-with-cxx's C++ conftest fails to RUN on the seed
  # toolchain) and mpfr against it, both with doCheck=false (illumos-flaky).
  #
  # EXPOSED AS `gawkReal`, NOT `gawk`: the top-level `gawk` is the seed-slice
  # bootstrap gawk, re-pinned by the stdenv (`inherit (prevStage) ... gawk`), so
  # a top-level `gawk =` override is shadowed (same class as the H15 bzip2 note).
  # This is the user-facing/profile gawk (published, durable at cache.solnix.io)
  # whose closure is host-free. The BOOTSTRAP seed-gawk RUNPATH is a stdenv-level
  # concern; on a fresh host the seed-gawk is made to load once (host libmpfr in
  # /usr/gcc/14/lib/amd64) purely to substitute this fixed gawk, after which it
  # is the canonical gawk.
  gawkReal = if isSolaris then
    let
      gmpC = (prev.gmp.override { cxx = false; }).overrideAttrs (_: { doCheck = false; });
      mpfrC = (prev.mpfr.override { gmp = gmpC; }).overrideAttrs (_: { doCheck = false; });
    in prev.gawk.overrideAttrs (old: {
      postPatch = "";  # drop the autoreconf "no-pma" patch (drags gettext/texinfo)
      nativeBuildInputs = builtins.filter
        (d: let n = d.pname or d.name or ""; in
            !(lib.hasInfix "autoreconf" n || lib.hasInfix "texinfo" n))
        (old.nativeBuildInputs or []);
      outputs = builtins.filter (o: o != "info") (old.outputs or [ "out" ]);
      buildInputs = (old.buildInputs or []) ++ [ gmpC mpfrC ];
      NIX_CFLAGS_COMPILE_BEFORE = lib.concatStringsSep " " [
        (old.NIX_CFLAGS_COMPILE_BEFORE or "")
        "-L${mpfrC}/lib" "-L${gmpC}/lib"
      ];
    })
    else prev.gawk;
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

  # NOTE: this is the seed set (~18 packages with documented fixes). Extend by
  # matching a build failure to a shared snippet above and adding one
  # `<attr> = onSolaris prev.<attr> (old: ...)` entry. When a fix recurs across
  # 3+ packages, promote it to a shared snippet (like gnulibFix / socketLibs).
}
