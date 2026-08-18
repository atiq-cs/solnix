#!/bin/sh
# solnix nix-pure Wayland desktop session:
#   Xvfb (virtual X display)  <-  smallvil (nix-pure smithay Wayland compositor,
#   winit-x11 backend, softpipe/llvmpipe SW GL)  <-  GTK4/libadwaita client
#   (nix-pure, GDK_BACKEND=wayland).  x11vnc exports the Xvfb to 127.0.0.1:5900.
#
# All toolkit pieces (compositor, GTK4 4.22.4, libadwaita 1.9.2, wayland libs)
# are /nix/store. Only the illumos base libc/libm/pthread and the OI-pkg Mesa
# softpipe libGL/libEGL (dlopen'd by the winit EGL backend) are non-nix -- there
# is no nix-pure Mesa realised on this host yet.
#
# Usage:  /root/solnix-cosmic-session.sh            # launches the GTK4 client
#         /root/solnix-cosmic-session.sh -c PROG    # launches PROG as the client
#         /root/solnix-cosmic-session.sh --shm      # launches the wl_shm test client
set -e

export PATH=/nix/store/q9cgfd001i87byzv866v1dvdh28jji7l-nix-2.24.15/bin:/usr/bin:$PATH

DISP=:99
GEOM=1280x800x24
XDG=/tmp/xdg-runtime
SMALLVIL=/root/smithay/target/x86_64-unknown-illumos/debug/smallvil
XVFB=/usr/bin/Xvfb
X11VNC=/usr/bin/x11vnc
NIXLIBS="$(cat /root/nix-gtk-libpath.txt)"
WLLIB=/nix/store/9paxj1538q1qvcw4vdpcv1c4crazdj32-wayland-1.26.0/lib

CLIENT=/root/adw-hello                # default: the nix-pure GTK4/libadwaita app
CLIENT_LIBS="$NIXLIBS"
CLIENT_ENV="GDK_BACKEND=wayland GSK_RENDERER=cairo"
case "$1" in
  -c)    CLIENT="$2"; CLIENT_ENV="" ;;
  --shm) CLIENT=/root/wlclient; CLIENT_LIBS="$WLLIB"; CLIENT_ENV="" ;;
esac

echo "[solnix] cleaning up any previous session"
pkill -9 -f smallvil  2>/dev/null || true
pkill -9 -f x11vnc    2>/dev/null || true
pkill -9 -f adw-hello 2>/dev/null || true
pkill -9 -f wlclient  2>/dev/null || true
sleep 1

mkdir -p "$XDG"; chmod 700 "$XDG"; rm -f "$XDG"/wayland-*

echo "[solnix] starting Xvfb $DISP ($GEOM)"
if ! DISPLAY=$DISP /root/xgrab /tmp/.probe.ppm >/dev/null 2>&1; then
  "$XVFB" $DISP -screen 0 $GEOM -ac >/root/xvfb.log 2>&1 &
  sleep 3
fi

echo "[solnix] starting smallvil (nix-pure Wayland compositor, softpipe)"
# nice 19 + Timer-driven client dispatch (see the illumos-epoll note in the source);
# GL is dlopen'd from the OI Mesa softpipe.
( unset WAYLAND_DISPLAY
  export DISPLAY=$DISP XDG_RUNTIME_DIR=$XDG RUST_LOG=warn
  nohup nice -n 19 "$SMALLVIL" -c /bin/true >/root/smallvil.log 2>&1 & )
for i in 1 2 3 4 5 6 7 8 9 10; do
  sleep 1; [ -S "$XDG/wayland-1" ] && break
done
[ -S "$XDG/wayland-1" ] || { echo "[solnix] smallvil socket not created"; exit 1; }
echo "[solnix] wayland-1 socket up"

echo "[solnix] starting client: $CLIENT"
( export LD_LIBRARY_PATH="$CLIENT_LIBS" WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR=$XDG
  export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe
  # shellcheck disable=SC2086
  env $CLIENT_ENV nohup nice -n 19 "$CLIENT" >/root/client.log 2>&1 & )
sleep 4

echo "[solnix] starting x11vnc on 127.0.0.1:5900 (localhost only, SSH-tunnel it)"
"$X11VNC" -display $DISP -localhost -rfbport 5900 -nopw -forever -shared -bg \
  -o /root/x11vnc.log >/dev/null 2>&1
sleep 2

echo
echo "[solnix] session up:"
pgrep -fl smallvil  | head -1
pgrep -fl "$(basename "$CLIENT")" | head -1
netstat -an 2>/dev/null | grep '127.0.0.1.5900' | head -1
echo
echo "[solnix] connect from your machine:"
echo "    ssh -N -L 5900:127.0.0.1:5900 root@<this-host>"
echo "    <vnc-viewer> 127.0.0.1:5900"
echo
echo "[solnix] to stop:  pkill -9 -f smallvil; pkill -9 -f x11vnc; pkill -9 -f $(basename "$CLIENT")"
