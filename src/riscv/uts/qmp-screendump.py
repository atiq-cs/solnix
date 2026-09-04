#!/usr/bin/env python3
"""
qmp-screendump.py -- take a QMP screendump of a running QEMU's scanout.

This is the evidence-collection half of the scanout proof: it asks the HOST
(QEMU) what its display surface currently contains, which is only what the guest
actually pushed through SET_SCANOUT + TRANSFER_TO_HOST_2D + RESOURCE_FLUSH. A
guest that wrote its framebuffer but never presented it produces a blank dump,
so the dump cannot be faked by the guest simply claiming success.

Usage: qmp-screendump.py <qmp-unix-socket> <out.ppm>

The generalized form of src/riscv-port/rp64/kernel/screendump.py (which had the
socket and output paths hardcoded to one node's /tmp layout, so it could not be
rerun anywhere else).
"""
import json
import socket
import sys
import time


def qmp(sock, obj):
    """Send one QMP command and return the first reply that is not an event.

    QMP interleaves asynchronous events with command replies, so reading one
    datagram and hoping it is the reply is a race. Read until a message with a
    'return' or 'error' key arrives.
    """
    sock.sendall((json.dumps(obj) + "\n").encode())
    buf = b""
    deadline = time.time() + 10
    while time.time() < deadline:
        chunk = sock.recv(65536)
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if not line.strip():
                continue
            msg = json.loads(line)
            if "return" in msg or "error" in msg:
                return msg
            # else: an event; keep reading
    raise TimeoutError(f"no QMP reply to {obj['execute']}")


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    sockpath, out = sys.argv[1], sys.argv[2]

    s = socket.socket(socket.AF_UNIX)
    # The socket may not exist yet if qemu is still starting.
    for _ in range(40):
        try:
            s.connect(sockpath)
            break
        except OSError:
            time.sleep(0.25)
    else:
        print(f"screendump: cannot connect to {sockpath}")
        return 1

    # The greeting arrives unsolicited before capabilities negotiation.
    s.recv(65536)
    r = qmp(s, {"execute": "qmp_capabilities"})
    if "error" in r:
        print("screendump: capabilities failed:", r["error"])
        return 1

    r = qmp(s, {"execute": "screendump", "arguments": {"filename": out}})
    s.close()
    if "error" in r:
        print("screendump: failed:", r["error"])
        return 1
    print(f"screendump: wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
