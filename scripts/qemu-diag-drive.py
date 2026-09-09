#!/usr/bin/env python3
"""qemu-diag-drive.py -- boot the live media under qemu and run a DIAGNOSTIC
script over the serial console, with a REAL USB HID keyboard attached.

Why a USB HID keyboard matters: the default qemu i440fx/q35 keyboard is PS/2
(illumos binds kb8042), which needs neither HID report-descriptor parsing nor the
usbkbm/kbtrans STREAMS chain. Adding `-device qemu-xhci -device usb-kbd` gives a
genuine USB HID class-3 device whose report descriptor illumos's hid(4D) +
hidparser must actually parse, so hid_attach / usbkbm / kbtrans / conskbd DO get
exercised. It is not the X1's own descriptor, so it cannot prove the X1 works,
but it can prove the chain binds at all -- which the PS/2 path cannot.

  qemu-diag-drive.py <img> <log> <deadline-s> <bios|uefi> <bus> <cmdfile>

cmdfile: one shell command per line, run after login. Each line's output is
bracketed by MARKER-<n>-BEGIN/END so the log is machine-readable.
Every wait is bounded by one wall-clock deadline and qemu is killed in finally:.
"""
import os, re, socket, subprocess, sys, time, glob, shutil, tempfile

img, log, deadline_s, fw, bus, cmdfile = sys.argv[1:7]
deadline = time.time() + float(deadline_s)
cmds = [l.rstrip("\n") for l in open(cmdfile) if l.strip() and not l.startswith("#")]
sock_path = tempfile.mktemp(prefix="/tmp/qdd-", suffix=".sock")

ovmf_code = sorted(glob.glob("/nix/store/*-OVMF-*/FV/OVMF_CODE.fd"))[0]
ovmf_vars_src = sorted(glob.glob("/nix/store/*-OVMF-*/FV/OVMF_VARS.fd"))[0]

cmd = ["qemu-system-x86_64", "-m", "6144", "-smp", "2", "-machine", "q35", "-display", "none"]
cmd += ["-cpu", "host", "-accel", "kvm"] if os.access("/dev/kvm", os.W_OK) else ["-cpu", "max", "-accel", "tcg"]
if fw == "uefi":
    v = tempfile.mktemp(prefix="/tmp/ovmf-vars-", suffix=".fd")
    shutil.copy(ovmf_vars_src, v); os.chmod(v, 0o600)
    cmd += ["-drive", f"if=pflash,format=raw,readonly=on,file={ovmf_code}",
            "-drive", f"if=pflash,format=raw,file={v}"]
cmd += ["-drive", f"file={img},format=raw,if=none,id=d0"]
cmd += {"virtio": ["-device", "virtio-blk-pci,drive=d0"],
        "usb":    ["-device", "qemu-xhci,id=xhci0", "-device", "usb-storage,bus=xhci0.0,drive=d0"],
        "ahci":   ["-device", "ahci,id=a0", "-device", "ide-hd,drive=d0,bus=a0.0"]}[bus]
# the REAL USB HID keyboard + mouse, on their own xhci controller
cmd += ["-device", "qemu-xhci,id=xhcikb", "-device", "usb-kbd,bus=xhcikb.0",
        "-device", "usb-mouse,bus=xhcikb.0"]
cmd += ["-chardev", f"socket,id=s0,path={sock_path},server=on,wait=off",
        "-serial", "chardev:s0", "-boot", "c"]

logf = open(log, "wb", buffering=0)
buf = bytearray()
errf = open(log + ".qemu-stderr", "wb")
print("[diag] " + " ".join(cmd), flush=True)
proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=errf)
rc = 0
try:
    for _ in range(100):
        if os.path.exists(sock_path): break
        time.sleep(0.1)
    s = socket.socket(socket.AF_UNIX); s.connect(sock_path); s.settimeout(1.0)

    def pump():
        try: d = s.recv(65536)
        except socket.timeout: return b""
        except (ConnectionResetError, BrokenPipeError, OSError): return b""
        if d: logf.write(d); buf.extend(d)
        return d

    def expect(pat, what):
        rx = re.compile(pat.encode())
        while time.time() < deadline:
            if rx.search(buf): print(f"[diag] SAW {what}", flush=True); return True
            if proc.poll() is not None:
                print(f"[diag] qemu EXITED waiting for {what}", flush=True); return False
            pump()
        print(f"[diag] TIMEOUT waiting for {what}", flush=True); return False

    def send(line):
        s.sendall(line.encode() + b"\n")

    if not expect(r"console login:", "login prompt"): sys.exit(2)
    time.sleep(2); send("root")
    time.sleep(3); send("")
    time.sleep(4); send("echo MARKER-LOGIN-OK-$((6*7))")
    if not expect(r"MARKER-LOGIN-OK-42", "root shell"): sys.exit(3)
    for i, c in enumerate(cmds):
        send(f"echo MARKER-{i}-BEGIN; {c} 2>&1; echo MARKER-{i}-END-rc=$?")
        if not expect(rf"MARKER-{i}-END-rc=", f"cmd {i}: {c[:50]}"):
            rc = 4; break
    while time.time() < deadline and pump(): pass
finally:
    proc.kill()
    try: proc.wait(10)
    except Exception: pass
    logf.close()
    try: os.unlink(sock_path)
    except OSError: pass
    print(f"[diag] done rc={rc}; log bytes {os.path.getsize(log)}", flush=True)
sys.exit(rc)
