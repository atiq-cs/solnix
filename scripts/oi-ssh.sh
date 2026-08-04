#!/usr/bin/env bash
# oi-ssh.sh — SSH into the solnix OpenIndiana build host with the right flags.
#
# Uses the ed25519 key we seed into root's authorized_keys, and crucially:
#   IdentitiesOnly + IdentityAgent=none  -> don't let the agent offer other keys
#                                           first and trip sshd MaxAuthTries
#   BatchMode=yes                        -> never prompt (no password popup)
#
# Usage: ./oi-ssh.sh <ip> [command...]
set -euo pipefail
IP="${1:?usage: oi-ssh.sh <ip> [command...]}"; shift || true
# NOTE(local-builder): when the artifacts were cross-built on THIS dev-box the
# store paths are already local -- no SSH hop. IP=localhost runs the command in
# a local shell so oi-fleet-publish.sh's `nix-store --export` reads the local
# store directly. (Fleet path unchanged for real remote builders.)
if [ "$IP" = localhost ] || [ "$IP" = 127.0.0.1 ]; then
  exec bash -c "$*"
fi
KEY="${SOLNIX_KEY:-$HOME/.ssh/id_ed25519}"   # must match scripts seed pubkey
exec ssh \
  -i "$KEY" \
  -o IdentitiesOnly=yes \
  -o IdentityAgent=none \
  -o BatchMode=yes \
  -o PreferredAuthentications=publickey \
  -o StrictHostKeyChecking=accept-new \
  -o ConnectTimeout=10 \
  "root@$IP" "$@"
