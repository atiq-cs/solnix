#!/bin/sh
# solnix COSMIC session launcher (reconstructed from the verified live session).
# Xorg:99-dummy + smallvil (smithay SW compositor, softpipe) + cosmic-term + x11vnc(127.0.0.1:5900).
set -u
export XDG_RUNTIME_DIR=/tmp/xdg-runtime
export WAYLAND_DISPLAY=wayland-1
export DISPLAY=:99
export GALLIUM_DRIVER=softpipe
export LIBGL_ALWAYS_SOFTWARE=1
export LIBGL_DRIVERS_PATH=/usr/lib/xorg/modules/dri/amd64
export XKB_CONFIG_ROOT=/nix/store/qrlmmyrjgzff4nywbprq995lpfnfbb7l-xkeyboard-config-2.48/share/X11/xkb
export ICED_BACKEND=tiny-skia
export GDK_BACKEND=wayland
WLLIB=/nix/store/jp5g7biz7c2bsqz48awsd5qwa9asig73-wayland-1.26.0/lib
BIN=/nix/cosmic/cosmic-apps/waveB2-bin
mkdir -p "$XDG_RUNTIME_DIR"; chmod 700 "$XDG_RUNTIME_DIR"

# already running? bail.
pgrep -f "Xorg :99" >/dev/null 2>&1 && { echo "session already up"; exit 0; }

# 1. Xorg :99 dummy (advertises DRI2 for Mesa EGL-X11 swrast)
/usr/bin/Xorg :99 -config /root/xorg-dummy.conf -noreset -nolisten tcp &
sleep 3
# 2. smallvil compositor (creates wayland-1)
env LD_LIBRARY_PATH="$WLLIB:/usr/lib/64" "$BIN/smallvil" &
sleep 3
# 3. cosmic-term client (paints via tiny-skia + the softbuffer POSIX-shm patch)
env LD_LIBRARY_PATH="$BIN/lib:$WLLIB:/usr/lib/64" \
    /nix/cosmic/cosmic-apps/cosmic-term/target/x86_64-unknown-illumos/release/cosmic-term --no-daemon &
sleep 2
# 4. x11vnc exporting :99 on 127.0.0.1:5900 (localhost only)
env -u WAYLAND_DISPLAY /usr/bin/x11vnc -display :99 -localhost -rfbport 5900 -noipv6 -forever -shared -nopw -noxdamage &
echo "solnix COSMIC session started; VNC on 127.0.0.1:5900 (ssh -N -L 5900:127.0.0.1:5900 root@<ip>)"
