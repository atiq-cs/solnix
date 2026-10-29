# modules/config/community/cache-proxy.nix -- solnix-cache-proxy, the local substituter on 127.0.0.1 (infra shape (a)).
# An inetd SMF service (one ksh93 process per request, as nobody): nix lists it first and cache.solnix.io second. Nix
# still checks every narinfo signature (require-sigs, 8UNr) and every NAR hash, so the proxy is trusted for
# availability only. NARs come from the swarm when the narinfo carries a Torrent: line and a torrent fetcher is
# installed (patch 4); otherwise the proxy answers 302 to cache.solnix.io, the HTTP fallback.
#
# Loopback only: inetd's bind_addr = 127.0.0.1 with proto tcp (IPv4 only; libinetsvc set_bind_addr). inetd's
# `name` must be a services(5) entry (getservbyname; a bare port number is NULL, measured on illumos), so the
# generation owns /etc/inet/services: the gate's file (./services.stock, sha256 8dded6d9..., the same bytes as dixi's
# /etc/inet/services) plus our line. Listed with extra-substituters: nix sorts substituters by Priority (ours 30,
# cache.solnix.io 50) so ours is tried first, and nothing replaces nix.nix's substituters list.
{ config, lib, pkgs, ... }:

let
  a = config.solnix.community.active;
  port = 37515;
  st = "/var/lib/solnix/cache-proxy";
  t = config.solnix.cache.seed.torrentPackage;
  esc = lib.escapeXML;
  env = {
    PROXY_PATH = "${pkgs.solnix.nixChain.curl}/bin:/usr/bin";
    CURL_CA_BUNDLE = "${pkgs.solnix.nixChain.cacert}/etc/ssl/certs/ca-bundle.crt";
    PROXY_STATE = st;
  } // lib.optionalAttrs (t != null) {
    # the swarm fetcher (seed.nix's torrentPackage): <torrent-url> <out> <seconds>, else the 302 fallback
    PROXY_TORRENT_FETCH = "${pkgs.writeScript "solnix-torrent-fetch" "#!/bin/sh\nexec ${t}/bin/solnix-torrent fetch \"$@\"\n"}";
  };
  # inetd as the restarter; inetd_start runs once per connection with the socket on stdin/stdout.
  inetdXml = ''
    <restarter><service_fmri value='svc:/network/inetd:default'/></restarter>
            <exec_method type='method' name='inetd_start' exec='/usr/bin/ksh93 ${./solnix-cache-proxy.sh}' timeout_seconds='0'>
              <method_context working_directory='/'><method_credential user='nobody' group='nobody'/>
                <method_environment>${lib.concatStrings (lib.mapAttrsToList (k: v: "<envvar name='${k}' value='${esc v}'/>") env)}</method_environment>
              </method_context>
            </exec_method>
            <exec_method type='method' name='inetd_disable' exec=':kill' timeout_seconds='0'/>
            <property_group name='inetd' type='framework'>
              <propval name='name' type='astring' value='solnix-cache-proxy'/>
              <propval name='endpoint_type' type='astring' value='stream'/>
              <propval name='proto' type='astring' value='tcp'/>
              <propval name='bind_addr' type='astring' value='127.0.0.1'/>
              <propval name='wait' type='boolean' value='false'/>
              <propval name='isrpc' type='boolean' value='false'/>
              <propval name='max_copies' type='integer' value='32'/>
            </property_group>'';
in
{
  config = lib.mkIf a.seed {
    environment.generatedEtc."inet/services" = builtins.readFile ./services.stock
      + "solnix-cache-proxy\t${toString port}/tcp\t\t\t# solnix local substituter (127.0.0.1 only)\n";
    nix.settings.extra-substituters = [ "http://127.0.0.1:${toString port}" ];
    # cache.solnix.io's nix-cache-info carries no Priority line, so nix gives it 0 and tries it before the proxy's 30
    # (lower = first): with both listed every path came straight from cache.solnix.io and the proxy saw no request
    # (measured on dixi, 2026-10-29; with ?priority=50 on the origin the same fetch went through the proxy). The
    # per-store ?priority= is nix's own knob. Only nix.nix's default list is rewritten (mkDefault < this); a config
    # that sets its own substituters keeps them.
    nix.settings.substituters = lib.mkOverride 900 [ "https://cache.solnix.io?priority=50" "https://cache.nixos.org" ];
    smf.services.solnix-cache-proxy-setup = {
      enable = true;
      category = "site";
      description = "solnix cache proxy state directory";
      model = "transient";
      requires = [ "svc:/system/filesystem/local:default" ];
      start.exec = "mkdir -p -m 0755 ${st} && mkdir -p -m 0700 ${st}/tmp ${st}/seen && chown nobody ${st}/tmp ${st}/seen";
      stop.exec = ":true";
    };
    smf.services.solnix-cache-proxy = {
      enable = true;
      category = "site";
      description = "solnix local substituter on 127.0.0.1:${toString port} (cache.solnix.io, torrent when offered)";
      requires = [ "svc:/site/solnix-cache-proxy-setup:default" ];
      # the service-level start/stop are svc.startd's and unused under inetd; the inetd_* methods below are inetd's.
      start.exec = ":true";
      stop.exec = ":true";
      extraManifestXML = inetdXml;
    };
  };
}
