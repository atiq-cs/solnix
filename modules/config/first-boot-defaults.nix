{ config, lib, ... }:
# modules/config/first-boot-defaults.nix — the "feels like a finished OS" defaults
# a fresh NixOS install gets, adapted to native illumos mechanisms. See
# docs/design-first-boot-defaults.md for the full audit. Tier-1 + Tier-2 here.
let
  cfg = config.solnix.defaults;
in
{
  # NixOS time.timeZone (nixos/modules/config/locale.nix): an IANA name, e.g. "America/New_York". NixOS's default is
  # null = UTC; illumos needs a TZ value, so solnix's default is "UTC". Zone files: /usr/share/lib/zoneinfo.
  options.time.timeZone = lib.mkOption {
    type = lib.types.str; default = "UTC"; example = "America/New_York";
    description = "The time zone used for displaying times and dates (TZ in /etc/default/init and the login environment).";
  };
  options.solnix.defaults = {
    enable = lib.mkOption { type = lib.types.bool; default = true; };
    enableStockServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Stock base-OS SMF services (FMRIs like "network/ipfilter", instance
        default) that the site profile enables. For SERVICES SHIPPED BY THE OS,
        not generated manifests.
      '';
    };
    timeZone = lib.mkOption {
      type = lib.types.str; default = config.time.timeZone;
      defaultText = lib.literalExpression "config.time.timeZone";
      description = "Default time zone (illumos reads TZ from /etc/default/init). Set time.timeZone, as on NixOS.";
    };
    locale = lib.mkOption {
      type = lib.types.str; default = "en_US.UTF-8";
      description = "Default LANG (illumos ships en_US.UTF-8).";
    };
    mdns = lib.mkOption {
      type = lib.types.bool; default = false;
      description = ''
        Multicast DNS (NixOS services.avahi with nssmdns4): enable illumos's own mdnsd (svc:/network/dns/multicast)
        and put mdns after dns on the hosts/ipnodes lines. nss_mdns answers only .local names and link-local
        addresses, so other lookups never wait on it. The mdnsd firewall port (UDP 5353) opens with it.
      '';
    };
    ntpServer = lib.mkOption {
      type = lib.types.str; default = "169.254.169.123";
      description = "NTP source. EC2 provides a link-local NTP at 169.254.169.123.";
    };
  };

  config = lib.mkIf cfg.enable {
    solnix.defaults.enableStockServices = lib.mkIf cfg.mdns [ "network/dns/multicast" ];
    solnix.firewall.allowedUDPPorts = lib.mkIf cfg.mdns [ 5353 ];
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

    # 5. `sudo`: a real command in system.path (modules/config/sudo.nix), RBAC
    # underneath. It replaces the shell function that was here, which only
    # interactive shells that sourced this file saw.

    # 4. MOTD — a helpful first-login message (release + how to install + docs).
    environment.generatedEtc."motd" = ''
      solnix ${config.solnix.release} (illumos + Nix), version ${config.solnix.version}

        install a package:   nix profile install nixpkgs#<name>
        list installed:      nix profile list
        admin (root):        pfexec <cmd>   (or: sudo <cmd>)
        docs:                https://solnix.io

    '' + lib.optionalString config.solnix.privacy.enable (builtins.readFile ./community/motd.txt + "\n");   # handoff 2026-10-28 section 1

    # 6. Nix GC so /nix doesn't grow unbounded (NixOS weekly-GC analog).
    # auto-optimise-store stays false, NixOS's default: with it on, identical files in the store share an inode, and a builder that
    # copies a store input with tar or cp -a and then edits one name per file edits them all (wave7: the world's usr/bin/ps and
    # usr/ucb/ps got one RUNPATH, so an out depended on the building host's nix.conf). `nix-store --optimise` still works on demand.
    nix.settings = {
      auto-optimise-store = lib.mkDefault false;
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

    # 7. log rotation: none here. An /etc/logadm.d/solnix.conf was generated until cosmic8 (2026-11-01), with rules for
    # /var/cores/core.* and /var/log/solnix.log. Neither ever ran: logadm reads only /etc/logadm.conf, and logadm-upgrade
    # merges a logadm.d file only when it is a regular -r--r--r-- root:sys file, which a generated-etc link is not
    # (`logadm -n -v` on lixi listed neither). Nothing writes /var/log/solnix.log. Cores: solnix-core-prune (coreadm.nix).

    # 8. nsswitch — hosts: files dns, plus mdns only with solnix.defaults.mdns (mdnsd running; no mdnsd -> slow lookups).
    environment.generatedEtc."nsswitch.conf" = ''
      passwd:     files
      group:      files
      hosts:      files dns${lib.optionalString cfg.mdns " mdns"}
      ipnodes:    files dns${lib.optionalString cfg.mdns " mdns"}
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
      # solnix bash defaults. bash reads this for every shell (SYS_BASHRC + SSH_SOURCE_BASHRC, as NixOS), so a
      # non-interactive `ssh host cmd` gets the login environment (PATH, MANPATH, INFOPATH) before the $PS1 return.
      [ -r /etc/profile.d/solnix-env.sh ] && . /etc/profile.d/solnix-env.sh
      umask 022
      [ -z "$PS1" ] && return
      PS1='\u@\h:\w\$ '
      alias ll='ls -l'
      alias la='ls -la'
      alias ..='cd ..'
    '';

    # 3+7 (SMF): stock base-OS services go in solnix.defaults.enableStockServices, which
    # the site profile enables (ipfilter: modules/config/firewall.nix). Until 2026-10-30
    # nothing read the option, so neither ipfilter nor ntp was ever enabled. ntp is NOT
    # listed: the world has no ntpd and no network/ntp manifest (measured on dixi), so
    # enabling it would only make svccfg warn. No NTP client runs until one is packaged.
  };
}
