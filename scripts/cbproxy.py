#!/usr/bin/env python3
# Cache-buster proxy: forwards GET to cache.solnix.io adding ?x=<rand> to defeat
# Cloudflare stale-404 negative caching. Listens on 127.0.0.1:8899.
import http.server, socketserver, urllib.request, os, sys

UP = "https://cache.solnix.io"
PORT = 8899

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        url = UP + self.path + ("&" if "?" in self.path else "?") + "x=" + os.urandom(4).hex()
        req = urllib.request.Request(url, headers={"User-Agent": "curl/8.21.0", "Accept": "*/*"})
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                data = r.read()
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            self.end_headers()
        except Exception as e:
            self.send_response(502)
            self.end_headers()
    def do_HEAD(self):
        self.do_GET()
    def log_message(self, *a):
        pass

class TS(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True

if __name__ == "__main__":
    TS(("127.0.0.1", PORT), H).serve_forever()
