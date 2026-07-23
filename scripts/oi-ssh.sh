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
