#!/usr/bin/env python3
"""ptyssh.py PORT -- rvtty3c: one interactive `ssh -tt` session into the riscv64 guest through lixr's hostfwd.

The client runs on floki under a real pty (python pty.fork), with no ssh config, no agent and ControlMaster off.
Checks: a dash prompt; echo $((6*7)) -> 42; sleep 100 then ^C returns to the prompt in under 3 s; the reported
window size equals the client's (set to 33x111); exit -> ssh rc 0. Prints one RESULT line.
"""
import os, pty, select, sys, time, fcntl, termios, struct

port = sys.argv[1]
argv = ["ssh", "-F", "/dev/null", "-o", "ControlMaster=no", "-o", "ControlPath=none", "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "IdentitiesOnly=yes",
        "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=60",
        "-o", "ProxyCommand=ssh -o BatchMode=yes gburd@192.168.1.179 -W 127.0.0.1:" + port,
        "-tt", "-i", os.path.expanduser("~/.ssh/id_ed25519"), "gburd@127.0.0.1"]
env = dict(os.environ); env.pop("SSH_AUTH_SOCK", None)
pid, fd = pty.fork()
if pid == 0:
    os.execvpe("ssh", argv, env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 33, 111, 0, 0))
buf = b""

def wait_for(pat, t):
    global buf
    end = time.time() + t
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                d = os.read(fd, 4096)
            except OSError:
                return False
            if not d:
                return False
            buf += d
            if pat in buf:
                return True
    return pat in buf

res = {}
res["prompt"] = wait_for(b"$ ", 90)
os.write(fd, b"echo FLAGS=$-\n"); wait_for(b"FLAGS=", 10)
os.write(fd, b"echo X$((6*7))X\n"); res["arith"] = wait_for(b"X42X", 15)
os.write(fd, b"/bin/winsz\n"); res["winsz"] = wait_for(b"33 111", 30)
os.write(fd, b"sleep 3; echo RC=$?\n"); res["sleep3"] = wait_for(b"RC=0", 15)
os.write(fd, b"sleep 100; echo RC=$?\n"); time.sleep(1.0); t0 = time.time(); os.write(fd, b"\x03")
res["ctrlc_killed"] = wait_for(b"^C", 5)
os.write(fd, b"echo AFTER$((1+1))\n"); got = wait_for(b"AFTER2", 30)
res["ctrlc_s"] = round(time.time() - t0, 2); res["ctrlc"] = got and res["ctrlc_s"] < 3.0
os.write(fd, b"exit\n"); wait_for(b"\x00never", 5)
_, st = os.waitpid(pid, 0)
res["exit_rc"] = os.waitstatus_to_exitcode(st)
ok = res["prompt"] and res["arith"] and res["ctrlc"] and res["winsz"] and res["exit_rc"] == 0
print("RESULT", "PASS" if ok else "FAIL", res)
open("/tmp/ptyssh-last.txt", "wb").write(buf)
