#!/usr/bin/env python3
"""qemu-diag-cmds.py -- boot an image under qemu, log in on the serial console,
and run an arbitrary list of diagnostic commands.

Same bounded-deadline + finally-kill discipline as qemu-serial-drive.py (a prior
run lost 16h to a foreground qemu). The command list comes from a file, one
shell command per line, so a diagnosis can be re-run without editing code.

  qemu-diag-cmds.py <img> <log> <deadline-s> <bios|uefi> <bus> <cmdfile>

Each command is sent, then the harness waits for a completion marker the harness
itself appends, so a command that produces no output still synchronises.

The marker is emitted SPLIT (`echo "MK-0-DON""E"`) so the console's own ECHO of
the command line does NOT contain the literal the harness waits for. Without the
split, expect() matched the echo rather than the output and fired the next command
while the previous was still running: every command overlapped and the transcript
interleaved into nonsense. An instrument that corrupts its own measurement.
"""
import os, re, socket, subprocess, sys, time, glob, shutil, tempfile

img, log, deadline_s, fw, bus, cmdfile = sys.argv[1:7]
deadline = time.time() + float(deadline_s)
sock_path = tempfile.mktemp(prefix="/tmp/qdc-", suffix=".sock")
cmds = [l.rstrip("\n") for l in open(cmdfile) if l.strip() and not l.startswith("#")]

ovmf_code = sorted(glob.glob("/nix/store/*-OVMF-*/FV/OVMF_CODE.fd"))[0]
ovmf_vars_src = sorted(glob.glob("/nix/store/*-OVMF-*/FV/OVMF_VARS.fd"))[0]

cmd = ["qemu-system-x86_64", "-m", "6144", "-smp", "2", "-machine", "q35", "-display", "none"]
cmd += ["-cpu", "host", "-accel", "kvm"] if os.access("/dev/kvm", os.W_OK) else ["-cpu", "max", "-accel", "tcg"]
if fw == "uefi":
    v = tempfile.mktemp(prefix="/tmp/ovmf-vars-", suffix=".fd")
    shutil.copy(ovmf_vars_src, v)
    os.chmod(v, 0o600)   # nix-store copy is r--r--r-- and qemu needs it WRITABLE
    cmd += ["-drive", f"if=pflash,format=raw,readonly=on,file={ovmf_code}",
            "-drive", f"if=pflash,format=raw,file={v}"]
cmd += ["-drive", f"file={img},format=raw,if=none,id=d0"]
cmd += {"virtio": ["-device", "virtio-blk-pci,drive=d0"],
        "ahci":   ["-device", "ahci,id=a0", "-device", "ide-hd,drive=d0,bus=a0.0"],
        "nvme":   ["-device", "nvme,drive=d0,serial=solnix0"],
        # the X1 boots from USB, and the ZFS/sad faults appear ONLY on this bus
        # (2/2 usb boots vs 0/16 virtio/ahci/cdrom), so it is the bus that matters.
        "usb":    ["-device", "qemu-xhci,id=xhci", "-device", "usb-storage,bus=xhci.0,drive=d0"]}[bus]
cmd += ["-chardev", f"socket,id=s0,path={sock_path},server=on,wait=off", "-serial", "chardev:s0", "-boot", "c"]

logf = open(log, "wb", buffering=0)
buf = bytearray()
errf = open(log + ".qemu-stderr", "wb")
proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=errf)
rc = 0
try:
    for _ in range(100):
        if os.path.exists(sock_path): break
        time.sleep(0.1)
    s = socket.socket(socket.AF_UNIX); s.connect(sock_path); s.settimeout(1.0)

    def pump():
        try:
            d = s.recv(65536)
        except socket.timeout:
            return b""
        except (ConnectionResetError, BrokenPipeError, OSError):
            return b""
        if d: logf.write(d); buf.extend(d)
        return d

    def expect(pat, what):
        rx = re.compile(pat.encode())
        while time.time() < deadline:
            if rx.search(buf):
                print(f"[diag] SAW {what}", flush=True); return True
            if proc.poll() is not None:
                print(f"[diag] qemu EXITED while waiting for {what}", flush=True); return False
            pump()
        print(f"[diag] TIMEOUT waiting for {what}", flush=True)
        return False

    def send(line):
        print(f"[diag] SEND {line!r}", flush=True)
        s.sendall(line.encode() + b"\n")

    if not expect(r"console login:", "console login prompt"): sys.exit(2)
    time.sleep(2); send("root")
    time.sleep(3); send("")            # empty root password on live media
    time.sleep(4); send('echo "LOGIN-OK"-$((6*7))')
    if not expect(r"LOGIN-OK-42", "root shell echo"): sys.exit(3)
    for i, c in enumerate(cmds):
        send(f'{c}; echo "MK-{i}-DON""E"')
        if not expect(rf"MK-{i}-DONE", f"cmd {i}: {c[:50]}"):
            rc = 4
            break
    time.sleep(2); pump()
finally:
    proc.kill()
    try: proc.wait(10)
    except Exception: pass
    logf.close()
    try: os.unlink(sock_path)
    except OSError: pass
    print(f"[diag] done rc={rc}; log bytes: {os.path.getsize(log)}", flush=True)
sys.exit(rc)
