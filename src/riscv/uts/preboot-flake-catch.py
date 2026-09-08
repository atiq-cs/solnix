#!/usr/bin/env python3
"""
catch178.py -- boot in a loop until the EXACT 178-line pre-boot flake signature
appears, then freeze the VM and dump every hart's registers plus the kernel's
dispatcher/lock words over QMP.

Targeted stall detector: the flake's tell is that the A/B dispatcher self-test
prints its last "round 3" line and then never prints
"[disp] thread A/B context-switch". Watching for exactly that (instead of a
generic "console stopped") cuts the detect time from ~25 s to ~5 s per attempt
and cannot be confused with the other stall shapes seen at lines 166/200.

All observation is QEMU-side and happens strictly AFTER the guest has wedged, so
it cannot perturb the race the way an added kernel printf would.

usage: catch178.py <max-attempts> [smp]
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

UTS = os.path.dirname(os.path.abspath(__file__))
OUT = os.environ.get("OUT", "/tmp/preboot-flake-catch")
KERNEL = os.environ.get("KERNEL", "unix-scanout")
os.makedirs(OUT, exist_ok=True)


def nm_path():
    """Locate riscv64-none-elf-nm: $NM, then PATH, then the nix store."""
    cand = os.environ.get("NM") or shutil.which("riscv64-none-elf-nm")
    if cand:
        return cand
    hits = sorted(glob.glob(
        "/nix/store/*riscv64-none-elf-binutils-*/bin/riscv64-none-elf-nm"))
    if hits:
        return hits[-1]
    sys.exit("riscv64-none-elf-nm not found; set $NM or put it on PATH")

WANT_WORDS = ["callout_lock", "runq_lock", "console_lock", "smp_dispatch_ready",
              "timer_ticks", "ab_rounds_a", "ab_rounds_b", "ab_done",
              "smp_harts_dispatching", "next_tid", "idle_harts"]
WANT_PTRS = ["runq_head", "runq_tail", "curthread", "idlethread"]


def syms():
    out = subprocess.run([nm_path(), KERNEL], cwd=UTS, capture_output=True,
                         text=True, timeout=120).stdout
    d = {}
    for line in out.splitlines():
        p = line.split()
        if len(p) == 3:
            d[p[2]] = int(p[0], 16)
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


def one(n, smp, S):
    log, sock = f"{OUT}/console-{n}.log", f"{OUT}/qmp-{n}.sock"
    for p in (log, sock):
        if os.path.exists(p):
            os.unlink(p)
    open(log, "w").close()
    cmd = ["qemu-system-riscv64", "-machine", "virt", "-smp", str(smp),
           "-m", "512M", "-bios", "default", "-kernel", KERNEL,
           "-global", "virtio-mmio.force-legacy=false",
           "-drive", "file=disk.img,if=none,id=hd0,format=raw",
           "-device", "virtio-blk-device,drive=hd0",
           "-drive", "file=data.img,if=none,id=hd1,format=raw",
           "-device", "virtio-blk-device,drive=hd1",
           "-netdev", "user,id=n0", "-device", "virtio-net-device,netdev=n0",
           "-device", "virtio-gpu-device",
           "-display", "none", "-qmp", f"unix:{sock},server,nowait",
           "-serial", f"file:{log}"]
    proc = subprocess.Popen(cmd, cwd=UTS, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    s = qmp_connect(sock)
    qmp(s, {"execute": "qmp_capabilities"})

    verdict, txt, stall = "TIMEOUT", "", 0
    for _ in range(300):
        time.sleep(0.25)
        try:
            txt = open(log, "rb").read().decode("utf-8", "replace")
        except OSError:
            txt = ""
        if "context-switch" in txt or "[exec]" in txt:
            verdict = "PASS"          # got past the A/B test
            break
        if "round 3" in txt:          # in the window: is it progressing?
            stall += 1
            if stall >= 24:           # ~6 s with round 3 seen, no [disp] line
                verdict = "FLAKE"
                break
        if proc.poll() is not None:
            verdict = "DIED"
            break

    dump = ""
    if verdict == "FLAKE":
        hmp(s, "stop")
        dump = "=== info registers -a\n" + hmp(s, "info registers -a")
        dump += "\n=== 32-bit kernel state words\n"
        for w in WANT_WORDS:
            if w in S:
                dump += f"{w:22s} @0x{S[w]:x} = {hmp(s, f'x/1wx 0x{S[w]:x}').strip()}\n"
        dump += "\n=== 64-bit dispatcher pointers (curthread/idlethread = 8 slots)\n"
        for w in WANT_PTRS:
            if w in S:
                cnt = 8 if w in ("curthread", "idlethread") else 1
                dump += f"{w:12s} @0x{S[w]:x}\n" + \
                    hmp(s, f"x/{cnt}gx 0x{S[w]:x}") + "\n"
    bh = re.search(r"Boot HART ID\s*:\s*(\d+)", txt)
    try:
        qmp(s, {"execute": "quit"})
    except Exception:
        pass
    s.close()
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()
    print(f"{n:3d} {verdict:7s} lines={txt.count(chr(10)):<5d} "
          f"bh={bh.group(1) if bh else '?'}", flush=True)
    if dump:
        p = f"{OUT}/regs-{n}.txt"
        open(p, "w").write(dump)
        print(f"    DUMP -> {p}", flush=True)
    return verdict


S = syms()
maxn = int(sys.argv[1]) if len(sys.argv) > 1 else 20
smp = int(sys.argv[2]) if len(sys.argv) > 2 else 4
hits = 0
for i in range(1, maxn + 1):
    if one(i, smp, S) == "FLAKE":
        hits += 1
        if hits >= 2:
            break
print(f"flake hits: {hits}", flush=True)
