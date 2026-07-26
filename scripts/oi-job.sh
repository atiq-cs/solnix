#!/usr/bin/env bash
# oi-job.sh — run a long command on the illumos build host as a DETACHED job,
# then poll its status with SHORT non-blocking calls. Anti-wedge pattern: never
# hold an SSH connection open across a multi-minute operation.
#
#   oi-job.sh start <name> '<remote shell command>'   # launch detached (nohup)
#   oi-job.sh poll  <name>                             # 1 short call: status + log tail
#   oi-job.sh wait  <name> [max_min]                   # poll ~60s up to max_min (default 30)
#   oi-job.sh list                                     # all jobs + status
#
# Job writes /var/tmp/solnix-jobs/<name>.{log,status,pid}. status = RUNNING |
# DONE:<exit>. To avoid fragile nested quoting, the command is base64-encoded,
# scp'd nowhere — instead sent as a here-doc into a .cmd file, and a fixed runner
# executes it. Poll from the orchestrator between other work.
set -euo pipefail
cd "$(dirname "$0")/.."
BIP="${BIP:-$(cat /tmp/oi_build_ip 2>/dev/null)}"
KEY="${SOLNIX_KEY:-$HOME/.ssh/id_ed25519}"
ssh_() { timeout "${SSH_TIMEOUT:-40}" ssh -i "$KEY" -o IdentitiesOnly=yes -o IdentityAgent=none \
           -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "root@$BIP" "$@"; }
JD=/var/tmp/solnix-jobs

case "${1:-}" in
  start)
    name="$2"; cmd="$3"
    # base64 the user command so no quoting survives to break; the runner decodes it.
    b64=$(printf '%s' "$cmd" | base64 | tr -d '\n')
    ssh_ "sh -s" <<EOF
set -e
mkdir -p $JD
printf '%s' '$b64' | openssl base64 -d -A > $JD/$name.cmd 2>/dev/null || printf '%s' '$b64' | base64 -d > $JD/$name.cmd
cat > $JD/$name.run <<'RUNEOF'
#!/bin/sh
export PATH=/nix-tools/bin:/usr/gnu/bin:/usr/bin:\$PATH
sh $JD/$name.cmd > $JD/$name.log 2>&1
echo "DONE:\$?" > $JD/$name.status
RUNEOF
chmod +x $JD/$name.run
echo RUNNING > $JD/$name.status
nohup $JD/$name.run </dev/null >/dev/null 2>&1 &
echo \$! > $JD/$name.pid
echo "started $name pid \$(cat $JD/$name.pid)"
EOF
    ;;
  poll)
    name="$2"
    ssh_ "printf 'status: '; cat $JD/$name.status 2>/dev/null || echo MISSING; echo '--- log tail ---'; tail -10 $JD/$name.log 2>/dev/null" ;;
  wait)
    name="$2"; maxmin="${3:-30}"; i=0
    while [ "$i" -lt "$maxmin" ]; do
      st=$(ssh_ "cat $JD/$name.status 2>/dev/null" 2>/dev/null | tr -d '\r\n ')
      echo "[$name] ${st:-?} (min $i/$maxmin)"
      case "$st" in DONE:*) ssh_ "tail -15 $JD/$name.log 2>/dev/null"; exit 0;; esac
      sleep 60; i=$((i+1))
    done
    echo "[$name] still RUNNING after ${maxmin}m — detached, poll later"; exit 2 ;;
  list)
    ssh_ "for s in $JD/*.status; do [ -f \"\$s\" ] && printf '%s\t%s\n' \"\$(basename \"\${s%.status}\")\" \"\$(cat \"\$s\")\"; done 2>/dev/null" ;;
  *) echo "usage: $0 {start <name> <cmd> | poll <name> | wait <name> [min] | list}"; exit 1 ;;
esac
