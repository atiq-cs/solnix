# cli/ -- the maintainer's headless CLI set (werk/meh home.packages) as solnix
# derivations: C/autotools on mk-src-pkg (./c-*.nix), Rust on cargoPkg (../cargo.nix,
# ./rust.nix), Go on a from-source go1.4 -> current chain (./go.nix, ./go-tools.nix).
{ base, world, graphics, cargoPkg ? null, goChain ? null }:
# cargoPkg/goChain null (aarch64: no Rust or Go illumos/aarch64 target upstream) drops those tiers.
let
  # base = srcPkgs (base-src.nix): mkSrcPkg, zlib, openssl, ncurses, coreutils, ... and nixChain.
  args = { inherit base world graphics; inherit (base) mkSrcPkg zlib openssl ncurses libiconv pkgconf nixChain; };
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
  h = args // { inherit scrub gnulibFix dropDocs chk; };
  c1 = import ./c-base.nix h;
  c2 = import ./c-net.nix (h // { inherit (c1) readline; });
  c3 = import ./c-gnupg.nix (h // { inherit (c1) readline; });
  c4 = import ./c-big.nix (h // { inherit (c1) readline gnum4; inherit (c2) sqlite; });
  c5 = import ./c-dev.nix (h // { inherit (c1) readline; inherit (c2) sqlite; inherit (c4) perl; });
  c6 = import ./c-mail.nix (h // { inherit (c1) readline; inherit (c4) perl; inherit (c5) cmake gdbm; });
  rust = import ./rust.nix { inherit cargoPkg chk; extra = import ./rust-extra.nix h; };
  gotools = import ./go-tools.nix { inherit (goChain) goPkg go_1_27; inherit chk; inherit (c5) python3; } // import ./go-c1.nix { inherit (goChain) goPkg go_1_27; inherit chk; inherit (c5) python3; };
  data = import ./data.nix h;
in c1 // c2 // c3 // c4 // c5 // c6 // data // (if cargoPkg == null then { } else rust) // (if goChain == null then { } else gotools)
