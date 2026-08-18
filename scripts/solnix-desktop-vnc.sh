#!/usr/bin/bash
# solnix desktop over VNC (software-rendered, no GPU).
# One command: starts an Xvfb software X server, a window manager, a couple
# of native GTK apps, and an x11vnc server bound to 127.0.0.1:5900 ONLY.
#
# Connect from a laptop:
#   ssh -L 5900:localhost:5900 root@<node-ip>
#   then point a VNC viewer at localhost:5900  (password: solnix)
set -u

export PATH=/usr/bin:/usr/X11/bin:$PATH
DISPLAY_NUM=":1"
GEOM="1280x800x24"
VNC_PASSFILE=/root/.vnc/passwd
LOG=/root/solnix-desktop.log

# Software rendering: force mesa's software rasteriser (swrast/llvmpipe),
# never a GPU driver. The host mesa (21.3.9) ships swrast_dri.so.
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export MESA_GL_VERSION_OVERRIDE=3.3
export GDK_BACKEND=x11
# GTK4 GL can be flaky on software EGL; let it fall back to cairo if GL fails.
export GSK_RENDERER=cairo

mkdir -p /root/.vnc
: > "$LOG"

echo "[solnix-vnc] cleaning old sessions" | tee -a "$LOG"
pkill -f "Xvfb $DISPLAY_NUM" 2>/dev/null
pkill x11vnc 2>/dev/null
rm -f /tmp/.X11-unix/X1 2>/dev/null
sleep 1

echo "[solnix-vnc] starting Xvfb (software framebuffer) on $DISPLAY_NUM" | tee -a "$LOG"
Xvfb "$DISPLAY_NUM" -screen 0 "$GEOM" -nolisten tcp >>"$LOG" 2>&1 &
XVFB_PID=$!
export DISPLAY="$DISPLAY_NUM"

# wait for the X server to accept connections
for i in $(seq 1 30); do
  if xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1; then break; fi
  sleep 0.5
done
if ! xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1; then
  echo "[solnix-vnc] ERROR: Xvfb did not come up; see $LOG" | tee -a "$LOG"
  exit 1
fi
echo "[solnix-vnc] Xvfb up (pid $XVFB_PID)" | tee -a "$LOG"

# a root-window colour + a window manager so apps have decorations
xsetroot -solid "#204060" 2>/dev/null
echo "[solnix-vnc] starting twm" | tee -a "$LOG"
twm >>"$LOG" 2>&1 &

# some visible native solnix apps
echo "[solnix-vnc] launching xterm + gtk4-demo + gtk3-demo" | tee -a "$LOG"
xterm -geometry 90x28+20+20 -T "solnix xterm" >>"$LOG" 2>&1 &
sleep 1
gtk4-demo >>"$LOG" 2>&1 &
sleep 1
gtk3-demo >>"$LOG" 2>&1 &

# VNC password (idempotent)
if [ ! -f "$VNC_PASSFILE" ]; then
  x11vnc -storepasswd solnix "$VNC_PASSFILE" >>"$LOG" 2>&1
fi

echo "[solnix-vnc] starting x11vnc bound to 127.0.0.1:5900 ONLY" | tee -a "$LOG"
# -localhost + -listen 127.0.0.1  => never reachable off-box; SSH tunnel only.
x11vnc -display "$DISPLAY_NUM" -rfbauth "$VNC_PASSFILE" \
       -localhost -listen 127.0.0.1 -rfbport 5900 \
       -forever -shared -noxdamage -o "$LOG" >>"$LOG" 2>&1 &
VNC_PID=$!
sleep 2

echo "[solnix-vnc] --- status ---" | tee -a "$LOG"
netstat -an 2>/dev/null | grep 5900 | tee -a "$LOG"
echo "[solnix-vnc] x11vnc pid $VNC_PID  Xvfb pid $XVFB_PID" | tee -a "$LOG"
echo "[solnix-vnc] READY. From laptop:  ssh -L 5900:localhost:5900 root@<node-ip>  then VNC to localhost:5900 (password: solnix)" | tee -a "$LOG"
