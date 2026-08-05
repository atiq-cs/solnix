{ config, lib, ... }:
# modules/config/first-boot-defaults.nix — the "feels like a finished OS" defaults
# a fresh NixOS install gets, adapted to native illumos mechanisms. See
# docs/design-first-boot-defaults.md for the full audit. Tier-1 + Tier-2 here.
let
  cfg = config.solnix.defaults;
in
{
  options.solnix.defaults = {
    enable = lib.mkOption { type = lib.types.bool; default = true; };
    timeZone = lib.mkOption {
      type = lib.types.str; default = "UTC";
      description = "Default time zone (illumos reads TZ from /etc/default/init).";
    };
    locale = lib.mkOption {
      type = lib.types.str; default = "en_US.UTF-8";
      description = "Default LANG (illumos ships en_US.UTF-8).";
    };
    ntpServer = lib.mkOption {
      type = lib.types.str; default = "169.254.169.123";
      description = "NTP source. EC2 provides a link-local NTP at 169.254.169.123.";
    };
  };

  config = lib.mkIf cfg.enable {
    # 1+2. Timezone + locale via /etc/default/init (read by init + login for TZ/LANG).
    environment.generatedEtc."default/init" = ''
      TZ=${cfg.timeZone}
      LANG=${cfg.locale}
      LC_ALL=${cfg.locale}
      UMASK=022
    '';

    # Also export LANG in the login env (belt-and-suspenders for both shells).
    environment.variables = {
      LANG = cfg.locale;
      TZ = cfg.timeZone;
    };

    # 5. `sudo` -> pfexec shim: illumos uses RBAC/pfexec for privilege escalation,
    # but muscle-memory + many scripts type `sudo`. Define a POSIX-sh function
    # (works in bash + ksh93) so `sudo <cmd>` runs `pfexec <cmd>`. Only defined if
    # a real sudo isn't on PATH (a user who installs the sudo package wins).
    environment.shellInit = ''
      if ! command -v sudo >/dev/null 2>&1; then
        sudo() { pfexec "$@"; }
      fi
    '';

    # 4. MOTD — a helpful first-login message (edition + how to install + docs).
    environment.generatedEtc."motd" = ''
      solnix ${config.solnix.edition or "unstable"} (illumos + Nix)

        install a package:   nix profile install nixpkgs#<name>
        list installed:      nix profile list
        admin (root):        pfexec <cmd>   (or: sudo <cmd>)
        docs:                https://solnix.io

    '';

    # 6. Nix GC + store optimise so /nix doesn't grow unbounded (NixOS weekly-GC analog).
    nix.settings = {
      auto-optimise-store = lib.mkDefault true;
      min-free = lib.mkDefault (128 * 1024 * 1024);   # start GC under 128MB free
      max-free = lib.mkDefault (1024 * 1024 * 1024);   # free up to 1GB
    };

    # 3 (NTP) + the SMF nix-gc timer + logadm(/var/cores) are wired as SMF services in
    # the activation layer (they need manifests, not just /etc files) — see
    # docs/design-first-boot-defaults.md T1.3/T2.6/T2.7. Declared here as intent;
    # the SMF generator picks them up.
  };
}
