#!/usr/bin/env python3
"""ser2.py <dir> mark | waitfrom <regex> <timeout> | send <text> | since [n] | run <cmd> [timeout]
Serial driver for a qemu guest whose socket/log live in <dir>. 'mark' records the
current log length so later waits only match NEW output (the log is never truncated)."""
import re, socket, sys, time, os
D = sys.argv[1]; SOCK = D + "/serial.sock"; LOG = D + "/serial.log"; MARK = D + "/.sermark"
ANSI = re.compile(rb"\x1b\[[0-9;=?]*[A-Za-z~]|\x1b[()][A-Z0-9]|\x1b[=>]|[\x08\x0f\x0e\x00]")
def raw():
    with open(LOG, "rb") as f: return f.read()
def clean(b): return ANSI.sub(b"", b).replace(b"\r", b"").decode("utf-8", "replace")
def mark(): return int(open(MARK).read()) if os.path.exists(MARK) else 0
def send(t):
    s = socket.socket(socket.AF_UNIX); s.connect(SOCK)
    for ch in t.encode().replace(b"\n", b"\r"): s.sendall(bytes([ch])); time.sleep(0.03)
    time.sleep(0.2); s.close()
cmd = sys.argv[2]
if cmd == "mark": open(MARK, "w").write(str(len(raw()))); print(len(raw()))
elif cmd == "waitfrom":
    r = re.compile(sys.argv[3]); t0 = time.time(); to = float(sys.argv[4])
    while time.time() - t0 < to:
        if r.search(clean(raw()[mark():])): print("MATCH %.0fs" % (time.time()-t0)); sys.exit(0)
        time.sleep(1)
    print("TIMEOUT"); sys.exit(1)
elif cmd == "send": send(sys.argv[3].encode().decode("unicode_escape"))
elif cmd == "since":
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 40
    print("\n".join(clean(raw()[mark():]).splitlines()[-n:]))
elif cmd == "run":
    tag = "MK%d" % int(time.time()*1000); open(MARK, "w").write(str(len(raw())))
    send(sys.argv[3] + "; echo __" + tag + "_E__\n"); to = float(sys.argv[4]) if len(sys.argv) > 4 else 60
    t0 = time.time()
    while time.time() - t0 < to:
        txt = clean(raw()[mark():])
        if ("__" + tag + "_E__\n") in txt.replace("__"+tag+"_E__\"", ""):
            break
        time.sleep(1)
    print(clean(raw()[mark():]))
