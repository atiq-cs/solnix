#!/usr/bin/env bash
# ldr.sh <dir> <loader cmd> [wait] -- type a loader command (via qemu monitor sendkey, the EFI loader ignores
# the serial socket) and print the new serial output.
D=$1; C=$2; W=${3:-4}
S="python3 /tmp/nixbase.WIP/ser2.py $D"
$S mark >/dev/null
python3 - "$D" "$C" <<'PY'
import socket, sys, time
D, C = sys.argv[1], sys.argv[2]
m = {' ':'spc','/':'slash','.':'dot','-':'minus','_':'shift-minus',':':'shift-semicolon','=':'equal',
     '"':'shift-apostrophe','\'':'apostrophe','?':'shift-slash','*':'shift-8','@':'shift-2',',':'comma',
     '$':'shift-4','>':'shift-dot','<':'shift-comma','|':'shift-backslash','\\':'backslash','!':'shift-1',
     '(':'shift-9',')':'shift-0','+':'shift-equal','#':'shift-3','&':'shift-7','%':'shift-5','~':'shift-grave_accent',
     ';':'semicolon','[':'bracket_left',']':'bracket_right','{':'shift-bracket_left','}':'shift-bracket_right'}
s = socket.socket(socket.AF_UNIX); s.connect(D + "/mon.sock"); s.settimeout(0.3)
def drain():
    try:
        while s.recv(65536): pass
    except Exception: pass
drain()
for ch in C:
    if ch.isupper(): k = 'shift-' + ch.lower()
    elif ch.isalnum(): k = ch
    else: k = m[ch]
    s.sendall(("sendkey %s\n" % k).encode()); time.sleep(0.06); drain()
s.sendall(b"sendkey ret\n"); time.sleep(0.2); drain(); s.close()
PY
sleep "$W"; $S since 60
