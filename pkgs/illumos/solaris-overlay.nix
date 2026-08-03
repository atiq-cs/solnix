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
  pkg-config = onSolaris prev.pkg-config (old:
    addLdFlags old "-lresolv ${socketLibs}");

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
  gawk = onSolaris prev.gawk (old:
    { postPatch = (old.postPatch or "") + gnulibFix; });
  diffutils = onSolaris prev.diffutils (old:
    { postPatch = (old.postPatch or "") + gnulibFix; });
  gettext = onSolaris prev.gettext (old:
    { postPatch = (old.postPatch or "") + gnulibFix;
      # Upstream nixpkgs sets a blanket illumos
      #   LDFLAGS=-lm -lmd -lmp -luutil -lnvpair -lnsl -lidmap -lavl -lsec
      # (gettext/default.nix). The solnix seed only carries libc/libm/libnsl/
      # libresolv/libsocket/... and NOT libmd/libmp/libnvpair/libuutil/libidmap/
      # libavl/libsec (and seed libnsl itself NEEDs the absent libmp/libmd), so
      # that link line fails `library -lmd: not found`. gettext-runtime does not
      # actually need the name-service/crypto libs -- pin LDFLAGS to the
      # seed-available libs. (Drop this once the seed regrows those libs.)
      env = (old.env or { }) // { LDFLAGS = "-lm"; };
    });

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

  # --- gcc-14 strictness relaxation (implicit decls / pointer types) ----
  # These build clean everywhere but trip gcc-14's promoted-to-error warnings
  # on illumos' older headers. Downgrade to warnings rather than patch sources.
  less = onSolaris prev.less (old: addCFlags old gcc14Relax);
  file = onSolaris prev.file (old: addCFlags old gcc14Relax);
  ncurses = onSolaris prev.ncurses (old:
    addCFlags old "${gcc14Relax} -DNCURSES_WIDECHAR=1");

  # NOTE: this is the seed set (~18 packages with documented fixes). Extend by
  # matching a build failure to a shared snippet above and adding one
  # `<attr> = onSolaris prev.<attr> (old: ...)` entry. When a fix recurs across
  # 3+ packages, promote it to a shared snippet (like gnulibFix / socketLibs).
}
