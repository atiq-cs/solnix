#!/usr/bin/env bash
# boot-be.sh <dir> <bootfs-dataset> [wait] -- reset guest, escape to loader prompt, boot a given BE, print console
D=$1; BE=$2; W=${3:-120}
S="python3 /tmp/nixbase.WIP/ser2.py $D"; L=/tmp/nixbase.WIP/ldr.sh
$S mark >/dev/null
python3 /var/tmp/bhost/mon.py system_reset >/dev/null 2>&1 || python3 - "$D" <<'PY'
import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]+"/mon.sock"); s.sendall(b"system_reset\n"); s.close()
PY
$S waitfrom 'Autoboot in [0-9]' 240 >/dev/null || { echo NO-MENU; exit 1; }
python3 - "$D" <<'PY'
import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]+"/mon.sock")
for k in ("spc","3"): s.sendall(("sendkey %s\n"%k).encode()); time.sleep(1)
s.close()
PY
$S waitfrom 'ok *$' 30 >/dev/null || { echo NO-OK; exit 1; }
$L $D "set currdev=zfs:$BE:" 2 >/dev/null
$L $D "boot" "$W" | tr -d '\r' | awk 'index($0,"Loading unix"){f=1} f'
