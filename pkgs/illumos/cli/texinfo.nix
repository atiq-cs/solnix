# cli/texinfo.nix -- GNU Texinfo 7.3: info(1), install-info(1), makeinfo/texi2any (NixOS: documentation.info.enable
# installs texinfoInteractive, i.e. texinfo with ncurses, and runs install-info over the system profile's share/info).
# Own file so no existing cli out moves. As nixpkgs common.nix: PERL= the store perl, perl XS off is NOT needed (native).
{ mkSrcPkg, world, ncurses, perl, gnum4, chk, hostTools, ... }:
{
  texinfo = mkSrcPkg {
    pname = "texinfo"; version = "7.3";
    src = { url = "https://mirrors.kernel.org/gnu/texinfo/texinfo-7.3.tar.xz";
            sha256 = "51f74eb0f51cfa9873b85264dfdd5d46e8957ec95b88f0fb762f63d9e164c72e"; };
    deps = [ world ncurses perl ];   # world: the XS modules NEED libgen.so.1, which the libc slice does not carry (recipes3)
    nativeTools = [ perl gnum4 ] ++ hostTools;   # store-only PATH + config.site, as the other cli recipes (wave4)
    build = ''
      ./configure --prefix="$out" --disable-nls PERL=${perl}/bin/perl
      gmake -j8; gmake install
      # libintl-perl's .pm modules start "#! /bin/false" (a guard, the files are not executable; the publish gate's B9 skips them, wave6's
      # out-host-refs.sh does not): blank that line, as nothing runs them by their #! (recipes3)
      n=0; for f in $(grep -rlE '^#![[:space:]]*/bin/false' "$out/share/texi2any" 2>/dev/null); do [ -x "$f" ] && continue
        head -1 "$f" | grep -qE '^#![[:space:]]*/bin/false[[:space:]]*$' || continue; sed -i '1s|.*|#|' "$f"; n=$((n+1)); done
      [ "$n" -gt 0 ] || { echo "FATAL: texinfo: no #! /bin/false guard found (anchor)" >&2; exit 1; }
      ${chk ''"$out/bin/info" --version'' "^info \\(GNU texinfo\\) 7\\.3"}
      ${chk ''"$out/bin/install-info" --version'' "^install-info \\(GNU texinfo\\) 7\\.3"}
      # the info reader must have its terminal library (configure drops info/ silently without one)
      [ -x "$out/bin/info" ] && [ -f "$out/share/info/info-stnd.info" ] || { echo "FATAL: no info reader / info-stnd.info" >&2; exit 1; }
      # makeinfo writes a manual, install-info gives it a dir entry, info reads it back non-interactively. info always
      # searches its own share/info too, so the control uses a manual that texinfo does not ship (solnixcheck).
      T=$(mktemp -d /var/tmp/ti.XXXXXX); mkdir "$T/with" "$T/without"
      printf '\\input texinfo\n@setfilename solnixcheck.info\n@settitle S\n@dircategory Solnix\n@direntry\n* Solnixcheck: (solnixcheck).  A check.\n@end direntry\n@node Top\n@top S\nsolnixcheck body text\n@bye\n' > "$T/s.texi"
      "$out/bin/makeinfo" -o "$T/with/solnixcheck.info" "$T/s.texi"
      "$out/bin/install-info" "$T/with/solnixcheck.info" "$T/with/dir"
      grep -q '^\* Solnixcheck: (solnixcheck)' "$T/with/dir" || { echo "FATAL: install-info wrote no entry" >&2; cat "$T/with/dir" >&2; exit 1; }
      INFOPATH="$T/with" "$out/bin/info" --output=- solnixcheck 2>&1 | grep -q 'solnixcheck body text' \
        || { echo "FATAL: info could not read solnixcheck" >&2; exit 1; }
      INFOPATH="$T/without" "$out/bin/info" --output=- solnixcheck 2>&1 | grep -q 'solnixcheck body text' \
        && { echo "FATAL: negative control: info found solnixcheck on a path without it" >&2; exit 1; }
      echo "CHECK-OK: makeinfo + install-info dir entry + info reads it; negative control empty" >&2
    '';
  };
}
