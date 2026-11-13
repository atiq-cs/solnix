# cli/ -- the maintainer's headless CLI set (werk/meh home.packages) as solnix
# derivations: C/autotools on mk-src-pkg (./c-*.nix), Rust on cargoPkg (../cargo.nix,
# ./rust.nix), Go on a from-source go1.4 -> current chain (./go.nix, ./go-tools.nix).
{ base, world, graphics, cargoPkg ? null, goChain ? null, shared ? { }, gtkMeson ? null }:   # shared: one readline from the caller (aarch64 final)
# cargoPkg/goChain null (aarch64: no Rust or Go illumos/aarch64 target upstream) drops those tiers.
let
  # base = srcPkgs (base-src.nix): mkSrcPkg, zlib, openssl, ncurses, coreutils, ... and nixChain.
  args = { inherit base world graphics; inherit (base) mkSrcPkg zlib openssl ncurses libiconv pkgconf nixChain hostTools; };
  # remove-references-to for text files (Config.pm, _sysconfigdata, generated scripts): the
  # gate proto and the compiler are build-time only; a hash left in a text file would pull
  # ~400 MB into the runtime closure (the ELF guard in mk-src-pkg only sees ELFs).
  # Also: the builder's temporary cc/c++ wrappers ($W/cc64) recorded as CC become plain gcc/g++.
  scrub = ''
    grep -rlF "$W/c" "$out" 2>/dev/null | while read -r f; do
      [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] && continue
      chmod u+w "$f"; sed -i "s@$W/cc64@gcc@g; s@$W/c++64@g++@g" "$f"
    done
    for x in "$gate" "$gcc"; do h=$(basename "$x" | cut -c1-32)
      grep -rlF "$h" "$out" 2>/dev/null | while read -r f; do
        [ "$(od -An -tx1 -N4 "$f" | tr -d ' \n')" = 7f454c46 ] && continue
        chmod u+w "$f"; LC_ALL=C sed -i "s/$h/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee/g" "$f"
      done
    done
  '';
  # gnulib in GNU tarballs declares getlocalename_l non-const (base-src.nix gnuTool).
  gnulibFix = ''
    for f in $(find . \( -name 'localename*.[ch]' -o -name 'getlocalename_l*.[ch]' -o -name 'setlocale_null*.c' \)); do
      sed -i 's/extern char \* *getlocalename_l/extern const char *getlocalename_l/;s/^char \* *getlocalename_l/const char *getlocalename_l/' "$f"
    done
  '';
  dropDocs = ''find "$out/share/doc" "$out/share/info" -delete 2>/dev/null || true'';
  # fail the build unless <cmd> prints <regex> (the brief's in-build --version check)
  chk = cmd: re: ''
    ( ${cmd} ) > "$W/chk.out" 2>&1 || true
    grep -Eq '${re}' "$W/chk.out" || { echo "FATAL: in-build check failed (want /${re}/), got:" >&2; head -5 "$W/chk.out" >&2; exit 1; }
    echo "CHECK-OK: $(head -1 "$W/chk.out")" >&2
  '';
  # NixOS's autoreconfHook: `autoreconf -fi` on the served store autotools (autoconf, automake, libtool, m4, perl), ACLOCAL_PATH from every
  # PATH entry's and dep's share/aclocal (what NixOS's setup hooks collect), so no host /usr/share/aclocal is read. A recipe puts
  # autoreconfTools in nativeTools and runs ${autoreconf} before ./configure (a tag tarball without a generated configure).
  autoreconfTools = [ c4.autoconf c4.automake c4.libtool c1.gnum4 c4.perl ];
  autoreconf = ''
    _acl=""
    for _d in $(echo "$PATH" | tr ':' ' ') $depsArg $linkDepsArg; do _d=''${_d%/bin}; _d=''${_d%/sbin}
      if [ -d "$_d/share/aclocal" ]; then _acl="$_acl:$_d/share/aclocal"; fi
    done
    # main's served libtool 2.5.4 ships bin/libtoolize without its exec bit (mk-src-pkg's x86 de-bake rewrites text files with sed > f.btfix
    # && mv, a new 0644 file; WAVE7-NOTES "stdenv"): run it through the shell, as autoreconf's LIBTOOLIZE allows
    ACLOCAL_PATH="''${_acl#:}" LIBTOOLIZE="$BASH ${c4.libtool}/bin/libtoolize" autoreconf -fi >&2
  '';
  h = args // { inherit scrub gnulibFix dropDocs chk autoreconfTools autoreconf; };
  c1 = import ./c-base.nix (h // { inherit shared; inherit (c5) gnupatch; });   # gnupatch: flex's fae57c41b4 (gnupatch's closure has no flex)
  c2 = import ./c-net.nix (h // { inherit (c1) readline; });
  c3 = import ./c-gnupg.nix (h // { inherit (c1) readline; });
  c4 = import ./c-big.nix (h // { inherit (c1) readline gnum4; inherit (c2) sqlite; inherit (c5) gnupatch; });   # gnupatch: perl's no-sys-dirs (no perl in its closure)
  c5 = import ./c-dev.nix (h // { inherit (c1) readline gnum4; inherit (c2) sqlite; inherit (c4) perl; });
  c6 = import ./c-mail.nix (h // { inherit (c1) readline; inherit (c4) perl; inherit (c5) cmake gdbm; });
  # recipes2: tools/libraries solnix lacked (a new file, so no served drv moves)
  c7 = import ./c-recipes2.nix (h // { inherit (c1) readline gnum4; inherit (c4) perl; inherit (c5) cmake python3; inherit (c3) libgpg-error libassuan bzip2-bin; });
  # libdb 2026.10.7.2 (+ the berkeleydb alias): Oracle Berkeley DB 5.3.28's replacement (libdb1, security)
  c8 = import ./c-libdb.nix (h // { inherit (c5) python3; tcl = c7.tcl.unfixed; }) // cqd // c13;   # c-recipes2.nix says why; cqd, c13: on this line, so the `in` line other lanes edit stays main's
  # qnew6: idle1's ranked leaves #21-#40 (a new file, so no served drv moves); x86 only, as c11
  c13 = if gtkMeson == null then { } else import ./c-qnew6.nix (h // { inherit (c5) cmake python3 gnupatch; inherit (c4) perl libtool;
    inherit (c1) flex bison autoconf-archive; inherit (c9) libogg check gtest; inherit (c10) uthash netsurf-buildsystem libparserutils libzen;
    inherit gtkMeson; });
  # qdeps: the shared image/messaging/XSLT/Lua leaves the x86 queue's names wait on (a new file, so no served drv moves); x86 only, as c10
  cqd = if gtkMeson == null then { } else import ./c-qdeps.nix (h // { inherit (c5) cmake gnupatch; inherit (c9) libdeflate;
    inherit (c10) lerc; inherit (c7) giflib; inherit gtkMeson; });
  # recipes3: libraries the x86 queue has jobs for (a new file, so no served drv moves)
  c9 = import ./c-recipes3.nix (h // { inherit (c5) cmake; inherit (c4) perl; });
  # recipes4: tools/libraries the x86 queue has jobs for (a new file, so no served drv moves); gtkMeson: x86 only (null drops it)
  c10 = if gtkMeson == null then { } else import ./c-recipes4.nix (h // { inherit (c5) python3; inherit (c5) gnupatch; inherit (c9) libxau libxdmcp libpthread-stubs vulkan-headers libogg check libuv utf8cpp libdeflate libedit popt; inherit (c1) bison; inherit (data) tzdata; inherit (c7) tcl fmt; inherit (c3) bzip2-bin; inherit (c1) gnum4; inherit (c5) cmake; inherit (c4) perl; inherit gtkMeson; });
  # qalias: the queue's nixpkgs variant attrs under their own pnames (a new file, so no served
  # drv moves; aarch64 gets them too, unused there)
  cqa = import ./c-qalias.nix (h // { inherit (c5) cmake gnupatch; inherit (c7) gmp6; inherit (c3) bzip2-bin; nasm = if gtkMeson == null then null else gtkMeson.nasm; });
  # qnew: new recipes for top-level x86 queue names (a new file, so no served drv moves); x86 only, as c10
  c11 = if gtkMeson == null then { } else import ./c-qnew.nix (h // { inherit (c5) cmake python3; inherit (c1) bison gnum4; inherit (c7) fmt;
    inherit (c10) spdlog; inherit (c2) sqlite; inherit gtkMeson; });
  rust = import ./rust.nix { inherit cargoPkg chk; extra = import ./rust-extra.nix h; };
  gotools = import ./go-tools.nix { inherit (goChain) goPkg go_1_27; inherit chk; inherit (c5) python3; } // import ./go-c1.nix { inherit (goChain) goPkg go_1_27; inherit chk; inherit (c5) python3; }
    // import ./go-recipes2.nix { inherit (goChain) goPkg; inherit chk; }
    // import ./go-recipes3.nix { inherit (goChain) goPkg; inherit chk; };   # recipes3 (a new file: no served drv moves)
  # qnew5: idle1's ranked leaves (a new file, so no served drv moves); x86 only, as c11
  c12 = if gtkMeson == null then { } else import ./c-qnew5.nix (h // { inherit (c5) cmake python3 gnupatch; inherit (c4) perl; inherit (ti) texinfo;
    inherit (c10) lzip; inherit (c7) groff; inherit gtkMeson; });
  data = import ./data.nix h // c11 // c12;   # c11, c12: on this line, so the `in` line other lanes edit stays main's
  ti = import ./texinfo.nix (h // { inherit (c1) gnum4; inherit (c4) perl; }) // cqa;   # cqa: on this line, so the `in` line other lanes edit stays main's
in c1 // c2 // c3 // c4 // c5 // c6 // c7 // c8 // c9 // c10 // data // ti // (if cargoPkg == null then { } else rust) // (if goChain == null then { } else gotools)
