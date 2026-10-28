#!/usr/bin/env python3
# tamper-upstream.py <port> <mode>: a fake cache.solnix.io on 127.0.0.1 for the negative controls (OI host only).
# It relays https://cache.solnix.io, and for jq's narinfo (mode sig) flips one byte of Sig, or (mode nar) points
# URL/FileHash at the real NAR but serves it with one byte flipped.
import sys, urllib.request, http.server
port, mode = int(sys.argv[1]), sys.argv[2]
JQ = "n9aq9aa2bmg6jf7544r69p2zmipfqkaw"
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        try:
            body = urllib.request.urlopen(urllib.request.Request("https://cache.solnix.io" + self.path, headers={"User-Agent": "curl/8"}), timeout=20).read()
        except Exception:
            self.send_response(404); self.end_headers(); return
        if mode == "sig" and self.path == f"/{JQ}.narinfo":
            t = body.decode().splitlines(); i = [n for n, l in enumerate(t) if l.startswith("Sig: ")][0]
            s = t[i]; c = s[-5]; t[i] = s[:-5] + ("A" if c != "A" else "B") + s[-4:]; body = ("\n".join(t) + "\n").encode()
        if mode == "nar" and self.path.startswith("/nar/0j3jx0gq"):
            import lzma  # a VALID xz of a NAR with one content byte flipped: only NarHash (and FileHash) can catch it
            b = bytearray(lzma.decompress(body)); b[len(b) // 2] ^= 1; body = lzma.compress(bytes(b), format=lzma.FORMAT_XZ)
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
