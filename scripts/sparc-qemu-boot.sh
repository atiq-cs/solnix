#!/usr/bin/env bash
# sparc-qemu-boot.sh — attempt to boot the Tribblix SPARC m34 ISO in
# qemu-system-sparc64 -machine sun4u (OpenBIOS -> illumos sparc boot). Runs
# headless, serial to a log, time-boxed. Success = the sun4u illumos kernel
# starts / reaches any illumos milestone (banner, VFS, login).
set -u
ISO="$HOME/ws/solnix-archive/sparc/tribblix-sparc-0m34.iso"
LOG="$HOME/ws/solnix/artifacts/sparc/qemu-sun4u-boot.log"
MON="/tmp/sparc-qemu-mon.sock"
BOOTSEC="${1:-360}"   # time-box seconds

[ -f "$ISO" ] || { echo "FATAL: ISO missing $ISO"; exit 2; }
mkdir -p "$(dirname "$LOG")"
: > "$LOG"

echo "=== qemu-system-sparc64 sun4u boot of $(basename "$ISO") (timebox ${BOOTSEC}s) ===" | tee -a "$LOG"
qemu-system-sparc64 --version | head -1 | tee -a "$LOG"

# OpenBIOS on sun4u boots a Sun sparc CD from device 'cdrom'. Serial console to
# stdio (captured). No graphics. IDE CD (qemu sun4u default south bridge is
# CMD646 IDE). Feed OBP the boot command over the console so the FCode CD path
# runs 'boot cdrom' (some builds sit at the ok prompt otherwise).
printf 'boot cdrom\n' > /tmp/sparc-obp-cmd.txt
timeout "${BOOTSEC}" qemu-system-sparc64 \
  -machine sun4u \
  -cpu "TI-UltraSparc-IIi" \
  -m 2048 \
  -nographic \
  -drive file="$ISO",format=raw,if=ide,media=cdrom,index=2 \
  -boot d \
  -nodefaults \
  -serial mon:stdio \
  < /tmp/sparc-obp-cmd.txt \
  > "$LOG" 2>&1 &
QPID=$!
echo "qemu pid $QPID" | tee -a "$LOG"
wait "$QPID" 2>/dev/null
rc=$?
echo "=== qemu exited rc=$rc (124=timeout=still-running-at-box) ===" | tee -a "$LOG"
echo "--- last 40 log lines ---"
tail -40 "$LOG"
