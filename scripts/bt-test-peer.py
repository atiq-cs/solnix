#!/usr/bin/env python3
"""bt-test-peer.py -- test-only BitTorrent helpers for scripts/test-swarm.sh (never installed). Not libtorrent.

  tracker <port> [as-ip]                           a minimal HTTP tracker on 127.0.0.1 (BEP 3 + BEP 23 compact);
                                                   as-ip: list every peer under that address (the probe's ok case)
  liar <host> <port> <infohash-hex> <file> [off]   a peer that connects INTO a fetcher's listen port, claims every
                                                   piece and serves <file>; with <off> it flips that byte first, so
                                                   the fetcher's own piece-hash check is all that stands in the way
"""
import socket, struct, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import unquote_to_bytes

def tracker(port, as_ip=None):
    peers, seeds = {}, {}
    class T(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def do_GET(self):
            q = dict(kv.split("=", 1) for kv in self.path.partition("?")[2].split("&") if "=" in kv)
            ih, p = unquote_to_bytes(q.get("info_hash", "")), int(q.get("port", "0"))
            me = (as_ip or self.client_address[0], p); s = peers.setdefault(ih, set()); d = seeds.setdefault(ih, set())
            if q.get("event") == "stopped": s.discard(me); d.discard(me)
            else:
                s.add(me); (d.add if q.get("left") == "0" else d.discard)(me)
            c = b"".join(socket.inet_aton(a) + struct.pack(">H", n) for a, n in s if n)
            body = b"d8:completei%de10:incompletei%de8:intervali5e5:peers%d:%se" % (len(d), len(s) - len(d), len(c), c)
            self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
            self.wfile.write(body)
    HTTPServer(("127.0.0.1", port), T).serve_forever()

def liar(host, port, ih, path, off=None):
    data = bytearray(open(path, "rb").read())
    if off is not None:
        data[off] ^= 0xFF; print(f"liar: tampered byte {off}", flush=True)
    PL = 256 * 1024; n = (len(data) + PL - 1) // PL
    def recvn(k):
        b = b""
        while len(b) < k:
            c = s.recv(k - len(b))
            if not c: raise EOFError
            b += c
        return b
    def send(mid, payload=b""): s.sendall(struct.pack(">IB", 1 + len(payload), mid) + payload)
    for _ in range(40):  # until the fetcher listens AND has added the torrent (before that it drops the handshake)
        try:
            s = socket.create_connection((host, port), timeout=5)
            s.sendall(b"\x13BitTorrent protocol" + bytes(8) + ih + b"-SX0001-liarliarliar")
            if recvn(68)[28:48] == ih: break
        except (OSError, EOFError):
            pass
        time.sleep(0.25)
    else:
        sys.exit("liar: no handshake from the fetcher")
    bf = bytearray((n + 7) // 8)
    for i in range(n): bf[i // 8] |= 0x80 >> (i % 8)
    send(5, bytes(bf)); send(1)  # bitfield (every piece), unchoke
    sent = 0; s.settimeout(60)
    try:
        while True:
            k = struct.unpack(">I", recvn(4))[0]
            m = recvn(k) if k else b""
            if m[:1] == b"\x06":  # request <index><begin><length>
                i, b, l = struct.unpack(">III", m[1:13])
                send(7, struct.pack(">II", i, b) + bytes(data[i * PL + b: i * PL + b + l])); sent += l
    except (EOFError, OSError):
        pass
    print(f"liar: sent {sent} bytes, then the fetcher closed the connection", flush=True)

if sys.argv[1] == "tracker": tracker(int(sys.argv[2]), sys.argv[3] if len(sys.argv) > 3 else None)
elif sys.argv[1] == "liar":
    liar(sys.argv[2], int(sys.argv[3]), bytes.fromhex(sys.argv[4]), sys.argv[5], int(sys.argv[6]) if len(sys.argv) > 6 else None)
else: sys.exit(__doc__)
