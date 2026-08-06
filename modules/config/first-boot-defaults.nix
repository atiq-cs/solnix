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
    enableStockServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Stock base-OS SMF services (FMRIs like "network/ntp") to `svcadm enable`
        at image build / first boot. For SERVICES SHIPPED BY THE OS (ntp, ipfilter),
        not generated manifests. The image builder + activation enable these.
      '';
    };
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

    # 5. `sudo` -> pfexec: illumos uses RBAC/pfexec for privilege escalation, but
    # muscle-memory + many scripts type `sudo`. A shell FUNCTION only helps
    # interactive shells that source this (not scripts or exec'd programs, and
    # ksh93 doesn't inherit it), so the image ALSO installs a real /usr/bin/sudo
    # wrapper file (see oi-make-declarative-be.sh). The function below is a
    # belt-and-suspenders for interactive shells; the wrapper is the real mechanism.
    # Only active if a real sudo isn't on PATH (a user who installs the sudo pkg wins).
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

    # 3. NTP config (svc:/network/ntp reads /etc/inet/ntp.conf). EC2 provides a
    # link-local NTP source at 169.254.169.123; fall back to the pool.
    environment.generatedEtc."inet/ntp.conf" = ''
      server ${cfg.ntpServer} iburst
      server 0.pool.ntp.org iburst
      server 1.pool.ntp.org iburst
      driftfile /var/ntp/ntp.drift
    '';

    # 7. logadm — rotate /var/cores + solnix logs (illumos-native log rotation,
    # the logrotate/journald-retention analog). Appended to the base logadm.conf.
    environment.generatedEtc."logadm.d/solnix.conf" = ''
      /var/cores/core.* -A 30d -C 20 -p 1d
      /var/log/solnix.log -C 8 -c -s 10m
    '';

    # 8. nsswitch — hosts: files dns (drop mdns; no mdnsd -> avoids slow lookups).
    environment.generatedEtc."nsswitch.conf" = ''
      passwd:     files
      group:      files
      hosts:      files dns
      ipnodes:    files dns
      networks:   files
      protocols:  files
      rpc:        files
      ethers:     files
      netmasks:   files
      bootparams: files
      publickey:  files
      netgroup:   files
      automount:  files
      aliases:    files
      services:   files
      printers:   user files
      project:    files
      auth_attr:  files
      prof_attr:  files
      tnrhtp:     files
      tnrhdb:     files
    '';

    # 10. /etc/bashrc — a pleasant interactive shell (umask, PS1, common aliases).
    # Sourced by interactive bash; ksh users get the login env from profile.d.
    environment.generatedEtc."bashrc" = ''
      # solnix interactive bash defaults
      umask 022
      [ -z "$PS1" ] && return
      PS1='\u@\h:\w\$ '
      alias ll='ls -l'
      alias la='ls -la'
      alias ..='cd ..'
    '';

    # 3+7 (SMF): enable the stock base-OS services (ntp for time, ipfilter is
    # handled by modules/config/firewall.nix). These are ENABLED via the image's
    # site profile / first-boot activation (svcadm enable), NOT generated manifests.
    solnix.enableStockServices = [ "network/ntp" ];
  };
}
