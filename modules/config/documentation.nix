# modules/config/documentation.nix — man pages, the man index, info pages, system-wide.
#
# The solnix analog of NixOS's misc/documentation.nix (+ mandoc.nix / man-db.nix). Goal: on every installed system
# and installer image, `man <tool>`, `man -k`, `whatis` and `info` work for the illumos base tools and every package
# in the system and user profiles, in every context (login shell, `ssh host cmd`, sudo/pfexec, cron, SMF methods).
#
# WHAT PROVIDES WHAT (measured; docs/man-and-debug-delivery.md):
#   * man, apropos, whatis and the whatis generator (`man -w`) are the gate's /usr/bin/man (pkgs.solnix.world);
#     man(1) formats with mandoc(1).
#   * Package pages: each package's $out/share/man, linked into sw/share/man (pathsToLink "/share/man") and
#     ~/.nix-profile/share/man. The login MANPATH (shell-environment.nix) lists every profile's share/man.
#   * The illumos BASE pages: pkgs.solnix.worldMan (mk-proto-world leaves usr/share/man out of the world).
#   * Without MANPATH (cron's job environment is HOME LOGNAME PATH SHELL TZ only, cron.c envinit; `ssh host cmd` runs
#     a non-login bash): illumos man derives the path from PATH and maps /usr/bin, /usr/sbin and /sbin BY INODE to
#     /usr/share/man (man.c bintoman[]). install-be lays /usr/share/man -> sw/share/man (and info), which is the
#     illumos form of NixOS man-db's `MANPATH_MAP /run/current-system/sw/bin /run/current-system/sw/share/man`.
#   * The index: illumos apropos/whatis/`man -k` read a plain-text <mandir>/whatis (man.c whatapro), which
#     `man -w -M <dir>` writes. NixOS's documentation.man.cache.enable builds the cache into the store at system build
#     time; man.cache.enable does the same into sw/share/man/whatis (environment.extraSetup).
#   * /etc/man.conf is not written: illumos man(1) never opens it, and mandoc(1) reads only lowercase `manpath`
#     lines, so the MANPATH lines this module wrote were read by nothing.
#   * info: texinfo's info/install-info; the profile's share/info/dir is rebuilt at system build time from every
#     *.info in it (NixOS documentation.info.enable). info's compiled default path includes /usr/share/info.

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption mkIf mkMerge types;
  cfg = config.documentation;
  man = "${pkgs.solnix.world}/bin/man";
in
{
  imports = [
    (lib.mkRenamedOptionModule [ "documentation" "man" "generateCaches" ] [ "documentation" "man" "cache" "enable" ])
    (lib.mkRemovedOptionModule [ "documentation" "man" "manPath" ]
      "illumos man(1) never reads /etc/man.conf; /usr/share/man is the system profile's share/man (install-be).")
  ];

  options.documentation = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Master switch for installing documentation. NixOS's documentation.enable.";
    };

    man.enable = mkOption {
      type = types.bool;
      default = cfg.enable;
      description = ''
        Install man pages and make `man` work for the base illumos tools and every profile package.
        NixOS's documentation.man.enable.
      '';
    };

    man.cache.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Build the man page index (sw/share/man/whatis) at system build time, so `man -k`, apropos(1) and
        whatis(1) work. NixOS's documentation.man.cache.enable (default false there too; base.nix turns it on).
      '';
    };

    info.enable = mkOption {
      type = types.bool;
      default = cfg.enable;
      description = ''
        Install info pages, the info reader and install-info, and build sw/share/info/dir at system build time.
        NixOS's documentation.info.enable.
      '';
    };

    doc.enable = mkOption {
      type = types.bool;
      default = cfg.enable;
      description = ''
        Link packages' share/doc into the system profile. NixOS's documentation.doc.enable. solnix packages keep
        one output, and most of them delete share/doc today; this delivers what is there.
      '';
    };
  };

  config = mkIf cfg.enable (mkMerge [
    (mkIf cfg.man.enable {
      # Base illumos man pages into the system profile (-> sw/share/man).
      environment.systemPackages = [ pkgs.solnix.worldMan ];
      # NixOS sets this from documentation.man.enable; solnix packages keep man in $out, so it only matters for a
      # package that splits a `man` output (system-path.nix adds it when the package has one).
      environment.extraOutputsToInstall = [ "man" ];   # "/share/man" is in system-path.nix's base pathsToLink
    })

    # The index, in the composed profile, as NixOS's man-db/mandoc modules do. sw/share/man is a tree of directories
    # (buildEnv makes real dirs and links the leaves), so the whatis file lands in the profile's own store path.
    # `man -w` follows the page links; a page link that dangles (worldMan carries a few) is only warned about.
    (mkIf (cfg.man.enable && cfg.man.cache.enable) {
      environment.extraSetup = ''
        if [ -d "$out/share/man" ]; then
          ${man} -w -M "$out/share/man" 2>/dev/null || true
          [ -s "$out/share/man/whatis" ] || { echo "FATAL: man -w wrote no $out/share/man/whatis" >&2; exit 1; }
          echo "man index: $(wc -l < "$out/share/man/whatis") whatis entries" >&2
        fi
      '';
    })

    (mkIf cfg.info.enable {
      environment.systemPackages = [ pkgs.solnix.texinfo ];
      environment.extraOutputsToInstall = [ "info" ];   # "/share/info" is in system-path.nix's base pathsToLink
      # NixOS documentation.nix: install-info over every *.info, into a dir file of the profile's own (each package's
      # `dir`, linked in by the merge, would otherwise win by link order and list only that package).
      environment.extraSetup = ''
        if [ -d "$out/share/info" ]; then
          rm -f "$out/share/info/dir"
          n=0
          for i in "$out"/share/info/*.info "$out"/share/info/*.info.gz; do
            [ -e "$i" ] || continue
            ${pkgs.solnix.texinfo}/bin/install-info "$i" "$out/share/info/dir" 2>/dev/null && n=$((n+1)) || true
          done
          [ "$n" -eq 0 ] || [ -s "$out/share/info/dir" ] || { echo "FATAL: install-info wrote no $out/share/info/dir" >&2; exit 1; }
          echo "info dir: $n manuals" >&2
        fi
      '';
    })

    (mkIf cfg.doc.enable {
      environment.extraOutputsToInstall = [ "doc" ];
      environment.pathsToLink = [ "/share/doc" ];
    })
  ]);
}
