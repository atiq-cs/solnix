#!/usr/bin/env python3
"""fbboot.py -- boot a disk image under QEMU/OVMF and OBSERVE THE FRAMEBUFFER.

Needed because an installed system configured with console="text" writes NOTHING
to the serial line, so an empty serial log cannot distinguish "booted fine on the
framebuffer" from "did not boot at all". This drives QMP screendump and measures
the screen, then greps the pixels for text-like content.

  fbboot.py <disk.img> <outprefix> [seconds]

Writes <outprefix>-tNNN.ppm screenshots and prints one summary line per shot:
  t=NN nonblank_rows=R ink_pixels=P
A booted illumos console shows hundreds of ink pixels across many rows; the
firmware's "no bootable device" screen shows a small, stable amount; a black
screen shows ~0.
"""
import os, socket, subprocess, sys, time, json, glob

img, prefix = sys.argv[1], sys.argv[2]
secs = int(sys.argv[3]) if len(sys.argv) > 3 else 240

code = glob.glob('/nix/store/*-OVMF-*/FV/OVMF_CODE.fd')[0]
vars_src = glob.glob('/nix/store/*-OVMF-*/FV/OVMF_VARS.fd')[0]
varsf = prefix + '-vars.fd'
subprocess.run(['cp', vars_src, varsf], check=True)
os.chmod(varsf, 0o644)          # nix-store source is 0444; qemu must WRITE the vars
qmp = prefix + '-qmp.sock'
for f in (qmp,):
    if os.path.exists(f):
        os.unlink(f)

accel = 'kvm' if os.access('/dev/kvm', os.W_OK) else 'tcg'
cpu = 'host' if accel == 'kvm' else 'max'
cmd = ['qemu-system-x86_64', '-cpu', cpu, '-accel', accel,
       '-m', '6144', '-smp', '2', '-machine', 'q35',
       '-drive', f'if=pflash,format=raw,readonly=on,file={code}',
       '-drive', f'if=pflash,format=raw,file={varsf}',
       '-drive', f'file={img},format=raw,if=none,id=d0,snapshot=on',
       '-device', 'ahci,id=ahci0', '-device', 'ide-hd,drive=d0,bus=ahci0.0',
       '-boot', 'c', '-vga', 'std', '-display', 'none',
       '-serial', f'file:{prefix}-serial.txt',
       '-qmp', f'unix:{qmp},server,nowait']
p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def ppm_stats(path):
    """count rows containing non-background pixels, and total 'ink' pixels."""
    with open(path, 'rb') as f:
        data = f.read()
    # P6 header: magic, width height, maxval, then binary RGB
    parts, idx = [], 0
    while len(parts) < 4:
        while data[idx:idx+1].isspace():
            idx += 1
        if data[idx:idx+1] == b'#':
            while data[idx:idx+1] != b'\n':
                idx += 1
            continue
        s = idx
        while not data[idx:idx+1].isspace():
            idx += 1
        parts.append(data[s:idx])
    idx += 1
    w, h = int(parts[1]), int(parts[2])
    px = data[idx:]
    rows, ink = 0, 0
    for y in range(h):
        base = y * w * 3
        rowink = 0
        for x in range(0, w * 3, 3):
            o = base + x
            if o + 2 >= len(px):
                break
            if px[o] > 60 or px[o+1] > 60 or px[o+2] > 60:
                rowink += 1
        if rowink:
            rows += 1
            ink += rowink
    return w, h, rows, ink

sock = None
for _ in range(120):
    s = socket.socket(socket.AF_UNIX)
    try:
        s.connect(qmp)
        sock = s
        break
    except OSError:
        s.close()
        time.sleep(0.5)
if sock is None:
    print('QMP connect failed'); p.kill(); sys.exit(1)
f = sock.makefile('rwb')
f.readline()                                    # greeting
f.write(b'{"execute":"qmp_capabilities"}\n'); f.flush(); f.readline()

t0 = time.time()
shots = []
try:
    while time.time() - t0 < secs:
        time.sleep(30)
        t = int(time.time() - t0)
        out = f'{prefix}-t{t:03d}.ppm'
        f.write(json.dumps({"execute": "screendump",
                            "arguments": {"filename": out}}).encode() + b'\n')
        f.flush()
        f.readline()
        time.sleep(1)
        if os.path.exists(out):
            w, h, rows, ink = ppm_stats(out)
            print(f't={t:3d} {w}x{h} nonblank_rows={rows:4d} ink_pixels={ink}', flush=True)
            shots.append((t, rows, ink))
finally:
    p.kill()
    try:
        p.wait(timeout=10)
    except Exception:
        pass
    os.unlink(varsf)
    if os.path.exists(qmp):
        os.unlink(qmp)

if shots:
    peak = max(s[2] for s in shots)
    last = shots[-1]
    print(f'PEAK_INK={peak} LAST_INK={last[2]} LAST_ROWS={last[1]}')
