#!/bin/sh
# solnix COSMIC SHELL session: Xorg :99 -> smallvil (smithay SW compositor,
# softpipe GLES2, now advertising wlr-layer-shell + fractional-scale +
# security-context + viewporter) -> D-Bus session bus -> cosmic-notifications
# -> cosmic-panel (the shell bar, a wlr-layer-shell client) -> cosmic-term
# (an xdg-shell app window) -> x11vnc on 127.0.0.1:5900. All wayland clients
# pump their queue via the illumos calloop-wayland-source Timer dispatch fix;
# cosmic-panel additionally relies on the wayland-client blocking_read
# finite-timeout fix for its synchronous startup roundtrip.
set -u
DISP=:99
BIN=/nix/cosmic/cosmic-apps/waveB2-bin
APPS=/nix/cosmic/cosmic-apps
WLLIB=/nix/store/jp5g7biz7c2bsqz48awsd5qwa9asig73-wayland-1.26.0/lib
MESAWL=/nix/mesabuild/mesa-wl/lib   # Mesa 25.1.4 libEGL WITH the wayland EGL platform (softpipe)
GCCLIB=/usr/gcc/14/lib/amd64
DRMLIB=/usr/lib/xorg/amd64        # system libdrm.so.2 lives here (not on the default runpath)
XKB=/nix/store/qrlmmyrjgzff4nywbprq995lpfnfbb7l-xkeyboard-config-2.48/share/X11/xkb
PANEL=$APPS/cosmic-panel/target/x86_64-unknown-illumos/release/cosmic-panel
TERM_BIN=$APPS/cosmic-term/target/x86_64-unknown-illumos/release/cosmic-term
NOTIF=$APPS/cosmic-notifications/target/x86_64-unknown-illumos/release/cosmic-notifications
export XDG_RUNTIME_DIR=/tmp/xdg-runtime
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"

# clean slate
pkill -9 -f smallvil 2>/dev/null; pkill -9 x11vnc 2>/dev/null
pkill -9 -f cosmic-panel 2>/dev/null; pkill -9 -f cosmic-term 2>/dev/null
pkill -9 -f cosmic-notifications 2>/dev/null
pkill -9 -f 'dbus-daemon --session' 2>/dev/null
pkill -9 Xorg 2>/dev/null; sleep 2
rm -f "$XDG_RUNTIME_DIR"/wayland-1* "$XDG_RUNTIME_DIR"/bus

# GLX/DRISWRAST amd64 link (fresh AMIs miss it)
svcadm restart application/opengl/ogl-select 2>/dev/null; sleep 2

# 1. Xorg :99 dummy (DRI2 for Mesa swrast)
/usr/bin/Xorg $DISP -config /root/xorg-dummy.conf -noreset -nolisten tcp > /root/xorg.log 2>&1 &
sleep 5

# 2. smallvil: winit-X11 window in :99; EGL PLATFORM_X11_KHR -> softpipe GLES2.
#    MUST unset WAYLAND_DISPLAY so winit uses X11 (not a nested wayland client,
#    which wedges in an infinite-timeout roundtrip on illumos).
(
  export DISPLAY=$DISP
  unset WAYLAND_DISPLAY
  export XKB_CONFIG_ROOT="$XKB"
  export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=softpipe
  export LIBGL_DRIVERS_PATH=/usr/lib/xorg/modules/dri/amd64
  export LD_LIBRARY_PATH="$WLLIB:/usr/lib/64"
  export RUST_LOG=info
  exec "$BIN/smallvil"
) > /root/smallvil.log 2>&1 &
# wait for the wayland-1 socket
i=0
while [ ! -S "$XDG_RUNTIME_DIR/wayland-1" ] && [ $i -lt 100 ]; do sleep 0.2; i=$((i+1)); done
sleep 3

# 2b. D-Bus session bus (workspaces-proxy + notifications connection paths)
/usr/bin/dbus-daemon --session --nofork --address="$DBUS_SESSION_BUS_ADDRESS" > /root/dbus.log 2>&1 &
i=0
while [ ! -S "$XDG_RUNTIME_DIR/bus" ] && [ $i -lt 50 ]; do sleep 0.2; i=$((i+1)); done

# 2c. cosmic-notifications daemon
if [ -x "$NOTIF" ]; then
  (
    export WAYLAND_DISPLAY=wayland-1 GDK_BACKEND=wayland
    export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=softpipe
    export EGL_PLATFORM=wayland
    export LIBGL_DRIVERS_PATH=/usr/lib/xorg/modules/dri/amd64
    unset DISPLAY
    export LD_LIBRARY_PATH="$MESAWL:$GCCLIB:$DRMLIB:$BIN/lib:$WLLIB:/usr/lib/64"
    export ICED_BACKEND=tiny-skia XKB_CONFIG_ROOT="$XKB"
    export RUST_LOG=info
    exec "$NOTIF"
  ) > /root/notifications.log 2>&1 &
  sleep 3
fi

# 3. cosmic-panel (the shell bar; wlr-layer-shell client). Its xdg_shell_wrapper
#    renders each layer via a REAL GLES2 context bound to the wayland display, so
#    it MUST use the wayland-EGL Mesa (MESAWL) ahead of the system /usr/lib/64.
#    XDG_DATA_DIRS + PATH expose the applet .desktop files + their Exec binaries
#    so the panel spawns applets (its bar content).
(
  export WAYLAND_DISPLAY=wayland-1 GDK_BACKEND=wayland
  export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=softpipe
  export EGL_PLATFORM=wayland
  export LIBGL_DRIVERS_PATH=/usr/lib/xorg/modules/dri/amd64
  unset DISPLAY
  export LD_LIBRARY_PATH="$MESAWL:$GCCLIB:$DRMLIB:$BIN/lib:$WLLIB:/usr/lib/64"
  export XDG_DATA_DIRS="/root/.local/share:/usr/share"
  export PATH="/nix/cosmic/applet-bin:$PATH"
  export ICED_BACKEND=tiny-skia XKB_CONFIG_ROOT="$XKB"
  export RUST_LOG=info
  exec "$PANEL"
) > /root/panel.log 2>&1 &
sleep 5

# 4. cosmic-term (xdg-shell app window, tiny-skia SW path -- proven painter)
(
  export WAYLAND_DISPLAY=wayland-1 GDK_BACKEND=wayland
  export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=softpipe
  export LIBGL_DRIVERS_PATH=/usr/lib/xorg/modules/dri/amd64
  unset DISPLAY
  export LD_LIBRARY_PATH="$BIN/lib:$WLLIB:/usr/lib/64"
  export ICED_BACKEND=tiny-skia XKB_CONFIG_ROOT="$XKB"
  exec "$TERM_BIN" --no-daemon
) > /root/cosmic-term.log 2>&1 &
sleep 6

# 4b. cosmic-files (second xdg-shell app window -- verified multi-app painter)
FILES_BIN=$APPS/cosmic-files/target/x86_64-unknown-illumos/release/cosmic-files
if [ -x "$FILES_BIN" ]; then
(
  export WAYLAND_DISPLAY=wayland-1 GDK_BACKEND=wayland
  export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=softpipe
  export LIBGL_DRIVERS_PATH=/usr/lib/xorg/modules/dri/amd64
  unset DISPLAY
  export LD_LIBRARY_PATH="$BIN/lib:$WLLIB:/usr/lib/64"
  export ICED_BACKEND=tiny-skia XKB_CONFIG_ROOT="$XKB"
  exec "$FILES_BIN"
) > /root/cosmic-files.log 2>&1 &
sleep 6
fi

# 5. VNC export, localhost-only (WAYLAND_DISPLAY unset: x11vnc is an X11 tool)
( unset WAYLAND_DISPLAY; exec /usr/bin/x11vnc -display $DISP -localhost -rfbport 5900 -noipv6 \
  -forever -shared -nopw -noxdamage -noshm > /root/x11vnc.log 2>&1 </dev/null ) &
sleep 4
echo "=== solnix COSMIC SHELL session ==="
echo "Xorg $(pgrep -f 'Xorg :99'|head -1)  smallvil $(pgrep -f smallvil|head -1)  dbus $(pgrep -f 'dbus-daemon --session'|head -1)"
echo "notif $(pgrep -f cosmic-notifications|head -1)  panel $(pgrep -f cosmic-panel|head -1)  term $(pgrep -f cosmic-term|head -1)  files $(pgrep -f cosmic-files|head -1)  x11vnc $(pgrep -f x11vnc|head -1)"
netstat -an 2>/dev/null | grep '127.0.0.1.5900' | head -1
