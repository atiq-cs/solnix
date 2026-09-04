import socket, time, sys

sock = "/tmp/rp64/qmp.sock"
out = "/tmp/rp64/kernel/scanout.ppm"
s = socket.socket(socket.AF_UNIX)
for _ in range(20):
    try:
        s.connect(sock); break
    except OSError:
        time.sleep(0.5)

def cmd(obj):
    import json
    s.sendall((json.dumps(obj) + "\n").encode())
    time.sleep(0.4)
    return s.recv(65536).decode(errors="replace")

print("greeting:", s.recv(65536).decode(errors="replace")[:80])
print("caps:", cmd({"execute": "qmp_capabilities"})[:80])
print("dump:", cmd({"execute": "screendump", "arguments": {"filename": out}})[:200])
s.close()
