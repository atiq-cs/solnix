#!/bin/sh
# solnix-memguard -- pause the nix builds while the machine runs short of memory (modules/config/solnix-memguard.nix).
# An SMF contract loop, root (only root can signal the build users' processes). Every MG_INTERVAL s: if free memory is
# under FLOOR_KB, or cosmic-comp's RSS is over LEAK_KB (the i915 flip_done leak), it SIGSTOPs every build process, and
# SIGCONTs them once both recover. A build process = real uid one of the build group's users (MG_GROUP, nix.conf's
# build-users-group) AND real gid that group: `pgrep -U <uids> -G <gid>`, ids from /etc/passwd and /etc/group, each pid
# re-checked (numeric, real and effective uid a build user, never 0) before its signal. No argv patterns: nothing else
# is ever signalled. A `pkill -f 'nix build'` (lixi's hand-run memguard to 2026-11-15) stops only the client: the
# daemon's build ran on, measured 7 -> 17 ticks in 10 s. TERM (svcadm disable, :kill) CONTs what it paused; at start
# it adopts builds a killed instance left stopped (paused=1), so the next good round CONTs them. Log: stdout (the SMF log).
#   solnix-memguard [list]     no args: the SMF loop; list: print the build pids it would signal
FLOOR_KB=${FLOOR_KB:-4194304}      # pause builds if free RAM < 4 GiB
LEAK_KB=${LEAK_KB:-4194304}        # cosmic-comp RSS over 4 GiB = the leak is running -> pause + alert
INTERVAL=${MG_INTERVAL:-15}
GRP=${MG_GROUP:-nixbld}
say(){ printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
PASSWD=${MG_PASSWD:-/etc/passwd} GROUPS_FILE=${MG_GROUP_FILE:-/etc/group}   # test seams
gid=$(awk -F: -v n="$GRP" '$1==n {print $3}' "$GROUPS_FILE")
case "$gid" in ''|*[!0-9]*|0) say "memguard FATAL: group $GRP's gid '$gid' is not a non-zero number"; exit 1;; esac
# the build users: primary group $GRP, named <group>N (nix's convention), uid a non-zero number
uids=$(awk -F: -v g="$gid" -v n="$GRP" '$4==g && $1 ~ ("^" n "[0-9]+$") && $3 ~ /^[0-9]+$/ && $3 != 0 {printf "%s%s", s, $3; s=","}' "$PASSWD")
[ -n "$uids" ] || { say "memguard FATAL: no ${GRP}N users in group $gid"; exit 1; }
# this zone's only: the uids above are this zone's (a builder zone has its own users and its own guard)
zone=$(zonename 2>/dev/null); [ -n "$zone" ] || { say "memguard FATAL: zonename failed"; exit 1; }
isbuild() { case ",$uids," in *",$1,"*) [ "$1" != 0 ];; *) false;; esac; }
builds() {  # pids of build processes, each re-checked
  for p in $(pgrep -z "$zone" -U "$uids" -G "$gid" 2>/dev/null); do
    case "$p" in ''|*[!0-9]*) continue;; esac
    ru=$(ps -o ruid= -p "$p" 2>/dev/null | tr -d ' '); eu=$(ps -o uid= -p "$p" 2>/dev/null | tr -d ' ')
    isbuild "$ru" && isbuild "$eu" && echo "$p"
  done; }
sig() {  # sig STOP|CONT: signal every build pid; prints how many
  n=0; for p in $(builds); do kill -"$1" "$p" 2>/dev/null && n=$((n+1)); done; echo $n; }
# `solnix-memguard list`: print the build pids it would signal, and exit (the test and an operator's check)
[ "${1:-}" = list ] && { builds; exit 0; }
paused=0
for p in $(builds); do [ "$(ps -o s= -p "$p" 2>/dev/null | tr -d ' ')" = T ] && paused=1; done
trap '[ "$paused" = 1 ] && say "memguard exit: CONT $(sig CONT) build processes"; exit 0' TERM INT HUP
say "memguard start (pid $$): FLOOR=${FLOOR_KB}KB free, LEAK=${LEAK_KB}KB cosmic-comp RSS; builds = the users of group $GRP ($gid), paused=$paused"
while :; do
  free=$(vmstat 1 2 2>/dev/null | tail -1 | awk '{print $5}')
  cc=$(pgrep -x cosmic-comp 2>/dev/null | head -1)
  ccrss=$( [ -n "$cc" ] && ps -o rss= -p "$cc" 2>/dev/null | tr -d ' ' || echo 0)
  nb=$(builds | head -1)
  if [ "${free:-0}" -lt "$FLOOR_KB" ] || [ "${ccrss:-0}" -gt "$LEAK_KB" ]; then
    if [ -n "$nb" ]; then
      n=$(sig STOP)   # every round while paused, so a build started since is stopped too
      [ "$paused" = 0 ] && say "PAUSE builds ($n processes): free=${free}KB cosmic-comp RSS=${ccrss}KB (floor ${FLOOR_KB}/leak ${LEAK_KB})"
      paused=1
    fi
    [ "${ccrss:-0}" -gt "$LEAK_KB" ] && say "WARN cosmic-comp RSS ${ccrss}KB: the i915 flip_done leak may be active; a reboot may be needed"
  elif [ "$paused" = 1 ]; then
    say "RESUME builds ($(sig CONT) processes): free=${free}KB cosmic-comp RSS=${ccrss}KB"; paused=0
  fi
  sleep "$INTERVAL" & wait $!   # wait, so a TERM runs the trap at once
done
