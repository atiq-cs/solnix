#!/usr/bin/env python3
"""
slotcheck.py -- DETERMINISTIC check for the pre-boot flake's root cause.

The flake itself is bursty, so "did it crash?" is a terrible test. But the
PRECONDITION -- two harts aliased onto one dispatcher cpu slot -- is a static
fact about kernel state that is either true or false on every boot, crash or no
crash. This reads it directly out of guest memory over QMP once the boot has
settled, so a single nonzero-boot-hart run gives a yes/no answer instead of a
probability.

What it checks, given OpenSBI's boot hart B and -smp N:
  ALIASED  : two harts share a slot. Shows up as idlethread[B] == NULL while
             idlethread[0] is populated -- the boot hart took slot 0 (hardcoded
             dispatch_init_cpu(0)) and left its own slot empty, and the real
             hart 0, started as a secondary, claimed slot 0 too.
  CLEAN    : idlethread[h] != NULL for exactly the N live harts, including B.

Boot-hart 0 runs are uninformative by construction (slot 0 IS the boot hart's
slot), so they are reported as SKIP rather than counted as clean.

usage: slotcheck.py <attempts> [smp]
"""
import glob
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time

KERNEL = os.environ.get("KERNEL", "unix-scanout")

UTS = os.path.dirname(os.path.abspath(__file__))
OUT = os.environ.get("OUT", "/tmp/hart-slot-check")
os.makedirs(OUT, exist_ok=True)


def nm_path():
    """Locate riscv64-none-elf-nm: $NM, then PATH, then the nix store.

    Resolved rather than hardcoded because the symbol addresses this reads must
    come from the SAME kernel binary being booted; a stale or absent nm would
    silently read the wrong addresses and report a clean slot table for a broken
    kernel, which is worse than not running.
    """
    cand = os.environ.get("NM") or shutil.which("riscv64-none-elf-nm")
    if cand:
        return cand
    hits = sorted(glob.glob(
        "/nix/store/*riscv64-none-elf-binutils-*/bin/riscv64-none-elf-nm"))
    if hits:
        return hits[-1]
    sys.exit("riscv64-none-elf-nm not found; set $NM or put it on PATH")


def syms():
    out = subprocess.run([nm_path(), KERNEL], cwd=UTS, capture_output=True,
                         text=True, timeout=120).stdout
    d = {p[2]: int(p[0], 16)
         for p in (l.split() for l in out.splitlines()) if len(p) == 3}
    for need in ("idlethread", "curthread"):
        if need not in d:
            sys.exit(f"{KERNEL} has no {need} symbol; build with -g / no strip")
    return d


def qmp_connect(path, tries=300):
    for _ in range(tries):
        try:
            s = socket.socket(socket.AF_UNIX)
            s.connect(path)
            s.settimeout(25)
            return s
        except OSError:
            time.sleep(0.1)
    raise TimeoutError("qmp never appeared")


def qmp(s, obj):
    s.sendall((json.dumps(obj) + "\n").encode())
    buf = b""
    deadline = time.time() + 25
    while time.time() < deadline:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if not line.strip():
                continue
            m = json.loads(line)
            if "return" in m or "error" in m:
                return m
    raise TimeoutError(obj)


def hmp(s, cmd):
    return qmp(s, {"execute": "human-monitor-command",
                   "arguments": {"command-line": cmd}}).get("return", "")


def words(s, addr, n):
    """Read n 64-bit words from guest PA via the monitor."""
    txt = hmp(s, f"x/{n}gx 0x{addr:x}")
    vals = []
    for line in txt.splitlines():
        if ":" not in line:
            continue
        for tok in line.split(":", 1)[1].split():
            if tok.startswith("0x"):
                vals.append(int(tok, 16))
    return vals[:n]


def one(n, smp, S):
    log, sock = f"{OUT}/console-{n}.log", f"{OUT}/qmp-{n}.sock"
    for p in (log, sock):
        if os.path.exists(p):
            os.unlink(p)
    open(log, "w").close()
    proc = subprocess.Popen(
        ["qemu-system-riscv64", "-machine", "virt", "-smp", str(smp),
         "-m", "512M", "-bios", "default", "-kernel", KERNEL,
         "-global", "virtio-mmio.force-legacy=false",
         "-drive", "file=disk.img,if=none,id=hd0,format=raw",
         "-device", "virtio-blk-device,drive=hd0",
         "-drive", "file=data.img,if=none,id=hd1,format=raw",
         "-device", "virtio-blk-device,drive=hd1",
         "-netdev", "user,id=n0", "-device", "virtio-net-device,netdev=n0",
         "-device", "virtio-gpu-device",
         "-display", "none", "-qmp", f"unix:{sock},server,nowait",
         "-serial", f"file:{log}"],
        cwd=UTS, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    s = qmp_connect(sock)
    qmp(s, {"execute": "qmp_capabilities"})

    txt, ready = "", False
    for _ in range(320):
        time.sleep(0.25)
        try:
            txt = open(log, "rb").read().decode("utf-8", "replace")
        except OSError:
            txt = ""
        # Any point after startup_dispatch is enough; wait for the SMP proof
        # line so every hart has been through dispatch_init_cpu.
        if "harts online in dispatcher" in txt or "boot hart only" in txt \
                or "login:" in txt:
            ready = True
            break
        if proc.poll() is not None:
            break

    bh = re.search(r"Boot HART ID\s*:\s*(\d+)", txt)
    bh = int(bh.group(1)) if bh else -1
    res, detail = "NOBOOT", ""
    if ready:
        hmp(s, "stop")
        idle = words(s, S["idlethread"], 8)
        cur = words(s, S["curthread"], 8)
        live = [h for h in range(8) if idle[h]]
        detail = ("idlethread=[" +
                  " ".join("0" if not v else f"{v:#x}"[-4:] for v in idle[:smp])
                  + "] curthread=[" +
                  " ".join("0" if not v else f"{v:#x}"[-4:] for v in cur[:smp])
                  + "]")
        if bh == 0:
            res = "SKIP"          # slot 0 is legitimately the boot hart's
        elif idle[bh] == 0:
            res = "ALIASED"       # boot hart's own slot empty => it took slot 0
        elif len(live) == smp:
            res = "CLEAN"
        else:
            res = f"ODD(live={live})"
    try:
        qmp(s, {"execute": "quit"})
    except Exception:
        pass
    s.close()
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()
    print(f"{n:3d} bh={bh} {res:12s} {detail}", flush=True)
    return res


S = syms()
attempts = int(sys.argv[1]) if len(sys.argv) > 1 else 12
smp = int(sys.argv[2]) if len(sys.argv) > 2 else 4
tally = {}
for i in range(1, attempts + 1):
    r = one(i, smp, S)
    tally[r] = tally.get(r, 0) + 1
print("tally: " + "  ".join(f"{k}={v}" for k, v in sorted(tally.items())),
      flush=True)
# Exit nonzero if any informative run was aliased: usable as a gate.
sys.exit(1 if tally.get("ALIASED") else 0)
