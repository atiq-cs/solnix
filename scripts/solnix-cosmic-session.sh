#!/bin/sh
# solnix-cosmic-session.sh -- one command: Xorg(dummy)+swrast DRI2 -> smallvil
# (smithay SW Wayland compositor, softpipe GLES2) -> a Wayland client ->
# x0vncserver + a localhost relay exporting the framebuffer on 127.0.0.1:5900.
#
#   solnix-cosmic-session.sh              # smallvil + the wl_shm test client
#   solnix-cosmic-session.sh -c PROG      # run PROG as the Wayland client
#   solnix-cosmic-session.sh --cosmic-term  # try cosmic-term (connects; SW-shm gated)
#
# stop:  pkill -9 -f smallvil; pkill -9 x0vncserver; pkill -9 lo-relay; pkill -9 Xorg
set -u

DISP=:99
BIN=/root/cosmic-gcroots/waveB2-bin
WLLIB=/nix/store/jp5g7biz7c2bsqz48awsd5qwa9asig73-wayland-1.26.0/lib
XKB=/nix/store/qrlmmyrjgzff4nywbprq995lpfnfbb7l-xkeyboard-config-2.48/share/X11/xkb
export XDG_RUNTIME_DIR=/tmp/xdg-runtime
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"

# --- clean slate ---
pkill -9 -f smallvil 2>/dev/null; pkill -9 x0vncserver 2>/dev/null
pkill -9 lo-relay 2>/dev/null;   pkill -9 wlclient 2>/dev/null
pkill -9 Xorg 2>/dev/null;       sleep 2
rm -f "$XDG_RUNTIME_DIR"/wayland-1*

# --- the mediated-GL server libglx link is populated at boot by ogl-select;
#     re-run it so Xorg loads GLX/DRISWRAST (fresh AMIs miss the amd64 link). ---
svcadm restart application/opengl/ogl-select 2>/dev/null; sleep 2

# --- 1. DISPLAY substrate: Xorg :99, dummy driver = a headless framebuffer that
#        (unlike Xvfb/Xvnc) advertises DRI2 so Mesa's swrast EGL-X11 works. ---
/usr/bin/Xorg $DISP -config /root/xorg-dummy.conf -noreset -nolisten tcp \
  > /root/xorg.log 2>&1 &
sleep 5

# --- 2. smallvil: the smithay SW Wayland compositor. winit-x11 opens a window in
#        Xorg :99; EGL PLATFORM_X11_KHR -> softpipe GLES2 (SW). GALLIUM=softpipe
#        (NOT llvmpipe: llvmpipe fails the DRI2 swrast screen on this Mesa). ---
(
  export DISPLAY=$DISP
  unset WAYLAND_DISPLAY               # so winit uses X11, not a nested wayland
  export XKB_CONFIG_ROOT="$XKB"
  export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=softpipe
  export LIBGL_DRIVERS_PATH=/usr/lib/xorg/modules/dri/amd64
  export LD_LIBRARY_PATH="$WLLIB:/usr/lib/64"
  exec "$BIN/smallvil"
) > /root/smallvil.log 2>&1 &
sleep 10

# --- 3. a Wayland client inside smallvil ---
CLIENT="$BIN/../.. "   # placeholder
case "${1:-}" in
  -c)            CLIENT="$2" ;;
  --cosmic-term) CLIENT="$BIN/cosmic-term" ;;
  --cosmic-files)CLIENT="$BIN/cosmic-files" ;;
  *)             CLIENT="/root/wlclient" ;;   # raw wl_shm proof (illumos-safe tmpfile shm)
esac
(
  export WAYLAND_DISPLAY=wayland-1 GDK_BACKEND=wayland
  export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=softpipe
  export LIBGL_DRIVERS_PATH=/usr/lib/xorg/modules/dri/amd64
  unset DISPLAY
  if [ "$CLIENT" = "/root/wlclient" ]; then
    export LD_LIBRARY_PATH="$WLLIB:/usr/lib/64"
  else
    export LD_LIBRARY_PATH="$BIN/lib:$WLLIB:/usr/lib/64"
  fi
  exec "$CLIENT"
) > /root/cosmic-client.log 2>&1 &
sleep 4

# --- 4. VNC export, localhost-only. x0vncserver (TigerVNC 1.8) can only listen
#        on all interfaces, so it runs on :5901 and lo-relay binds 127.0.0.1:5900
#        and forwards -> the only externally-tunneled listener is localhost. ---
/usr/bin/x0vncserver -display $DISP -rfbport 5901 -SecurityTypes None \
  > /root/x0vnc.log 2>&1 &
sleep 3
/root/lo-relay 5900 5901 > /root/lo-relay.log 2>&1 &
sleep 2

echo "=== solnix COSMIC/Wayland session ==="
echo "Xorg :99      pid $(pgrep -f 'Xorg :99' | head -1)"
echo "smallvil      pid $(pgrep -f smallvil | head -1)  (softpipe SW GLES2 compositor)"
echo "client        pid $(pgrep -f "$(basename "$CLIENT")" | head -1)  ($CLIENT)"
echo "x0vncserver   pid $(pgrep -f x0vncserver | head -1)  (mirrors :99 on 5901)"
echo "lo-relay      pid $(pgrep -f lo-relay | head -1)"
echo
netstat -an 2>/dev/null | grep '127.0.0.1.5900' | head -1
echo "VNC: 127.0.0.1:5900 (localhost only). Tunnel: ssh -N -L 5900:127.0.0.1:5900 root@<host>"
