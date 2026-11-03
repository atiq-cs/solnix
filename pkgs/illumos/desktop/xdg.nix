# desktop/xdg.nix -- xdg-utils and xdg-user-dirs (NixOS: services.graphical-desktop's xdg-utils, the cosmic module's
# xdg-user-dirs). Both are small; neither needs glib.
{ mkSrcPkg, bash, coreutils, gnugrep, gnused, file, hostname, hostTools }:
let
  rt = "${bash}/bin:${coreutils}/bin:${gnugrep}/bin:${gnused}/bin:${file}/bin:${hostname}/bin";
  gate = if hostTools == [ ] then "" else "/usr/bin/bash ${../path-gate.sh}";   # seed instance (hostTools []): host PATH, no gate
in {
  # xdg-utils 1.2.1 (scripts only; the man pages need xmlto + docbook, not built here). As nixpkgs (resholve), each script
  # gets store bash and a runtime PATH ahead of the caller's: GNU coreutils for realpath/readlink -f (illumos has neither)
  # and libmagic's `file`, whose --mime-type xdg-mime's generic path calls as /usr/bin/file (illumos file has no
  # --mime-type). The usage/manual text comes from the .txt files xmlto would write; here the scripts get empty ones.
  xdg-utils = mkSrcPkg {
    pname = "xdg-utils"; version = "1.2.1";
    src = { url = "https://gitlab.freedesktop.org/xdg/xdg-utils/-/archive/v1.2.1/xdg-utils-v1.2.1.tar.gz";
            sha256 = "f6b648c064464c2636884c05746e80428110a576f8daacf46ef2e554dcfdae75"; };
    nativeTools = hostTools;   # store-only PATH (the OI host's /usr/gnu awk/sed/install otherwise; gtkfix)
    build = ''
      ${gate}
      cd scripts; mkdir -p "$out/bin"
      for s in xdg-desktop-menu xdg-desktop-icon xdg-mime xdg-icon-resource xdg-open xdg-email xdg-screensaver xdg-settings; do
        : > "$s.txt"
        awk -f generate-help-script.awk "$s.in" | sed -e "s/@NAME@/$s/g" \
          -e '1s|^#!.*|#!${bash}/bin/bash|' -e 's|/usr/bin/file |file |' > "$out/bin/$s"
        # the runtime PATH, right after the shebang
        sed -i '1a PATH=${rt}:$PATH' "$out/bin/$s"; chmod 0555 "$out/bin/$s"
        ! grep -q '/usr/bin/file' "$out/bin/$s" || { echo "FATAL: $s still calls /usr/bin/file" >&2; exit 1; }
      done
      # in-build check: xdg-mime finds a text file's type through libmagic, and a .desktop-declared default
      T=$(mktemp -d); printf 'hello\n' > "$T/a.txt"
      [ "$(HOME=$T XDG_DATA_DIRS=$T "$out/bin/xdg-mime" query filetype "$T/a.txt")" = text/plain ] || { echo "FATAL: xdg-mime filetype" >&2; exit 1; }
      mkdir -p "$T/applications"; printf '[Desktop Entry]\nType=Application\nName=T\nExec=true %%f\nMimeType=text/plain;\n' > "$T/applications/t.desktop"
      printf '[Default Applications]\ntext/plain=t.desktop\n' > "$T/applications/mimeapps.list"
      [ "$(HOME=$T XDG_DATA_DIRS=$T XDG_CONFIG_HOME=$T/c "$out/bin/xdg-mime" query default text/plain)" = t.desktop ] || { echo "FATAL: xdg-mime default" >&2; exit 1; }
      [ -z "$(HOME=$T XDG_DATA_DIRS=$T/none XDG_CONFIG_HOME=$T/c "$out/bin/xdg-mime" query default text/plain)" ] || { echo "FATAL: negative control" >&2; exit 1; }
      echo "CHECK-OK: xdg-mime filetype + default; negative control empty" >&2
    '';
  };

  # xdg-user-dirs 0.20: xdg-user-dirs-update (writes ~/.config/user-dirs.dirs, makes ~/Documents ...) and xdg-user-dir, plus
  # the config and the XDG autostart entry that runs it at login. meson's build is two executables, so plain $CC here;
  # no NLS (English folder names), so no libintl. XDGCONFDIR is the store's etc/xdg; XDG_CONFIG_DIRS overrides it.
  xdg-user-dirs = mkSrcPkg {
    pname = "xdg-user-dirs"; version = "0.20";
    src = { url = "https://user-dirs.freedesktop.org/releases/xdg-user-dirs-0.20.tar.xz";
            sha256 = "b8e34286278f4fef3e1bfe9685c395ccc0eb50c14d3a2fb4953dd00fbfd3af39"; };
    nativeTools = hostTools;   # store-only PATH: GNU install from the store coreutils, not /usr/gnu/bin's (gtkfix)
    build = ''
      ${gate}
      # meson's iconv probe: does iconv() take const char ** here?
      printf '#include <iconv.h>\nint main(void){iconv_t c=0;const char *i=0;char *o=0;size_t a=0,b=0;return (int)iconv(c,&i,&a,&o,&b);}\n' > ic.c
      ic=; $CC -Werror -c ic.c -o ic.o 2>/dev/null && ic=const
      printf '#define PACKAGE "xdg-user-dirs"\n#define VERSION "0.20"\n#define GETTEXT_PACKAGE "xdg-user-dirs"\n#define XDGCONFDIR "%s/etc/xdg"\n#define LOCALEDIR "%s/share/locale"\n#define ICONV_CONST %s\n' "$out" "$out" "$ic" > config.h
      mkdir -p "$out/bin" "$out/etc/xdg/autostart"
      $CC -O2 -DHAVE_CONFIG_H -I. -o "$out/bin/xdg-user-dirs-update" src/xdg-user-dirs-update.c
      $CC -O2 -DHAVE_CONFIG_H -I. -o "$out/bin/xdg-user-dir" src/xdg-user-dir.c src/xdg-user-dir-lookup.c
      install -m0644 data/user-dirs.conf data/user-dirs.defaults "$out/etc/xdg/"
      install -m0644 data/xdg-user-dirs.desktop "$out/etc/xdg/autostart/"
      T=$(mktemp -d)
      HOME=$T XDG_CONFIG_HOME=$T/c "$out/bin/xdg-user-dirs-update"
      grep -q '^XDG_DOCUMENTS_DIR="$HOME/Documents"' "$T/c/user-dirs.dirs" && [ -d "$T/Documents" ] || { echo "FATAL: user-dirs.dirs" >&2; exit 1; }
      [ "$(HOME=$T XDG_CONFIG_HOME=$T/c "$out/bin/xdg-user-dir" DOWNLOAD)" = "$T/Downloads" ] || { echo "FATAL: xdg-user-dir" >&2; exit 1; }
      echo "CHECK-OK: xdg-user-dirs-update + xdg-user-dir" >&2
    '';
  };
}
