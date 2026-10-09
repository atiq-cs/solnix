# lib/home-manager-pkgs.nix -- the pkgs a home-manager configuration is evaluated
# with on solnix: lib/host-pkgs.nix (pkgs.solnix.* and the plain-derivation
# writers) plus the nixpkgs-shaped surface home-manager's own modules call.
#
# Why a separate set: NixOS gives home-manager a full nixpkgs, and the
# x86_64-solaris nixpkgs stdenv does not evaluate (home-manager's misc/nixpkgs.nix
# re-imports pkgs.path, which recurses infinitely on x86_64-solaris) and its
# bootstrap is in no cache. This is the same choice mkPkgs makes for systems: plain
# derivations over solnix's own from-source tools, so a user's home builds on the
# host that runs it, with nothing from a Linux builder.
#
# Measured against home-manager db7d5e23 (release-26.05): the module set calls
# lib, path (for nixos/modules/misc/{assertions,meta}.nix), formats, stdenv
# (hostPlatform.isLinux/isDarwin, shellDryRun), runCommand/runCommandLocal with
# passAsFile and stdenv's substituteInPlace, writeTextFile with checkPhase,
# writeShellScript (a #! line), replaceVars, linkFarm, buildEnv with postBuild,
# lndir/xorg.lndir, and the activation PATH tools bash, coreutils, diffutils,
# findutils, gettext, gnugrep, gnused, jq, ncurses. Anything else a module needs
# fails at eval with "attribute ... missing", which names the gap.
#
# Usage (a flake's home configuration for a solnix host):
#   pkgs = import "${solnix}/lib/home-manager-pkgs.nix" {
#     hostPkgs = solnix.lib.mkPkgs { };
#     nixpkgs = nixpkgs.outPath;  # a SOURCE for lib and pkgs-lib; nothing is built from it
#   };
# then homeManagerConfiguration { inherit pkgs; modules = [ ...
#   { _module.args.pkgs = lib.mkForce pkgs; } ]; }  -- the mkForce stops
# home-manager's nixpkgs module from re-importing pkgs.path for the system.
{ hostPkgs, nixpkgs, system ? "x86_64-solaris" }:

let
  lib = import (nixpkgs + "/lib");
  s = hostPkgs.solnix;
  plat = lib.systems.elaborate system;

  # The builders' PATH: the GNU tools home-manager's scripts are written against
  # (realpath -m, ln -T, find -printf ...), ahead of the base OS.
  tools = [ s.coreutils s.findutils s.gnused s.gnugrep s.diffutils s.jq s.lndir s.bash ];
  toolPath = lib.makeBinPath tools + ":/usr/bin:/usr/sbin";
  bashBin = "${s.bash}/bin/bash";

  # stdenv's substituteInPlace / substitute, the --subst-var-by and --replace*
  # forms. Bash parameter expansion, not sed, so a replacement may hold any text
  # (home-manager substitutes multi-line shell into its scripts).
  setup = builtins.toFile "solnix-hm-setup.sh" ''
    substituteStream() {
      local content=$1; shift
      while [ $# -gt 0 ]; do
        case $1 in
          --subst-var-by) content=''${content//"@$2@"/"$3"}; shift 3 ;;
          --replace|--replace-fail|--replace-warn|--replace-quiet)
            content=''${content//"$2"/"$3"}; shift 3 ;;
          *) echo "substitute: unsupported argument $1" >&2; return 1 ;;
        esac
      done
      printf '%s' "$content"
    }
    substitute() {
      local input=$1 output=$2; shift 2
      local content; content=$(cat "$input"; printf x); content=''${content%x}
      if [ -e "$output" ]; then chmod +w "$output"; fi
      substituteStream "$content" "$@" > "$output"
    }
    substituteInPlace() { local f=$1; shift; substitute "$f" "$f" "$@"; }
  '';

  # Attrs a nixpkgs derivation accepts that a bare derivation must not see (they
  # would become env vars at best, or a non-string type error).
  dropAttrs = [ "nativeBuildInputs" "buildInputs" "preferLocalBuild" "allowSubstitutes" "meta" "passthru" ];

  # nativeBuildInputs are honoured the nixpkgs way: their bin/ goes on PATH
  # (home-manager's message catalogue runs gettext's msgfmt, not the base OS one).
  runCommand = name: env: script: derivation ({
    inherit name system;
    builder = bashBin;
    PATH = lib.makeBinPath (env.nativeBuildInputs or [ ]) + ":" + toolPath;
    # errexit only, no nounset/pipefail: what nixpkgs' stdenv leaves set when a
    # build script runs (bash -e, and setup.sh restores the caller's options).
    # home-manager's scripts rely on it (home-files reads an unset
    # seenTargets[...] entry as a test).
    args = [ "-e" "-c" ''
      . ${setup}
      ${script}
    '' ];
  } // builtins.removeAttrs env dropAttrs);

  writeTextFile = { name, text, executable ? false, destination ? "", checkPhase ? "", ... }:
    runCommand name { inherit text; passAsFile = [ "text" ]; } ''
      target=$out${destination}
      mkdir -p "$(dirname "$target")"
      cp "$textPath" "$target"
      ${lib.optionalString executable ''chmod +x "$target"''}
      ${checkPhase}
    '';

  writeShellScript = name: text: writeTextFile {
    inherit name; executable = true;
    text = "#!${bashBin}\n" + text;
    checkPhase = ''${bashBin} -n "$target"'';
  };

  pkgs = hostPkgs // s // {
    inherit lib system runCommand writeTextFile writeShellScript;
    path = nixpkgs;
    config = { };
    overlays = [ ];
    stdenv = {
      inherit system;
      hostPlatform = plat; buildPlatform = plat; targetPlatform = plat;
      inherit (plat) isLinux isDarwin isSunOS;
      shell = bashBin;
      shellDryRun = "${bashBin} -n -O extglob";
    };
    stdenvNoCC = pkgs.stdenv;
    buildPackages = pkgs;
    runtimeShell = bashBin;
    bashInteractive = s.bash;
    runCommandLocal = runCommand;
    writeText = name: text: writeTextFile { inherit name text; };
    writeScript = name: text: writeTextFile { inherit name text; executable = true; };
    writeShellScriptBin = name: text: writeTextFile {
      inherit name; executable = true; destination = "/bin/${name}";
      text = "#!${bashBin}\n" + text;
    };
    replaceVars = src: vars: runCommand (baseNameOf (toString src)) { } (''
      cp ${src} $out
    '' + lib.concatStrings (lib.mapAttrsToList (k: v: ''
      substituteInPlace $out --subst-var-by ${k} ${lib.escapeShellArg (toString v)}
    '') vars));
    linkFarm = name: entries:
      let list = if builtins.isList entries then entries
                 else lib.mapAttrsToList (name: path: { inherit name path; }) entries;
      in runCommand name { } (''
        mkdir -p $out
      '' + lib.concatMapStrings (e: ''
        mkdir -p "$(dirname "$out/${e.name}")"
        ln -s ${e.path} "$out/${e.name}"
      '') list);
    # lib/build-env.nix plus nixpkgs' postBuild hook (home-manager's
    # home.extraProfileCommands), run in the merged tree.
    buildEnv = args:
      let
        env = hostPkgs.buildEnv (builtins.removeAttrs args [ "postBuild" "meta" "passthru" ]);
        post = args.postBuild or "";
      in if post == "" then env else runCommand args.name { } ''
        cp -RP ${env} $out
        chmod -R u+w $out
        ${post}
      '';
    xorg = { inherit (s) lndir; };
  };
in
pkgs // { formats = (import (nixpkgs + "/pkgs/pkgs-lib") { inherit lib pkgs; }).formats; }
