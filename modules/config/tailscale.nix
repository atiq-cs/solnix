# modules/config/tailscale.nix -- services.tailscale, a subset of NixOS's (nixos/modules/services/networking/tailscale.nix):
# tailscaled as an SMF contract daemon (root, as NixOS), then tailscale-autoconnect (authKeyFile) and tailscale-set
# (extraSetFlags) as transients after it. illumos has no tailscale TUN (upstream net/tstun/tstun_stub.go panics there;
# solnix has no tuntap driver), so tailscaled always runs --tun=userspace-networking (netstack): tailnet TCP to this
# node's 100.64.x address is forwarded to localhost (sshd on 22, dixi 2026-10-29), and local programs reach the tailnet
# only through tailscaled's SOCKS5/HTTP proxy (extraDaemonFlags --socks5-server=...). New services land disabled after a
# live switch; reboot (or svcadm enable) to start them.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.tailscale;
  t = lib.types;
  cli = "${cfg.package}/bin/tailscale";
  # the control URL `up` logs in to: the last --login-server= in extraUpFlags, else tailscale's default.
  # shortcut: sees only the --login-server=URL form, not "--login-server" "URL"; upgrade if a host writes the split form.
  login = lib.foldl' (u: f: if lib.hasPrefix "--login-server=" f then lib.removePrefix "--login-server=" f else u)
    "https://controlplane.tailscale.com" cfg.extraUpFlags;
  flags = d: lib.mkOption { type = t.listOf t.str; default = [ ]; description = d; };
in
{
  options.services.tailscale = {
    enable = lib.mkEnableOption "Tailscale client daemon";
    package = lib.mkOption { type = t.package; default = pkgs.solnix.tailscale; defaultText = lib.literalExpression "pkgs.solnix.tailscale";
      description = "The tailscale package (tailscale and tailscaled)."; };
    port = lib.mkOption { type = t.port; default = 41641; description = "The UDP port for tunnel traffic (0 = autoselect)."; };
    interfaceName = lib.mkOption { type = t.str; default = "userspace-networking";
      description = "Must stay \"userspace-networking\": illumos has no tailscale TUN device (asserted)."; };
    authKeyFile = lib.mkOption { type = t.nullOr t.path; default = null; example = "/var/lib/solnix/tailscale-authkey";
      description = "A file with the auth key, placed by hand outside the store; when set, tailscale-autoconnect logs the node in."; };
    extraUpFlags = flags "Extra flags for `tailscale up`; only applied with authKeyFile, and only when the node is not already up.";
    extraSetFlags = flags "Flags for `tailscale set`, applied on every start (also on a node that is already logged in).";
    extraDaemonFlags = flags "Extra flags for tailscaled.";
    disableUpstreamLogging = lib.mkOption { type = t.bool; default = false;
      description = "Stop tailscaled uploading logs to log.tailscale.io (TS_NO_LOGS_NO_SUPPORT)."; };
    openFirewall = lib.mkOption { type = t.bool; default = false;
      description = "Open the UDP port in the firewall (solnix.firewall.allowedUDPPorts). Without it the direct path still works outbound (keep state); inbound-first peers fall back to DERP."; };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      { assertion = cfg.interfaceName == "userspace-networking";
        message = "services.tailscale.interfaceName = \"${cfg.interfaceName}\": illumos has no tailscale TUN device (tailscale's net/tstun panics there and solnix has no tuntap driver); only \"userspace-networking\" works."; }
      { assertion = cfg.authKeyFile == null || !lib.hasPrefix builtins.storeDir (toString cfg.authKeyFile);
        message = "services.tailscale.authKeyFile is in the Nix store, which every user can read; place the key outside it (0600 root)."; }
    ];
    solnix.firewall.allowedUDPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
    environment.systemPackages = [ cfg.package ];
    smf.services.tailscaled = {
      enable = true; category = "site"; description = "Tailscale node agent (userspace networking)"; model = "contract";
      requires = [ "svc:/milestone/network:default" "svc:/milestone/name-services:default" "svc:/system/filesystem/local:default" ];
      environment = lib.optionalAttrs cfg.disableUpstreamLogging { TS_NO_LOGS_NO_SUPPORT = "true"; };
      # the mkdirs in the foreground (a `a && b &` list would background them in a lingering subshell).
      # /var/run/tailscale is 0700 root: tailscaled makes its socket 0666 (it trusts peer creds), but the LocalAPI's
      # `dial` serves ANY local uid. On illumos nix builds run unsandboxed as nixbld, and a derivation reached
      # floki's sshd over the tailnet through it (bzone1, dixi 2026-10-30). NixOS hides the socket with the build
      # sandbox; here the directory does. Non-root users run the CLI with pfexec.
      start.exec = "mkdir -p -m 0700 /var/lib/tailscale && mkdir -p -m 0700 /var/run/tailscale && chmod 0700 /var/run/tailscale || exit 1\n" + lib.escapeShellArgs ([
        "${cfg.package}/bin/tailscaled" "--tun=${cfg.interfaceName}" "--state=/var/lib/tailscale/tailscaled.state"
        "--socket=/var/run/tailscale/tailscaled.sock" "--port=${toString cfg.port}" ] ++ cfg.extraDaemonFlags) + " &";
      stop.exec = ":kill";
    };
    smf.services.tailscale-autoconnect = lib.mkIf (cfg.authKeyFile != null) {
      enable = true; category = "site"; description = "Log Tailscale in with authKeyFile (idempotent)"; model = "transient";
      requires = [ "svc:/site/tailscaled:default" ];
      environment = { TS_CLI = cli; TS_JQ = "${pkgs.solnix.jq}/bin/jq"; TS_AUTHKEY_FILE = toString cfg.authKeyFile; TS_LOGIN_SERVER = login; };
      start = { exec = "/usr/bin/bash ${./tailscale-autoconnect.sh} ${lib.escapeShellArgs cfg.extraUpFlags}"; timeoutSeconds = 240; };
      stop.exec = ":true";
    };
    smf.services.tailscale-set = lib.mkIf (cfg.extraSetFlags != [ ]) {
      enable = true; category = "site"; description = "Apply services.tailscale.extraSetFlags"; model = "transient";
      requires = [ "svc:/site/tailscaled:default" ] ++ lib.optional (cfg.authKeyFile != null) "svc:/site/tailscale-autoconnect:default";
      start = { exec = "i=0; until ${cli} status --json >/dev/null 2>&1; do i=$((i+1)); [ $i -lt 60 ] || exit 1; sleep 1; done; "
        + "exec ${cli} set ${lib.escapeShellArgs cfg.extraSetFlags}"; timeoutSeconds = 120; };
      stop.exec = ":true";
    };
  };
}
