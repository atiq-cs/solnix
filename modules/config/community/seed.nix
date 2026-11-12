# modules/config/community/seed.nix -- BitTorrent: seed what this host fetched or built (solnix-seed.sh), and let the
# cache proxy fetch NARs from the swarm (PROXY_TORRENT_FETCH). Installed only with active.seed AND a torrent client:
# `solnix.cache.seed.torrentPackage`, a package with bin/solnix-torrent (src/solnix-torrent, on libtorrent-rasterbar,
# BSD-3). Until that package is in the solnix package set it is null, and the proxy stays HTTP-only (cache-proxy.nix
# passes the same package to the proxy as PROXY_TORRENT_FETCH).
# Seeds only paths cache.solnix.io serves under 8UNr (the gate in solnix-seed.sh), never a local-only path.
# solnix-swarm-probe keeps <proxy-state>/swarm/ok only while the tracker lists a public peer; without it the proxy
# never tries the swarm (today's tracker lists only its ingress pod, so every NAR goes straight to HTTP).
# Seeder and probe run as nobody, as the proxy does; only the setup method and the post-build hook are root.
{ config, lib, pkgs, ... }:

let
  a = config.solnix.community.active;
  cfg = config.solnix.cache.seed;
  t = cfg.torrentPackage;
  st = "/var/lib/solnix/seed";
  s = pkgs.solnix;
  on = a.seed && t != null;
  px = "/var/lib/solnix/cache-proxy";
in
{
  options.solnix.cache.seed.torrentPackage = lib.mkOption {
    type = lib.types.nullOr lib.types.package;
    default = null;
    description = "A package providing bin/solnix-torrent (libtorrent-rasterbar). null = no seeding, HTTP-only proxy.";
  };
  config = lib.mkIf on {
    # the peer port, TCP and uTP/UDP (SOLNIX_TORRENT_LISTEN below), open only while seeding (NixOS: transmission's openPeerPorts)
    solnix.firewall.allowedTCPPorts = [ 51413 ];
    solnix.firewall.allowedUDPPorts = [ 51413 ];
    smf.services.solnix-seed = {
      enable = true;
      category = "site";
      description = "solnix BitTorrent seeder of fetched and built cache paths (tracker.solnix.io)";
      model = "contract";
      requires = [ "svc:/milestone/network:default" "svc:/milestone/name-services:default" "svc:/site/solnix-seed-setup:default" ];
      dependencies = [ config.smf.networkOnline ];   # the DHCP lease and resolv.conf (solnix-net), not only network/physical
      user = "nobody";
      environment = {
        SEED_PATH = "${t}/bin:${s.nixChain.curl}/bin:${config.nix.package}/bin:/usr/bin:/usr/sbin";
        CURL_CA_BUNDLE = "${s.nixChain.cacert}/etc/ssl/certs/ca-bundle.crt";
        SEED_STATE = st;
        SEED_PROXY_STATE = px;
        SOLNIX_TORRENT_LISTEN = "0.0.0.0:51413";   # the BitTorrent peer port (peers see this host's IP: the opt-in says so)
      };
      start.exec = "/usr/bin/ksh93 ${./solnix-seed.sh} &";
      stop.exec = ":kill";
    };
    # root's part: the seeder's state dirs owned by nobody (built/ is written by the root post-build hook)
    smf.services.solnix-seed-setup = {
      enable = true;
      category = "site";
      description = "solnix seeder and swarm-probe state directories";
      model = "transient";
      requires = [ "svc:/site/solnix-cache-proxy-setup:default" ];
      start.exec = "mkdir -p -m 0755 ${st} ${st}/nars ${st}/built ${st}/xdg ${px}/swarm && chown nobody ${st} ${st}/nars ${st}/xdg ${px}/swarm";
      stop.exec = ":true";
    };
    smf.services.solnix-swarm-probe = {
      enable = true;
      category = "site";
      description = "solnix BitTorrent swarm health probe (gates the cache proxy's torrent path)";
      model = "contract";
      requires = [ "svc:/milestone/network:default" "svc:/milestone/name-services:default" "svc:/site/solnix-seed-setup:default" ];
      dependencies = [ config.smf.networkOnline ];   # the DHCP lease and resolv.conf (solnix-net), not only network/physical
      user = "nobody";
      environment = {
        SWARM_PATH = "${t}/bin:${s.nixChain.curl}/bin:/usr/bin";
        CURL_CA_BUNDLE = "${s.nixChain.cacert}/etc/ssl/certs/ca-bundle.crt";
        SWARM_STATE = "${px}/swarm";
      };
      start.exec = "/usr/bin/ksh93 ${./solnix-swarm-probe.sh} &";
      stop.exec = ":kill";
    };
    # the push hook: record each built path for solnix-seed (it never fails a build)
    nix.settings.post-build-hook = "${pkgs.writeScript "solnix-announce" (builtins.readFile ./solnix-announce.sh)}";
  };
}
