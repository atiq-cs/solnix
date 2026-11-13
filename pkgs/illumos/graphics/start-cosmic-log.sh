# solnix: keep the session's output. greetd hands the session its VT and there is no journald, so cosmic-session, the
# compositor and every applet wrote into nothing, and a frozen session left no evidence (lixi, 2026-11-13). Each login
# appends to its own $XDG_STATE_HOME/cosmic-session/session-<time>.log; the newest 5 are kept.
d="${XDG_STATE_HOME:-$HOME/.local/state}/cosmic-session"
if mkdir -p "$d" 2>/dev/null && [ -w "$d" ]; then
    ls -1t "$d"/session-*.log 2>/dev/null | tail -n +5 | while read -r f; do rm -f "$f"; done
    exec >> "$d/session-$(date +%Y%m%dT%H%M%S).log" 2>&1
    echo "start-cosmic: $(date -u +%Y-%m-%dT%H:%M:%SZ) pid $$ user $(id -un) display ${WAYLAND_DISPLAY:-unset}"
fi
export RUST_BACKTRACE="${RUST_BACKTRACE:-1}"   # a panic prints where it happened
