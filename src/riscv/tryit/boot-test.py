#!/usr/bin/env python3
"""boot-test.py TEMU IMGDIR LOG -- tryit1: boot the demo under native TinyEMU (temu) on a pty and run the
checks solnix.io infra will run through the page: login: within 20 s, log in as root (no password),
uname -a, ls /, a pipeline, a Backspace edit (0x7f and 0x08), ^C on sleep 30. Prints CHECK PASS/FAIL lines
and exits 0 only if all pass. The native cfg names root.img directly (temu reads no split disk)."""
import os, pty, re, select, sys, time
temu, img, log = sys.argv[1:4]
cfg = os.path.join(img, "native.cfg")
open(cfg, "w").write(open(os.path.join(img, "solnix.cfg")).read().replace('"disk/blk.txt"', '"root.img"'))
argv = [temu, cfg]
if os.path.basename(temu).startswith("qemu"):	# SMP check: qemu virt -smp $SMP, the kernel ELF, the root as fs0
    import subprocess
    w = os.path.join(img, "qemu-w"); os.makedirs(w, exist_ok=True)
    subprocess.check_call("dd if=/dev/zero of=%s/disk.img bs=512 count=2048 status=none; "
        "printf '\\x55\\xaa' | dd of=%s/disk.img bs=1 seek=510 conv=notrunc status=none; cp %s/root.img %s/root.img" % (w, w, img, w), shell=True)
    argv = [temu, "-machine", "virt", "-smp", os.environ.get("SMP", "4"), "-m", "512M", "-nographic", "-bios", "default",
        "-kernel", os.environ["KERNEL"], "-global", "virtio-mmio.force-legacy=false",
        "-drive", "file=%s/disk.img,if=none,id=hd0,format=raw" % w, "-device", "virtio-blk-device,drive=hd0",
        "-drive", "file=%s/root.img,if=none,id=fs0,format=raw" % w, "-device", "virtio-blk-device,drive=fs0"]
pid, fd = pty.fork()
if pid == 0:
    os.execv(argv[0], argv)
buf, t0, out = b"", time.time(), open(log, "wb")
def until(pat, tmo):
    global buf
    end = time.time() + tmo
    while time.time() < end:
        m = re.search(pat, buf, re.S)
        if m:
            return m
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                d = os.read(fd, 4096)
            except OSError:
                break
            buf += d; out.write(d); out.flush()
    return None
def send(s, pace=0.03):
    for c in s:
        os.write(fd, bytes([c])); time.sleep(pace)
res = []
def check(name, ok, info=""):
    res.append(ok); print("CHECK %s %s %s" % ("PASS" if ok else "FAIL", name, info)); sys.stdout.flush()
m = until(rb"solnix-riscv login: ", 60)
check("login-prompt<20s", m is not None and time.time() - t0 < 20, "%.1fs" % (time.time() - t0))
mark = len(buf); send(b"root\r")
check("shell-prompt", until(rb"# $", 20) is not None)
def cmd(name, line, want, tmo=20):
    global buf
    mark = len(buf); send(line)
    m = until(rb"(?s).{%d}.*?%s.*?# $" % (mark, want), tmo)
    check(name, m is not None, repr(buf[mark:][-120:]) if m is None else "")
cmd("uname", b"uname -a\r", rb"SunOS")
cmd("ls-root", b"ls /\r", rb"bin.*etc.*root.*sbin")
cmd("pipeline", b"grep an /etc/words | sort | uniq -c | sort -rn | head -1\r", rb"2 banana")
cmd("backspace-0x7f", b"echo abX\x7fc\r", rb"\nabc\r*\n")
cmd("backspace-0x08", b"echo deY\x08f\r", rb"\ndef\r*\n")
cmd("release", b"cat /etc/release\r", rb"Solnix riscv64")
mark = len(buf); t1 = time.time(); send(b"sleep 3; echo SLEPT\r")	# control: sleep really sleeps
m = until(rb"(?s).{%d}.*\nSLEPT\r*\n# $" % mark, 15)
check("sleep3-control", m is not None and time.time() - t1 > 2.5, "%.1fs" % (time.time() - t1))
mark = len(buf); send(b"sleep 30\r"); time.sleep(2); t1 = time.time(); send(b"\x03")
m = until(rb"(?s).{%d}.*\^C.*?# $" % mark, 10)
check("ctrl-c-sleep30", m is not None and time.time() - t1 < 5, "%.1fs" % (time.time() - t1))
cmd("after-ctrl-c", b"echo X$((6*7))X\r", rb"X42X")
mark = len(buf); send(b"exit\r")	# logout: init respawns the getty; the new session gets the console as ctty
check("relogin-prompt", until(rb"(?s).{%d}.*solnix-riscv login: $" % mark, 20) is not None)
send(b"root\r"); until(rb"# $", 20)
mark = len(buf); send(b"sleep 30\r"); time.sleep(2); t1 = time.time(); send(b"\x03")
m = until(rb"(?s).{%d}.*\^C.*?# $" % mark, 10)
check("relogin-ctrl-c", m is not None and time.time() - t1 < 5, "%.1fs" % (time.time() - t1))
bad = [l for l in buf.decode("latin1").splitlines() if re.search(r"\[(fork|exec|elf|exit)\]|\[ld\.so|FAIL|WARN", l)]
check("quiet-console", not bad, repr(bad[:3]))
os.kill(pid, 9)
print("SUMMARY %d/%d" % (sum(res), len(res)))
sys.exit(0 if all(res) else 1)
