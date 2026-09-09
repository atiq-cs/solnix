#!/usr/bin/env python3
"""qemu-serial-drive.py -- boot an image under qemu and DRIVE its serial console.

The capture-only harness (qemu-boottest.sh) proves a boot reaches a login prompt.
It cannot prove what happens AFTER the prompt, because -serial file: has no input
side. This connects a socket chardev instead, so an expect-style script can log
in and run the installer -- i.e. exercise the operator's real path on the
UNMODIFIED deliverable image, rather than baking an auto-install marker into it.

  qemu-serial-drive.py <img> <log> <deadline-s> <bios|uefi> <bus> [target.img]

Every wait is bounded by a single wall-clock deadline, and qemu is killed from a
finally: block, so this can never hold the caller (a prior agent lost 16h to a
foreground qemu).
"""
import os, re, socket, subprocess, sys, time, glob, shutil, tempfile

img, log, deadline_s, fw, bus = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4], sys.argv[5]
target = sys.argv[6] if len(sys.argv) > 6 else None
sock_path = tempfile.mktemp(prefix="/tmp/qsd-", suffix=".sock")
deadline = time.time() + deadline_s

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
        "nvme":   ["-device", "nvme,drive=d0,serial=solnix0"]}[bus]
if target:
    # install target on virtio too: illumos's nvme driver panics on qemu NVMe.
    cmd += ["-drive", f"file={target},format=raw,if=none,id=t0", "-device", "virtio-blk-pci,drive=t0"]
cmd += ["-chardev", f"socket,id=s0,path={sock_path},server=on,wait=off", "-serial", "chardev:s0", "-boot", "c"]

logf = open(log, "wb", buffering=0)
buf = bytearray()
errf = open(log + ".qemu-stderr", "wb")
proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=errf)
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
            return b""   # qemu gone; the deadline loop / poll() ends the wait
        if d: logf.write(d); buf.extend(d)
        return d

    def expect(pat, what):
        """Wait for pat. Returns True/False; never raises on timeout."""
        rx = re.compile(pat.encode())
        while time.time() < deadline:
            if rx.search(buf): 
                print(f"[drive] SAW {what}", flush=True); return True
            if proc.poll() is not None:
                print(f"[drive] qemu EXITED while waiting for {what}", flush=True); return False
            pump()
        print(f"[drive] TIMEOUT waiting for {what}", flush=True)
        return False

    def send(line):
        print(f"[drive] SEND {line!r}", flush=True)
        s.sendall(line.encode() + b"\n")

    if not expect(r"console login:", "console login prompt"): sys.exit(2)
    time.sleep(2); send("root")
    # empty root password (oi-make-livecd.sh clears it so console recovery works)
    time.sleep(3); send("")
    time.sleep(4); send("echo MARKER-LOGIN-OK-$((6*7))")
    if not expect(r"MARKER-LOGIN-OK-42", "root shell echo"): sys.exit(3)
    send("id; uname -a; ls -l /usr/sbin/solnix-install; echo MARKER-IDENT-DONE")
    expect(r"MARKER-IDENT-DONE", "ident block")
    if target:
        send("ls /dev/rdsk | head -40; echo MARKER-DISKS-DONE")
        expect(r"MARKER-DISKS-DONE", "disk list")
        # run the REAL installer at the operator's own hand, to the SECOND disk.
        # Pick the target by ELIMINATION, never by a hardcoded name: the second
        # virtio disk enumerated as c2t0d0, not the assumed c1t1d0, and
        # solnix-install's own guard correctly refused with "target disk c1t1d0
        # not present". $BOOTDISK is the media itself and must be excluded.
        tgt = os.environ.get("SOLNIX_TARGET_DISK", "c2t0d0")
        send(f"SOLNIX_POOL=rpool SOLNIX_ALLOW_RPOOL=1 /usr/sbin/solnix-install {tgt} "
             "> /tmp/inst.log 2>&1; echo MARKER-INSTALL-RC=$?")
        expect(r"MARKER-INSTALL-RC=\d+", "installer to finish")
        send("tail -40 /tmp/inst.log; echo MARKER-TAIL-DONE")
        expect(r"MARKER-TAIL-DONE", "installer log tail")
        send("zpool list; zpool get bootfs rpool; echo MARKER-POOL-DONE")
        expect(r"MARKER-POOL-DONE", "pool state")
    while time.time() < deadline and pump():
        pass
finally:
    proc.kill()
    try: proc.wait(10)
    except Exception: pass
    logf.close()
    try: os.unlink(sock_path)
    except OSError: pass
    print(f"[drive] done; log bytes: {os.path.getsize(log)}", flush=True)
