# cli/data.nix -- data packages (plain files, no ELF): IANA services/protocols, mime.types+mailcap, the tz database.
# nixpkgs' versions at nix-config's lock. Built with mk-src-pkg so they get its fetch check, fixed W and gate.
# mpdecimal (libmpdec, C; what python's decimal and qsv's nixpkgs closure use) is here too: one file for batch C1.
{ mkSrcPkg, chk, dropDocs, ... }:
{
  iana-etc = mkSrcPkg {
    pname = "iana-etc"; version = "20251215";
    src = { url = "https://github.com/Mic92/iana-etc/releases/download/20251215/iana-etc-20251215.tar.gz";
            sha256 = "c75695a85e583f2e175e7e671f03bddd989857bab10889764c1bb3b7abd206c3"; };
    build = ''
      mkdir -p "$out/etc"; cp services protocols "$out/etc/"
      ${chk ''grep -E "^ssh[[:space:]]+22/tcp" "$out/etc/services"'' "^ssh"}
    '';
  };

  mpdecimal = mkSrcPkg {
    pname = "mpdecimal"; version = "4.0.1";
    src = { url = "https://www.bytereef.org/software/mpdecimal/releases/mpdecimal-4.0.1.tar.gz";
            sha256 = "96d33abb4bb0070c7be0fed4246cd38416188325f820468214471938545b1ac8"; };
    build = ''
      ./configure --prefix="$out" --libdir="$out/lib/amd64" --disable-static --disable-cxx --disable-doc
      gmake -j8; gmake install
      ${dropDocs}
      /usr/bin/elfdump -d "$out/lib/amd64/libmpdec.so.4" | grep -q 'SONAME.*libmpdec.so.4' || { echo "FATAL: no libmpdec.so.4" >&2; exit 1; }
    '';
  };

  # releases.pagure.org dropped the tarball (404, 2026-10-30); Fedora's lookaside serves the same bytes.
  mailcap = mkSrcPkg {
    pname = "mailcap"; version = "2.1.54";
    src = { url = "https://src.fedoraproject.org/repo/pkgs/mailcap/mailcap-2.1.54.tar.xz/sha512/a80caba013b644111f163d8ef74fe801d7266cf4edd38ca723f98fb12a103a24e84a8fca0c569beb05ca0f407437ed1282306b30303c38327b744194c6fe80b2/mailcap-2.1.54.tar.xz";
            sha256 = "9a4032202fc0d2b0858f41b167389a9cfe52ac24ec282e6479b90765319de113"; };
    build = ''
      sed -i 's|/usr/bin/||g' mailcap
      mkdir -p "$out/etc/nginx" "$out/share/man/man5"
      cp mailcap mime.types "$out/etc/"; cp mailcap.5 "$out/share/man/man5/"
      sh generate-nginx-mimetypes.sh < mime.types > "$out/etc/nginx/mime.types"
      ${chk ''grep -E "^application/json[[:space:]]+json" "$out/etc/mime.types"'' "json"}
    '';
  };

  # tzdata + tzcode (one release, two tarballs; nixpkgs unpacks both). The source is IANA's own
  # git tag tarball (eggert/tz 2026e: data and code together, one fetch). zic is built from it.
  tzdata = mkSrcPkg {
    pname = "tzdata"; version = "2026e";
    src = { url = "https://codeload.github.com/eggert/tz/tar.gz/refs/tags/2026e";
            sha256 = "5b62258a9a868813f00b070983b9b3e7279634575571a0fcc732be6a1f7047c1"; };
    build = ''
      # VERSION: a git-tag tarball has no version file, and `git describe` fails outside a repo.
      gmake -j8 CC="$CC" cc="$CC" AWK=awk CURL=: VERSION=2026e REDO=posix_right TOPDIR="$out" \
        TZDIR="$out/share/zoneinfo" BINDIR="$out/bin" ZICDIR="$out/bin" ZDUMPDIR="$out/bin" ETCDIR="$W/etc" LIBDIR="$W/lib" \
        MANDIR="$out/share/man" TZDEFAULT=tzdefault-to-remove CFLAGS="-O2 -DHAVE_LINK=0 -DZIC_BLOAT_DEFAULT=\\\"fat\\\"" install
      # as nixpkgs: no default zone link (it would name a host), posix/ and right/ inside zoneinfo.
      rm -f "$out/share/zoneinfo-posix" "$out/share/zoneinfo/tzdefault-to-remove"; [ -d "$out/share/zoneinfo-leaps" ] && mv "$out/share/zoneinfo-leaps" "$out/share/zoneinfo/right"
      cp leap-seconds.list "$out/share/zoneinfo/"
      mkdir "$out/share/zoneinfo/posix"; (cd "$out/share/zoneinfo/posix"; ln -s ../* .; rm posix)
      ${chk ''"$out/bin/zdump" -v -c 2026,2027 "$out/share/zoneinfo/America/New_York"'' "2026 UT = .* EDT isdst=1"}
    '';
  };
}
