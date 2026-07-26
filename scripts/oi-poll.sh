#!/usr/bin/env bash
# oi-poll.sh <ip> <logfile> — compact status of a detached build:
# last non-empty line + whether the marker "built solnix-" or "error:" is present.
IP="${1:?ip}"; LOG="${2:?log}"
KEY="${SOLNIX_KEY:-$HOME/.ssh/id_ed25519}"
ssh -i "$KEY" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes \
    -o PreferredAuthentications=publickey -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 "root@$IP" "
  if grep -q '=== built solnix-' $LOG 2>/dev/null; then echo DONE;
  elif grep -Eq '^error:|FATAL:|couldn.t be built' $LOG 2>/dev/null; then echo FAIL;
  else echo RUNNING; fi
  tail -2 $LOG 2>/dev/null | cut -c1-160
"
