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

# MUST match MAXCPU in main.c / proc.c. The slot arrays are MAXCPU entries wide;
# reading fewer silently cannot see an alias in the upper harts.
#
# This is a DEFAULT, not the authority. It used to be a hardcoded 8 while the
# kernel moved to 16, and this checker -- whose entire purpose is catching hart
# aliasing -- was therefore blind to an alias involving any hart above 7, i.e.
# to exactly the bug it exists to catch. A number duplicated in a second file
# and trusted is how that happened, so slot_width() below OVERRIDES this from
# the binary itself and only falls back here.
MAXCPU = int(os.environ.get("MAXCPU", "16"))

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


def slot_width():
    """Read the REAL slot count out of the kernel binary: sizeof(idlethread)/8.

    Derived, not declared. The kernel's MAXCPU is a #define in main.c and proc.c
    that this script cannot see, and the previous copy of it here was stale by a
    factor of two -- so the checker reported CLEAN for topologies it never looked
    at. nm -S gives the array's byte size, which is MAXCPU * sizeof(kthread_t *),
    so the binary answers the question and no one has to remember to update two
    files. Also VERIFIES the arrays agree with each other and with the
    secondary_stacks pool, since a mismatch between them IS the bug class.
    """
    out = subprocess.run([nm_path(), "-S", "--size-sort", KERNEL], cwd=UTS,
                         capture_output=True, text=True, timeout=120).stdout
    size = {}
    for line in out.splitlines():
        p = line.split()
        if len(p) == 4:                      # addr size type name
            size[p[3]] = int(p[1], 16)
    n_idle = size.get("idlethread", 0) // 8
    n_cur = size.get("curthread", 0) // 8
    if not n_idle:
        print(f"WARN: no size for idlethread in {KERNEL}; "
              f"falling back to MAXCPU={MAXCPU}", flush=True)
        return MAXCPU
    if n_idle != n_cur:
        sys.exit(f"FAIL: idlethread holds {n_idle} slots but curthread holds "
                 f"{n_cur} -- the per-hart arrays disagree, which is the "
                 f"aliasing bug class itself.")
    # secondary_stacks is MAXCPU-1 stacks of SECONDARY_STACK_SIZE (16 KiB).
    # locore.S sizes it by hand (.skip 16384 * 15), so it is the copy most
    # likely to drift out of step with the C MAXCPU.
    #
    # ⚠️ --size-sort is REQUIRED, not cosmetic: plain `nm -S` prints NO size
    # column for a symbol defined by .skip in assembly, so `size.get(...)` came
    # back 0 and the pool check quietly skipped itself -- a check that cannot
    # fail, in the tool whose whole point is that a stale constant made it
    # blind once already. --size-sort makes nm compute the extent instead.
    if "secondary_stacks" not in size:
        sys.exit("FAIL: cannot read the size of secondary_stacks from "
                 f"{KERNEL}. Do NOT read this as 'the pool is fine' -- it "
                 "means this check did not run. (nm needs -S --size-sort for "
                 ".skip-defined symbols.)")
    n_stk = size["secondary_stacks"] // 16384
    if n_stk != n_idle - 1:
        sys.exit(f"FAIL: {n_idle} hart slots but secondary_stacks holds "
                 f"{n_stk} stacks (want {n_idle - 1}). locore.S is out of step "
                 f"with MAXCPU in main.c/proc.c -- a secondary would run on a "
                 f"stack that overlaps another hart's.")
    if n_idle != MAXCPU:
        print(f"NOTE: kernel has {n_idle} hart slots, this script's default "
              f"MAXCPU says {MAXCPU}; using the binary's {n_idle}.", flush=True)
    print(f"slot width from {KERNEL}: {n_idle} slots "
          f"(idlethread={size.get('idlethread')}B, "
          f"curthread={size.get('curthread')}B, "
          f"secondary_stacks={n_stk} stacks) -- and a -smp N above this is "
          f"what the boot-hart panic exists to refuse.", flush=True)
    return n_idle


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
    # A DELIBERATE REFUSAL IS NOT A HANG. start_secondaries() panics when the
    # boot hart has no slot (bug #9's aliasing being refused rather than folded
    # silently). Without this branch that run is reported NOBOOT -- the same
    # label as a kernel that died for real -- and the tool's most important
    # PASS looks like an infrastructure failure. Same shape as an empty serial
    # log being indistinguishable from a hang, which has misled this project
    # before, so the panic is classified from its own text.
    if ">= MAXCPU" in txt and "start_secondaries" in txt:
        res, detail = "PANIC_NOSLOT", f"boot hart {bh} correctly refused"
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
    res, detail = "NOBOOT", ""
    if ready:
        hmp(s, "stop")
        # Read MAXCPU slots, not a hardcoded 8: MAXCPU is 16 (the SpacemiT K3
        # has 16 harts), and reading only the first 8 would miss an alias
        # involving a high hart entirely -- reporting CLEAN for the exact
        # topology this check exists to cover.
        idle = words(s, S["idlethread"], MAXCPU)
        cur = words(s, S["curthread"], MAXCPU)
        live = [h for h in range(MAXCPU) if idle[h]]
        detail = ("idlethread=[" +
                  " ".join("0" if not v else f"{v:#x}"[-4:] for v in idle[:smp])
                  + "] curthread=[" +
                  " ".join("0" if not v else f"{v:#x}"[-4:] for v in cur[:smp])
                  + "]")
        if bh == 0:
            res = "SKIP"          # slot 0 is legitimately the boot hart's
        elif bh >= MAXCPU:
            # The boot hart is outside the slot array entirely. This must be
            # tested BEFORE indexing idle[bh]: doing it after raised
            # IndexError and killed the whole run, so the one topology this
            # tool exists to judge (a high boot hart on a kernel that folds it)
            # produced a traceback instead of a verdict. A kernel that reaches
            # dispatch with a boot hart it has no slot for HAS aliased -- it
            # folded onto some other hart's slot -- and the panic path above is
            # the correct behaviour it failed to take.
            res = "ALIASED_OOR"
            detail += f" boot hart {bh} >= {MAXCPU} slots and did NOT panic"
        elif idle[bh] == 0:
            res = "ALIASED"       # boot hart's own slot empty => it took slot 0
        elif len(live) == min(smp, MAXCPU):
            # min(): with -smp above MAXCPU the kernel can only ever populate
            # MAXCPU slots, so comparing against smp reports every such run as
            # ODD -- a false alarm that trains the reader to ignore the field.
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
MAXCPU = slot_width()          # the binary is the authority, not the constant
attempts = int(sys.argv[1]) if len(sys.argv) > 1 else 12
smp = int(sys.argv[2]) if len(sys.argv) > 2 else 4
if smp > MAXCPU:
    print(f"NOTE: -smp {smp} exceeds the kernel's {MAXCPU} slots; expect the"
          f" start_secondaries panic on any boot hart >= {MAXCPU}.", flush=True)
tally = {}
for i in range(1, attempts + 1):
    r = one(i, smp, S)
    tally[r] = tally.get(r, 0) + 1
print("tally: " + "  ".join(f"{k}={v}" for k, v in sorted(tally.items())),
      flush=True)
# Exit nonzero if any informative run was aliased: usable as a gate.
# ALIASED_OOR counts too -- it is the same defect reached by a different route
# (a boot hart with no slot that folded instead of panicking).
sys.exit(1 if (tally.get("ALIASED") or tally.get("ALIASED_OOR")) else 0)
