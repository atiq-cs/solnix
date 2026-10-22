{ config, lib, pkgs, ... }:
# modules/config/nix-channel.nix -- what `<solnix>`, `nix-env -iA solnix.<pkg>`,
# `nix-shell -p <pkg>` and `nix profile install solnix#<pkg>` need on a fresh system:
# NIX_PATH, the root channel subscription, and the system flake registry. The solnix
# analog of NixOS's config/nix-channel.nix, misc/nixpkgs-flake.nix and the
# nix.registry half of config/nix-flakes.nix.
#
# Where solnix departs from NixOS, and why:
# - nixpkgs= names solnix's OWN package set. On NixOS <nixpkgs> is the nixpkgs the
#   system was built with. On x86_64-solaris nixpkgs' stdenv does not evaluate
#   (home-manager-pkgs.nix: misc/nixpkgs.nix re-imports pkgs.path and recurses) and
#   its bootstrap is in no cache, so `nix-shell -p htop` against it can never work.
#   The packages that DO build here are pkgs.solnix.*, so <nixpkgs> and <solnix>
#   both resolve to the expression that returns them, and `nix-shell -p htop`
#   finds solnix's htop. (nix-shell -p also needs pkgs.mkShell/runCommandCC from
#   nixpkgs' stdenv; the expression does not have them, so -p is NOT expected to
#   work yet -- measured, see docs/nixos-parity-audit.md.)
# - The channel expression is IN the system closure (a store path, as NixOS's
#   flake-built systems pin nixpkgs.flake.source), not a downloaded tarball, so
#   NIX_PATH works with no network and matches the running generation. A root
#   subscription to the release channel is still written to /root/.nix-channels,
#   as NixOS does, so `nix-channel --update` moves to newer packages.
let
  inherit (lib) mkOption mkIf types concatStringsSep;
  cfg = config.nix;

  # The package-set expression: this tree's default.nix (import <solnix> {} =
  # pkgs.solnix), copied with only what pkgs/illumos reads at evaluation time.
  # builtins.path, so it is a content-addressed source like NixOS's pinned
  # nixpkgs.flake.source, not a build.
  root = ../..;
  # docs/: only the two registry tables pkgs/illumos reads (cached.nix, starter.nix);
  # the rest of docs/registry is audit output (tens of MB) nothing evaluates.
  # scripts/: only what pkgs/illumos imports (../../scripts/...).
  keepDocs = [ "registry" "registry/arch-manifest.tsv" "registry/real-derivations.tsv" ];
  keepScripts = [ "patches" "oi-cc-wrapper.sh" "oi-closure.sh" "oi-gate-slices.sh"
                  "oi-smf-gates.sh" "oi-world-slices.sh" "gate-c-hello.sh" ];
  # The install-root flake, on the git host, at the SUPPORTED EDITION branch: so
  # `solnix#tmux` gives the edition's build. It follows solnix.release (26.11, ...)
  # and falls to the rolling `unstable` branch only for an unstable system.
  solnixFlake = {
    type = "git";
    url = "https://git.solnix.io/solnix.git";
    ref = if config.solnix.release == "unstable" then "unstable" else config.solnix.release;
  };
  channelSrc = builtins.path {
    name = "solnix-channel";
    path = root;
    filter = p: _t:
      let rel = lib.removePrefix (toString root + "/") (toString p);
          parts = lib.splitString "/" rel;
          top = builtins.head parts;
          rest = lib.concatStringsSep "/" (builtins.tail parts);
      in if builtins.length parts == 1 then builtins.elem top [ "default.nix" "lib" "pkgs" "scripts" "docs" ]
         else if top == "docs" then builtins.elem rest keepDocs
         else if top == "scripts" then builtins.elem (builtins.head (builtins.tail parts)) keepScripts
         else builtins.elem top [ "lib" "pkgs" ];
  };
  # the derivation nix-env installs into root's channels profile: one directory
  # per channel name, holding the expression (<profile>/<name>/default.nix).
  # `nixos` is the name NixOS gives its system channel, so the NixOS manual's
  # `nix-env -iA nixos.hello` works here too; `solnix` stays as the explicit name.
  channelTree = pkgs.runCommand "solnix-channel-tree" { src = channelSrc; } ''
    mkdir -p $out; ln -s $src $out/solnix; ln -s $src $out/nixos
  '';
in
{
  options = {
    nix.channel.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether the nix-channel state is set up (NixOS nix.channel.enable): the root
        channel subscription in /root/.nix-channels, and NIX_PATH entries naming
        the channels profile.
      '';
    };
    nix.nixPath = mkOption {
      type = types.listOf types.str;
      default = [
        "solnix=${channelSrc}"
        "nixpkgs=${channelSrc}"
      ] ++ lib.optional cfg.channel.enable "/nix/var/nix/profiles/per-user/root/channels";
      defaultText = lib.literalExpression ''
        [ "solnix=<this generation's package set>" "nixpkgs=<the same>" ]
        ++ optional nix.channel.enable "/nix/var/nix/profiles/per-user/root/channels"'';
      description = "The default Nix search path (NIX_PATH), as NixOS's nix.nixPath.";
    };
    nix.registry = mkOption {
      type = types.attrsOf (types.attrsOf types.anything);
      default = { };
      example = lib.literalExpression ''{ solnix.to = { type = "git"; url = "git+https://git.solnix.io/solnix.git"; }; }'';
      description = ''
        The system flake registry, written to /etc/nix/registry.json (NixOS
        nix.registry). Each entry is <name>.to = <flake reference attrs>.
      '';
    };
    system.defaultChannel = mkOption {
      internal = true;
      type = types.str;
      default = "https://codeberg.org/solnix/solnix/archive/${
        if config.solnix.release == "unstable" then "unstable" else config.solnix.release}.tar.gz";
      description = ''
        The channel root is subscribed to (NixOS system.defaultChannel). "unstable"
        follows main, a dated release its release-YY.MM branch.
      '';
    };
    system.build.solnixChannel = mkOption {
      internal = true;
      type = types.unspecified;
      description = "The package-set expression NIX_PATH names (solnix= and nixpkgs=).";
    };
  };

  config = mkIf cfg.enable {
    system.build.solnixChannel = channelSrc;

    # The `solnix` indirect flake ref: `nix ... solnix#<name>` resolves to the
    # install-root flake (pkgs.solnix.<name>) served from git.solnix.io over
    # anonymous-read HTTPS. The install root is solnix.git (it composes the full
    # pkgs.solnix.* world; solnix-pkgs.git is only its bootstrap-overlay input).
    nix.registry.solnix.to = lib.mkDefault solnixFlake;
    # `nixpkgs` on solnix is solnix's package set, as NixOS points it at the system's
    # own nixpkgs (nixos/modules/misc/nixpkgs-flake.nix: nix.registry.nixpkgs.to).
    # So the NixOS manual's `nix shell nixpkgs#hello` installs solnix's hello. The
    # solnix flake is a superset of nixpkgs' outputs (lib, legacyPackages for every
    # system), so a third-party flake whose nixpkgs input resolves here still finds
    # nixpkgs.lib and, on Linux/macOS, plain nixpkgs packages.
    nix.registry.nixpkgs.to = lib.mkDefault solnixFlake;

    # NixOS: environment.sessionVariables.NIX_PATH = nix.nixPath, plus the
    # per-user channels first when the user has any.
    environment.sessionVariables.NIX_PATH = cfg.nixPath;
    environment.extraInit = mkIf cfg.channel.enable ''
      if [ -e "$HOME/.nix-defexpr/channels" ]; then
        NIX_PATH="$HOME/.nix-defexpr/channels''${NIX_PATH:+:$NIX_PATH}"; export NIX_PATH
      fi
    '';

    nix.generatedEtc."nix/registry.json" = builtins.toJSON {
      version = 2;
      flakes = lib.mapAttrsToList (n: v: { from = { type = "indirect"; id = n; }; inherit (v) to; }) cfg.registry;
    };

    # NixOS writes /root/.nix-channels with a tmpfiles `f` rule (create if
    # absent, never overwrite). install-be does the same from this file.
    environment.generatedEtc."solnix/root-nix-channels" =
      mkIf cfg.channel.enable "${config.system.defaultChannel} solnix\n";

    # nix-env -iA reads ~/.nix-defexpr, not NIX_PATH: its top-level attributes are
    # the channels in root's channels profile (~/.nix-defexpr/channels_root, which
    # nix creates for every user). NixOS puts the system's own nixpkgs there
    # (installer/cd-dvd/channel.nix's nix-channel-init, nixos-install's channel
    # copy), so `nix-env -iA nixos.hello` works before any nix-channel --update.
    # The same here, once per system: install the channel expression into root's
    # channels profile as `solnix`, so `nix-env -iA solnix.htop` works for root and
    # every user. Never repeated, so an admin's nix-channel --update wins.
    smf.services.solnix-channel-init = mkIf cfg.channel.enable {
      enable = true;
      category = "system";
      description = "solnix: root's channels profile gets this system's package set (nix-channel-init)";
      model = "transient";
      requires = [ "svc:/system/filesystem/local:default" ];
      start.exec = "${pkgs.writeScript "solnix-channel-init" ''
        #!/sbin/sh
        . /lib/svc/share/smf_include.sh
        stamp=/var/lib/solnix/did-channel-init
        [ -e "$stamp" ] && exit $SMF_EXIT_OK
        P=/nix/var/nix/profiles/per-user/root
        mkdir -p "$P" /var/lib/solnix || exit $SMF_EXIT_ERR_FATAL
        # a channel is a directory named for the channel holding the expression
        # (nix-channel --update unpacks the same shape).
        ${cfg.package}/bin/nix-env -p "$P/channels" -i ${channelTree} --quiet \
          --option build-use-substitutes false > /dev/msglog 2>&1 || exit $SMF_EXIT_ERR_FATAL
        mkdir -p /root/.nix-defexpr && chmod 0700 /root/.nix-defexpr
        [ -h /root/.nix-defexpr/channels ] || ln -s "$P/channels" /root/.nix-defexpr/channels
        touch "$stamp"
        exit $SMF_EXIT_OK
      ''}";
      start.timeoutSeconds = 300;
      stop.exec = ":true";
    };
  };
}
