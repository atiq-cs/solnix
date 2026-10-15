#!/usr/bin/env python3
"""x1ediag-receiver -- LAN receiver for scripts/live/solnix-x1ediag.

Appends every POST to <inbox>/<host>-<boot>.<kind>.log and prints one line per
request. Text in, text on disk; no auth, so run it only on a trusted LAN and bind
it to the LAN address. Usage:
    python3 x1ediag-receiver.py [--bind 192.168.1.151] [--port 8099] [--inbox DIR]
"""
import argparse, os, re, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SAFE = re.compile(r"[^A-Za-z0-9._-]")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8099)
    ap.add_argument("--inbox", default="/tmp/x1e-diag/inbox")
    a = ap.parse_args()
    os.makedirs(a.inbox, exist_ok=True)

    class H(BaseHTTPRequestHandler):
        def do_POST(self):
            n = int(self.headers.get("Content-Length", "0") or 0)
            if n > 64 * 1024 * 1024:
                self.send_response(413); self.end_headers(); return
            body = self.rfile.read(n)
            host = SAFE.sub("_", self.headers.get("X-Host", "unknown"))[:64]
            boot = SAFE.sub("_", self.headers.get("X-Boot", "unknown"))[:64]
            kind = SAFE.sub("_", self.headers.get("X-Kind", "data"))[:32]
            mode = "wb" if kind == "acpi" else "ab"
            ext = "dat" if kind == "acpi" else "log"
            path = os.path.join(a.inbox, f"{host}-{boot}.{kind}.{ext}")
            with open(path, mode) as f:
                f.write(body)
                if ext == "log" and not body.endswith(b"\n"):
                    f.write(b"\n")
            print(f"{time.strftime('%H:%M:%S')} {self.client_address[0]} {host} {boot} {kind} {len(body)}B",
                  flush=True)
            self.send_response(200); self.end_headers(); self.wfile.write(b"ok\n")

        def log_message(self, *args):
            pass

    print(f"x1ediag receiver on {a.bind}:{a.port} -> {a.inbox}", flush=True)
    ThreadingHTTPServer((a.bind, a.port), H).serve_forever()


if __name__ == "__main__":
    sys.exit(main())
