{ config, lib, pkgs, ... }:
# modules/config/release.nix -- release labels: /etc/os-release, /etc/solnix-release,
# solnix-version. The solnix analog of NixOS's misc/version.nix (system.nixos.release,
# codeName, revision, version; /etc/os-release) and installer/tools/nixos-version.sh.
# docs/nixos-parity-audit.md (row 8) and "Cutting 26.11" say how a release changes these.
let
  inherit (lib) mkOption types optionalString optionalAttrs concatStringsSep mapAttrsToList toLower;
  cfg = config.solnix;

  shortRev = if cfg.revision == null then null else builtins.substring 0 7 cfg.revision;
  # "unstable" has no code name of its own; a dated release names one.
  named = cfg.codeName != cfg.release;
  prettyName = "solnix ${cfg.release}${optionalString named " (${cfg.codeName})"}";

  # os-release(5) quoting, as version.nix's attrsToText: bare when alphanumeric.
  quote = s: if builtins.match "[a-zA-Z0-9]+" s != null then s
             else ''"${lib.escape [ "$" "\"" "\\" "`" ] s}"'';
  attrsToText = attrs: concatStringsSep "\n" (mapAttrsToList (n: v: "${n}=${quote v}") attrs) + "\n";

  # NixOS's field set (misc/version.nix osReleaseContents), with solnix's names.
  # ID_LIKE=nixos is what version.nix writes for a distroId other than nixos.
  osRelease = {
    NAME = "solnix";
    ID = "solnix";
    ID_LIKE = "nixos";
    VERSION = "${cfg.release}${optionalString named " (${cfg.codeName})"}";
    VERSION_CODENAME = toLower cfg.codeName;
    VERSION_ID = cfg.release;
    PRETTY_NAME = prettyName;
    HOME_URL = "https://solnix.io/";
    BUG_REPORT_URL = "https://codeberg.org/gregburd/solnix/issues";
    DEFAULT_HOSTNAME = "solnix";
  } // optionalAttrs (cfg.revision != null) { BUILD_ID = shortRev; };

  versionJson = builtins.toJSON ({ solnixVersion = cfg.version; solnixRelease = cfg.release; }
    // optionalAttrs (cfg.revision != null) { solnixRevision = cfg.revision; });

  # nixos-version's interface. Values are fixed at build time, so each generation's
  # copy describes that generation.
  solnixVersion = pkgs.writeScript "solnix-version" ''
    #!/sbin/sh
    # solnix-version -- print this generation's solnix version (nixos-version analog).
    case "''${1:-}" in
      -h|--help)
        echo "usage: solnix-version [--hash|--revision|--json]"; exit 0 ;;
      --hash|--revision)
        ${if cfg.revision == null
          then ''echo "$0: solnix revision is unknown" >&2; exit 1''
          else ''echo '${cfg.revision}' ''} ;;
      --json)
        cat <<'EOF'
    ${versionJson}
    EOF
        ;;
      *)
        echo '${cfg.version}${optionalString named " (${cfg.codeName})"}' ;;
    esac
  '';
in
{
  options.solnix = {
    release = mkOption {
      type = types.str;
      default = "unstable";
      example = "26.11";
      description = ''
        The solnix release (system.nixos.release). "unstable" on main; a release
        branch sets its dated value ("26.11").
      '';
    };
    codeName = mkOption {
      type = types.str;
      default = cfg.release;
      defaultText = lib.literalExpression "config.solnix.release";
      description = "Release code name (system.nixos.codeName); a dated release names one.";
    };
    revision = mkOption {
      type = types.nullOr types.str;
      # a git checkout knows its HEAD; a flake's source copy has no .git, so a flake
      # caller passes self.rev (as nixpkgs' flake sets system.nixos.revision).
      default = if builtins.pathExists ../../.git then lib.sources.commitIdFromGitRepo ../../.git else null;
      defaultText = lib.literalExpression "the HEAD of the solnix checkout, or null";
      description = "The solnix git revision this system was built from (system.nixos.revision).";
    };
    version = mkOption {
      type = types.str;
      readOnly = true;
      default = cfg.release + optionalString (cfg.revision != null) ".${shortRev}";
      description = "The full solnix version, release plus short revision (system.nixos.version).";
    };
  };

  config = {
    environment.generatedEtc."os-release" = attrsToText osRelease;
    # the shell-sourceable stamp scripts read (scripts/solnix-selftest: EDITION;
    # pgfarm: ROLES).
    environment.generatedEtc."solnix-release" = ''
      NAME=solnix
      ID=solnix
      RELEASE=${cfg.release}
      VERSION=${cfg.version}
      VERSION_ID=${cfg.release}
      EDITION=${cfg.edition}
      REVISION=${if cfg.revision == null then "" else cfg.revision}
      ROLES=${concatStringsSep "," cfg.roles}
    '';
    environment.systemPackages = [
      (pkgs.runCommand "solnix-version-bin" { } ''
        mkdir -p $out/bin; ln -s ${solnixVersion} $out/bin/solnix-version
      '')
    ];
  };
}
