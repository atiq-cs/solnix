# desktop/help.nix -- "get help" on the COSMIC desktop. COSMIC 1.5 has no help system (no yelp, no help: or man: URI
# handler, no launcher plugin for manuals), and NixOS's cosmic module adds none, so this is NixOS's own pieces:
#   * solnix-help + "Solnix Manual" desktop entry: NixOS's nixos-help + its desktopItem (opens the docs in a browser);
#   * solnix-man-open + a desktop entry with MimeType=x-scheme-handler/man: `xdg-open man:ls` shows ls(1) in a terminal;
#   * pop-launcher-man + plugin.ron: "man <word>" in the COSMIC launcher lists matching pages (upstream pop-launcher
#     has this only as toolkit/examples/man-pages-plugin.rs); the module links plugin.ron into /etc/pop-launcher.
# Scripts only, store bash and jq on their #! and paths. Own file (desktop/), so no COSMIC drv moves.
{ bash, coreutils, gnused, gnugrep, jq }:
derivation {
  name = "solnix-help-1"; system = "x86_64-solaris"; builder = "${bash}/bin/bash";
  src = ./help;
  PATH = "${coreutils}/bin:${gnused}/bin:${gnugrep}/bin";
  args = [ "-c" ''
    set -eu
    mkdir -p "$out/bin" "$out/libexec" "$out/share/applications" "$out/share/pop-launcher/plugins/man"
    for f in solnix-man-open solnix-help; do
      sed '1s|^#!.*|#!${bash}/bin/bash|' "$src/$f" > "$out/bin/$f"; chmod 0555 "$out/bin/$f"
    done
    sed -e '1s|^#!.*|#!${bash}/bin/bash|' -e 's|@jq@|${jq}/bin/jq|' -e "s|@open@|$out/bin/solnix-man-open|" \
      "$src/pop-launcher-man" > "$out/libexec/pop-launcher-man"; chmod 0555 "$out/libexec/pop-launcher-man"
    sed "s|@out@|$out|" "$src/plugin.ron" > "$out/share/pop-launcher/plugins/man/plugin.ron"
    cp "$src/solnix-manual.desktop" "$src/solnix-man.desktop" "$out/share/applications/"
    ! grep -q '@[a-z]*@' "$out/libexec/pop-launcher-man" "$out/share/pop-launcher/plugins/man/plugin.ron" \
      || { echo "FATAL: unsubstituted @var@" >&2; exit 1; }

    # checks. 1: the man: handler turns URIs into a man command and REFUSES anything that is not a page name
    o() { SOLNIX_MAN_OPEN_PRINT=1 "$out/bin/solnix-man-open" "$1"; }
    [ "$(o man:ls)" = "man ls" ] && [ "$(o 'man:printf(3c)')" = "man -s 3c printf" ] && [ "$(o man://zfs)" = "man zfs" ] \
      || { echo "FATAL: solnix-man-open URI parsing" >&2; exit 1; }
    for bad in 'man:ls;id' 'man:$(id)' 'man:-P/bin/sh' 'man:ls(1;id)' 'man:'; do
      o "$bad" > /dev/null 2>&1 && { echo "FATAL: solnix-man-open accepted $bad" >&2; exit 1; }
    done
    # 2: the launcher plugin speaks pop-launcher's protocol: Search -> Append + Finished, Activate -> Close, and a
    # query with no match (the negative control) appends nothing. A stand-in man answers whatis/apropos.
    W=$(mktemp -d); mkdir "$W/bin"
    printf '#!${bash}/bin/bash\ncase "$2" in ls) echo "ls(1)                    - list contents of directory";; *) :;; esac\n' > "$W/bin/man"
    chmod +x "$W/bin/man"
    r=$(printf '{"Search":"man ls"}\n{"Search":"man nosuchpage"}\n{"Search":"man ;id"}\n"Exit"\n' | PATH="$W/bin:$PATH" "$out/libexec/pop-launcher-man")
    [ "$(echo "$r" | grep -c '"Append"')" = 1 ] && echo "$r" | grep -q '"name":"ls(1)"' \
      && echo "$r" | grep -q '"description":"list contents of directory"' && [ "$(echo "$r" | grep -c '^"Finished"$')" = 3 ] \
      || { echo "FATAL: pop-launcher-man protocol:" >&2; echo "$r" >&2; exit 1; }
    r=$(printf '{"Search":"man ls"}\n{"Activate":0}\n"Exit"\n' | PATH="$W/bin:$PATH" TERMINAL=true "$out/libexec/pop-launcher-man")
    echo "$r" | grep -q '^"Close"$' || { echo "FATAL: pop-launcher-man Activate" >&2; echo "$r" >&2; exit 1; }
    echo "CHECK-OK: man: URIs parsed, 5 bad URIs refused; plugin Search/Activate; no-match control appends nothing" >&2
  '' ];
}
