#!/usr/bin/bash
# tailscale-autoconnect.sh [tailscale up flags...] -- services.tailscale's one-shot (./tailscale.nix), the nix-config
# autoconnect for SMF: log the node in with TS_AUTHKEY_FILE, unless it is already Running on TS_LOGIN_SERVER.
# Env: TS_CLI (the tailscale CLI), TS_JQ, TS_AUTHKEY_FILE, TS_LOGIN_SERVER. scripts/test-tailscale-eval.sh runs it on a stub.
set -u
st() { "$TS_CLI" status --json 2>/dev/null | "$TS_JQ" -r '.BackendState // "Unknown"' 2>/dev/null; }
# wait out tailscaled's start-up (not answering yet, NoState, Starting), as NixOS's tailscaled-autoconnect does; 90 s + up's 120 s < the 240 s method timeout
state=$(st); i=0
while :; do
  case "$state" in Running|NeedsLogin|NeedsMachineAuth|Stopped) break ;; esac
  [ "$i" -lt 90 ] || { echo "tailscale-autoconnect: tailscaled still '$state' after 90 s; not touching it" >&2; exit 1; }
  i=$((i + 1)); sleep 1; state=$(st)
done
if [ "$state" = Running ]; then
  ctrl=$("$TS_CLI" debug prefs 2>/dev/null | "$TS_JQ" -r '.ControlURL // ""' 2>/dev/null)
  if [ "$ctrl" = "$TS_LOGIN_SERVER" ]; then echo "tailscale already running on $ctrl, nothing to do"; exit 0; fi
  echo "tailscale running on '$ctrl', moving to $TS_LOGIN_SERVER"
else
  echo "tailscale state=$state, logging in with $TS_AUTHKEY_FILE"
fi
# a tailscale.com tskey- fails against Headscale anyway ("invalid key"); an empty file is a placement mistake
key=$(cat "$TS_AUTHKEY_FILE" 2>/dev/null) || key=
case "$key" in
  "" | tskey-*) echo "tailscale-autoconnect: $TS_AUTHKEY_FILE is missing, empty or a tskey- key; refusing to run tailscale up" >&2; exit 1 ;;
esac
unset key
# --auth-key=file: keeps the key off argv; --reset makes the flags the whole truth, --force-reauth allows a new control URL
exec "$TS_CLI" up --timeout=120s --reset --force-reauth --auth-key="file:$TS_AUTHKEY_FILE" "$@"
