# modules/config/community/builder-zone.nix -- solnix.builder.isolation = "zone": the solnix.io queue builder runs as
# the untrusted user solnix-builder-<shortId> in its own zone, with the zone's own nix-daemon and /nix/store.
# Why a whole zone (docs: /scratch/solnix/bzone1/design.md, measured on dixi 2026-10-30): solnix builds with
# sandbox = false, so build code runs as nixbldN IN THE DAEMON'S ZONE. Through the global zone's daemon a recipe could
# list /home, read IMDS and reach the tailnet; a zone around the client alone would change nothing. The zone is the
# coarse stand-in for NixOS's per-build sandbox (one for all of this builder's builds).
# NixOS parallels: a dedicated untrusted user (github-runner, hydra), the token in a root-placed file outside the store,
# ProtectSystem/ProtectHome (the zone's own root), a container with privateNetwork + networking.nat, restarted when its
# config changes; CPUQuota/MemoryMax -> capped-cpu/capped-memory.
# Pieces: the `solnix` brand (zone-brand/, linked into the BE's /usr/lib/brand by install-be), its install hook
# (zone-install.sh), the zone's init (zone-init.sh), the GZ service site/solnix-builder-zone (solnix-builder-zone.sh),
# and the zone link's ipf/ipnat rules: out to TCP 443 and DNS only, never to private, CGNAT (tailnet) or link-local
# (IMDS) addresses, nothing to the GZ itself.
{ config, lib, pkgs, solnixSystem, ... }:

let
  a = config.solnix.community.active;
  b = config.solnix.builder;
  cfg = config.solnix.cache.build.zone;
  bi = config.solnix.cache.build.internal;
  on = a.build && b.isolation == "zone";
  s = pkgs.solnix;
  user = "solnix-builder-${toString b.shortId}";
  uid = 30090;
  zp = "/var/lib/solnix/zones/${cfg.name}";
  secrets = "${zp}-secrets";
  gw = "10.200.0.1"; addr = "10.200.0.2"; prefix = "30";
  stub = "bzstub0"; gzlink = "bzgz0"; zlink = "bzz0";
  sh = text: name: pkgs.writeTextFile { inherit name; executable = true; text = "#!/sbin/sh\n" + text; };
  nixConf = pkgs.writeText "zone-nix.conf" ''
    # the builder zone's own nix-daemon: the zone user may ask for builds, only root is trusted
    allowed-users = ${user}
    trusted-users = root
    build-users-group = nixbld
    sandbox = false
    max-jobs = ${toString cfg.maxJobs}
    cores = 0
    substituters = https://cache.solnix.io
    trusted-public-keys = cache.solnix.io-1:8UNrVAOSOrI9PGHc8/pD2Yqp265ZeYb3OId+gv4+wm8=
    require-sigs = true
    ssl-cert-file = ${bi.cacert}
    experimental-features = nix-command flakes
    keep-outputs = false
    min-free = ${toString (2 * 1024 * 1024 * 1024)}
    max-free = ${toString (8 * 1024 * 1024 * 1024)}
    warn-dirty = false
  '';
  resolv = pkgs.writeText "zone-resolv.conf" (lib.concatMapStrings (n: "nameserver ${n}\n") cfg.nameservers);
  hosts = pkgs.writeText "zone-hosts" "127.0.0.1 localhost\n${addr} ${cfg.name}\n";
  # the builder, as the zone user: the GZ service's environment with zone paths
  run = pkgs.writeText "solnix-builder-zone-run" ''
    export BUILDER_PATH='${bi.path}' CURL_CA_BUNDLE='${bi.cacert}' BUILDER_STATE=/home/${user}/state BUILDER_SYSTEM='${solnixSystem}'
    export ${lib.concatStringsSep " " (lib.mapAttrsToList (n: v: "${n}='${v}'") bi.env)}
    export BUILDER_BEARER_FILE=/var/lib/solnix/secrets/build-queue-bearer HOME=/home/${user} SSL_CERT_FILE='${bi.cacert}' GIT_SSL_CAINFO='${bi.cacert}'
    exec /usr/bin/ksh93 ${bi.script}
  '';
  initEnv = pkgs.writeText "solnix-builder-zone-init.env" ''
    ZONE_LINK=${zlink} ZONE_ADDR=${addr} ZONE_PREFIX=${prefix} ZONE_GW=${gw} ZONE_USER=${user} ZONE_NIX=${config.nix.package} ZONE_RUN=${run}
  '';
  init = sh "exec /usr/bin/ksh93 ${./zone-init.sh} ${initEnv}\n" "solnix-builder-zone-init";
  installEnv = pkgs.writeText "solnix-builder-zone-install.env" ''
    ZONE_TOP=/run/current-system ZONE_SW=${config.system.path} ZONE_USER=${user} ZONE_UID=${toString uid} ZONE_NIXBLD=${toString cfg.buildUsers}
    ZONE_NIXCONF=${nixConf} ZONE_RESOLV=${resolv} ZONE_HOSTS=${hosts} ZONE_CACERT=${bi.cacert} ZONE_INIT=${init}
    # the zone's store: what its /usr /lib /sbin links name, plus its own init; never the toplevel itself (its etc/)
    ZONE_STORE_PATHS="${s.world} ${s.early} ${config.system.path} ${init} $(cat /run/current-system/early-paths)"
  '';
  install = sh "exec /usr/bin/ksh93 ${./zone-install.sh} ${installEnv} \"$@\"\n" "solnix-builder-zone-install";
  brand = pkgs.runCommand "solnix-zone-brand" { } ''
    mkdir $out
    sed -e 's|@install@|${install}|' ${./zone-brand/config.xml.in} > $out/config.xml
    cp ${./zone-brand/platform.xml} $out/platform.xml
  '';
  zonecfg = pkgs.writeText "solnix-builder-zone.cfg" ''
    create -b
    set brand=solnix
    set zonepath=${zp}
    set autoboot=false
    set ip-type=exclusive
    set limitpriv=default
    add net
    set physical=${zlink}
    set allowed-address=${addr}/${prefix}
    end
    add fs
    set dir=/var/lib/solnix/secrets
    set special=${secrets}
    set type=lofs
    add options [ro,nosetuid,nodevices]
    end
    ${lib.optionalString (cfg.cpuCap != null) ''
    add capped-cpu
    set ncpus=${toString (cfg.cpuCap / 100)}.${lib.fixedWidthNumber 2 (lib.mod cfg.cpuCap 100)}
    end
    ''}    add capped-memory
    set swap=${cfg.memCap}
    end
    set max-lwps=${toString cfg.maxLwps}
    commit
  '';
  # the GZ service's settings: one file, read by solnix-builder-zone.sh
  svcEnv = pkgs.writeText "solnix-builder-zone.env" ''
    ZONE_NAME=${cfg.name} ZONE_PATH=${zp} ZONE_DATASET=${cfg.dataset} ZONE_QUOTA=${cfg.quota} ZONE_CFG=${zonecfg} ZONE_SPEC=${install}
    ZONE_STUB=${stub} ZONE_GZLINK=${gzlink} ZONE_LINK=${zlink} ZONE_GW=${gw} ZONE_PREFIX=${prefix}
    ZONE_UPLINKS="${lib.concatStringsSep " " cfg.uplinks}" ZONE_UID=${toString uid}
    ZONE_BEARER_SRC=/var/lib/solnix/build-queue-bearer ZONE_SECRETS=${secrets}
  '';
  # out of the zone: DNS to its nameservers, then TCP 443 to any public address; nothing to private, CGNAT (tailnet),
  # link-local (IMDS) or the GZ. In on the zone link: only replies (keep state).
  blocked = [ "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "100.64.0.0/10" "169.254.0.0/16" "127.0.0.0/8" "224.0.0.0/3" "0.0.0.0/8" ];
  zoneRules = ''
    # solnix builder zone (builder-zone.nix): its link first, before the default policy. Toward the zone only the
    # replies its own connections created state for (state is checked before rules), nothing routed in from outside.
    block out log quick on ${gzlink} all
    ${lib.concatMapStrings (n: ''
      pass in quick on ${gzlink} proto udp from ${addr}/32 to ${n}/32 port = 53 keep state
      pass in quick on ${gzlink} proto tcp from ${addr}/32 to ${n}/32 port = 53 flags S keep state
    '') cfg.nameservers}
    ${lib.concatMapStrings (n: "block in log quick on ${gzlink} from any to ${n}\n") blocked}
    pass in quick on ${gzlink} proto tcp from ${addr}/32 to any port = 443 flags S keep state
    block in log quick on ${gzlink} all
  '';
in
{
  options.solnix.cache.build.zone = {
    name = lib.mkOption { type = lib.types.strMatching "[a-z][a-z0-9-]{0,30}"; default = "solnix-builder"; description = "The zone's name."; };
    dataset = lib.mkOption { type = lib.types.str; example = "data/zones/solnix-builder";
      description = "The ZFS dataset for the zonepath (created at ${zp}). Not under a BE root."; };
    quota = lib.mkOption { type = lib.types.str; default = "100G"; description = "Quota of the zone's dataset (its store, homes and build trees)."; };
    cpuCap = lib.mkOption { type = lib.types.nullOr (lib.types.ints.between 10 10000); default = config.solnix.cache.build.cpuCap;
      description = "capped-cpu, in percent of one CPU (the project.cpu-cap of isolation = none); null: no cap."; };
    memCap = lib.mkOption { type = lib.types.str; default = "32g"; description = "capped-memory swap: the zone's reserved memory (kernel-enforced; a physical cap needs rcapd)."; };
    maxLwps = lib.mkOption { type = lib.types.ints.positive; default = 20000; description = "zone.max-lwps."; };
    maxJobs = lib.mkOption { type = lib.types.ints.positive; description = "The zone daemon's max-jobs (the builder's own parallelJobs sizes the work).";
      default = let j = config.solnix.cache.build.parallelJobs; in if j == null then cfg.buildUsers else lib.max 2 j; };
    buildUsers = lib.mkOption { type = lib.types.ints.between 1 32; default = 8; description = "nixbld users in the zone (uids 30101..)."; };
    nameservers = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ "1.1.1.1" "9.9.9.9" ];
      description = "The zone's resolvers: public ones, so the zone needs no route to the host's LAN or VPC resolver."; };
    uplinks = lib.mkOption { type = lib.types.listOf lib.types.str; default = lib.attrNames config.networking.interfaces;
      description = "IP interfaces the zone's traffic is NATed out of (forwarding is turned on for these and the zone link only)."; };
  };

  config = lib.mkIf on {
    assertions = [
      { assertion = b.shortId != null;
        message = "solnix.builder.shortId must be set (infra assigns it per enrolled builder key) when solnix.builder.isolation is ${b.isolation}"; }
      { assertion = config.solnix.firewall.enable;
        message = "solnix.builder.isolation = \"zone\" needs solnix.firewall.enable: the zone's traffic is filtered by the host's ipfilter."; }
      { assertion = cfg.uplinks != [ ];
        message = "solnix.cache.build.zone.uplinks is empty: no interface to NAT the builder zone out of."; }
    ];
    system.zoneBrands.solnix = brand;
    solnix.firewall.extraRules = zoneRules;
    environment.generatedEtc."ipf/ipnat.conf" =
      lib.concatMapStrings (u: "map ${u} ${addr}/32 -> 0/32 portmap tcp/udp auto\nmap ${u} ${addr}/32 -> 0/32\n") cfg.uplinks;
    smf.services.solnix-builder-zone = {
      enable = true;
      category = "site";
      description = "solnix idle-time build-queue drainer in its own zone (builders.solnix.io)";
      model = "transient";
      requires = [ "svc:/network/ipfilter:default" "svc:/system/zones:default" "svc:/milestone/network:default"
        "svc:/system/filesystem/local:default" ] ++ lib.optional config.solnix.ephemeralPool.enable "svc:/site/solnix-ephemeral-pool:default";
      dependencies = [ config.smf.networkOnline ];   # the DHCP lease and resolv.conf (solnix-net), not only network/physical
      start = { exec = "/usr/bin/ksh93 ${./solnix-builder-zone.sh} ${svcEnv} start"; timeoutSeconds = 3600; };
      stop.exec = "/usr/bin/ksh93 ${./solnix-builder-zone.sh} ${svcEnv} stop";
    };
  };
}
