# aarch64/a64h-pkgs.nix -- build-only tools the stage0 box had in /usr/bin and /opt that no aarch64 recipe built yet:
# bison (nix's parser.y, gdbm, tmux: dixa4's logs show devroot's /usr/bin/bison) and autoconf-archive (nix's autoreconf needs
# AX_BOOST_BASE; was /opt/ooce/autoconf-archive). Built by the store-only mkSrcPkg (no seed copy: nothing at run time needs them).
{ mkSrcPkg }:
{
  # cli/c-gnupg.nix's bzip2-bin, the same text (so the same drv as gnupg's): GNU tar runs bzip2 from PATH for boost's .tar.bz2.
  bzip2-bin = mkSrcPkg {
    pname = "bzip2-bin"; version = "1.0.8";
    src = { url = "https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz";
            sha256 = "ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269"; };
    build = ''
      gmake bzip2 CC="$CC" >&2
      mkdir -p "$out/bin"; cp bzip2 "$out/bin/"; ln -s bzip2 "$out/bin/bunzip2"; ln -s bzip2 "$out/bin/bzcat"
      echo bzip2-ok | "$out/bin/bzip2" | "$out/bin/bzcat" | grep -qx bzip2-ok || { echo "FATAL: bzip2 round trip" >&2; exit 1; }
    '';
  };
  bison = mkSrcPkg {
    pname = "bison"; version = "3.8.2";
    src = { url = "https://mirrors.kernel.org/gnu/bison/bison-3.8.2.tar.xz";
            sha256 = "9bba0214ccf7f1079c5d59210045227bcf619519840ebfa80cd3849cff5a5bf2"; };
    build = ''
      MAKEINFO=true ./configure --prefix="$out" --disable-nls --disable-yacc
      gmake -j8 MAKEINFO=true; gmake install MAKEINFO=true
      find "$out/share/doc" "$out/share/info" -delete 2>/dev/null || true
      printf '%%%%\ns: "a";\n%%%%\n' > "$W/t.y"; "$out/bin/bison" -o "$W/t.c" "$W/t.y"
      grep -q yyparse "$W/t.c" || { echo "FATAL: bison self-check" >&2; exit 1; }
    '';
  };
  # 2024.10.16, gpgv GOOD (Peter Simons 1A4F63A13A4649B632F65EE141BC28FE99089D72) against gnu-keyring.gpg.
  autoconf-archive = mkSrcPkg {
    pname = "autoconf-archive"; version = "2024.10.16";
    src = { url = "https://mirrors.kernel.org/gnu/autoconf-archive/autoconf-archive-2024.10.16.tar.xz";
            sha256 = "7bcd5d001916f3a50ed7436f4f700e3d2b1bade3ed803219c592d62502a57363"; };
    build = ''
      MAKEINFO=true ./configure --prefix="$out"
      gmake MAKEINFO=true install
      find "$out/share/doc" "$out/share/info" -delete 2>/dev/null || true
      [ -f "$out/share/aclocal/ax_boost_base.m4" ] || { echo "FATAL: no ax_boost_base.m4" >&2; exit 1; }
    '';
  };
}
