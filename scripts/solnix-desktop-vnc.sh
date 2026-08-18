#!/usr/bin/bash
# solnix desktop over VNC (software-rendered, no GPU).
# One command: starts an Xvfb software X server, a window manager, a couple
# of lightweight native X clients, and an x11vnc server bound to
# 127.0.0.1:5900 ONLY (never the internet; connect via an SSH tunnel).
#
# Connect from a laptop:
#   ssh -L 5900:localhost:5900 root@<node-ip>
#   then point a VNC viewer at localhost:5900   (password: solnix)
set -u

export PATH=/usr/bin:/usr/X11/bin:$PATH
DISPLAY_NUM=":1"
GEOM="1280x800x24"
VNC_PASSFILE=/root/.vnc/passwd
LOG=/root/solnix-desktop.log

# Software rendering only: force mesa's software rasteriser (swrast/llvmpipe),
# never a GPU driver. The host mesa (21.3.9) ships swrast_dri.so. GTK apps
# reach GL via libepoxy's dlopen dispatch.
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export GDK_BACKEND=x11
# Force GTK4 onto the cairo (CPU) renderer, NOT GL: software EGL/llvmpipe GL
# under a headless Xvfb pegs the CPU and can wedge the box. cairo is safe.
export GSK_RENDERER=cairo
export LIBGL_ALWAYS_INDIRECT=0

mkdir -p /root/.vnc
: > "$LOG"

log() { echo "[solnix-vnc] $*" | tee -a "$LOG"; }

log "cleaning old sessions"
pkill -f "Xvfb $DISPLAY_NUM" 2>/dev/null
pkill x11vnc 2>/dev/null
rm -f /tmp/.X11-unix/X1 2>/dev/null
sleep 1

log "starting Xvfb (software framebuffer) on $DISPLAY_NUM"
Xvfb "$DISPLAY_NUM" -screen 0 "$GEOM" -nolisten tcp >>"$LOG" 2>&1 &
XVFB_PID=$!
export DISPLAY="$DISPLAY_NUM"

for i in $(seq 1 40); do
  xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1 && break
  sleep 0.5
done
if ! xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1; then
  log "ERROR: Xvfb did not come up; see $LOG"; exit 1
fi
log "Xvfb up (pid $XVFB_PID)"

xsetroot -solid "#204060" 2>/dev/null
log "starting twm"
twm >>"$LOG" 2>&1 &

# Lightweight visible clients ONLY (no software-GL demos: those wedge the box).
log "launching xterm windows"
xterm -geometry 100x30+30+30 -T "solnix desktop -- SunOS illumos" \
      -e /usr/bin/bash -lc 'uname -a; echo; echo "solnix desktop over VNC (Xvfb + twm + x11vnc, software mesa)"; echo; exec /usr/bin/bash' \
      >>"$LOG" 2>&1 &
sleep 1
xterm -geometry 80x20+30+430 -T "solnix shell" >>"$LOG" 2>&1 &

# VNC password (idempotent)
[ -f "$VNC_PASSFILE" ] || x11vnc -storepasswd solnix "$VNC_PASSFILE" >>"$LOG" 2>&1

log "starting x11vnc bound to 127.0.0.1:5900 ONLY"
# -localhost => loopback bind only, unreachable off-box (SSH tunnel only).
# No -autoport: honour exactly 5900. nohup + full fd redirect so it detaches
# cleanly and never holds an ssh session's stdout pipe open.
nohup x11vnc -display "$DISPLAY_NUM" -rfbauth "$VNC_PASSFILE" \
       -localhost -rfbport 5900 -noipv6 \
       -forever -shared -noxdamage \
       >>"$LOG" 2>&1 </dev/null &
VNC_PID=$!
sleep 3

log "--- status ---"
netstat -an -f inet 2>/dev/null | grep "127.0.0.1.5900" | tee -a "$LOG"
log "x11vnc pid $VNC_PID  Xvfb pid $XVFB_PID"
log "READY. From laptop:  ssh -L 5900:localhost:5900 root@<node-ip>  then VNC to localhost:5900 (password: solnix)"
