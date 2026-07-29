#!/usr/bin/env bash
# qemu-boottest.sh — boot a solnix ISO or disk image under qemu, TIMEOUT-WRAPPED
# and DETACHED, capture the serial console to a log, then kill qemu. NEVER waits
# in the foreground (a prior agent wedged 16h on a hung qemu).
#
#   qemu-boottest.sh iso  <iso>   <logfile> [seconds] [bios|uefi]
#   qemu-boottest.sh disk <img>   <logfile> [seconds] [bios|uefi]
#   qemu-boottest.sh install <iso> <scratch.img> <logfile> [seconds] [bios|uefi]
#       boot the ISO with a blank scratch disk attached (for solnix-install)
#
# Pattern: nohup qemu ... -serial file:LOG >/dev/null 2>&1 &  ; sleep N ; kill.
# The caller greps LOG for the banner / installer prompt afterward.
set -u

MODE="${1:?usage: qemu-boottest.sh iso|disk|install ...}"
QEMU=qemu-system-x86_64
# OVMF UEFI firmware (read-only CODE + a writable VARS copy per run)
OVMF_CODE="$(ls /nix/store/*-OVMF-*/FV/OVMF_CODE.fd 2>/dev/null | head -1)"
OVMF_VARS_SRC="$(ls /nix/store/*-OVMF-*/FV/OVMF_VARS.fd 2>/dev/null | head -1)"

run_qemu() {  # run_qemu <logfile> <seconds> <qemu-args...>
  local log="$1" secs="$2"; shift 2
  : > "$log"
  echo "[qemu] launching detached, timeout ${secs}s, log=$log" >&2
  # -cpu host if KVM is available (exposes SEP + all hwcaps illumos libc needs;
  # the default qemu64 CPU lacks SEP -> "CA_SUNW_HW_1 unsupported" in ld.so.1),
  # else -cpu max (TCG, still exposes the needed caps). Prefer KVM for speed.
  local cpu=max accel=tcg
  if [ -w /dev/kvm ]; then cpu=host accel=kvm; fi
  # hard outer timeout(1) AND an inner background kill — belt and braces so a
  # hung qemu can NEVER hold this shell. -display none, serial->file.
  nohup timeout --kill-after=10 "$secs" "$QEMU" -cpu "$cpu" -accel "$accel" "$@" \
        -display none -serial "file:$log" >/dev/null 2>&1 &
  local qpid=$!
  echo "[qemu] pid=$qpid" >&2
  # watchdog: after secs+15, SIGKILL anything still alive (defense in depth).
  ( sleep $((secs + 15)); kill -KILL "$qpid" 2>/dev/null
    pkill -KILL -f "$QEMU.*$(basename "$log")" 2>/dev/null ) &
  local wpid=$!
  # foreground-wait ONLY on the timeout-bounded pid (bounded by construction).
  wait "$qpid" 2>/dev/null || true
  kill "$wpid" 2>/dev/null || true
  # sweep any stray qemu bound to this log (safety).
  pkill -KILL -f "$QEMU.*$(basename "$log")" 2>/dev/null || true
  echo "[qemu] done; ${secs}s elapsed (or earlier exit). log bytes: $(wc -c < "$log" 2>/dev/null || echo 0)" >&2
}

# build the OVMF pflash args into a global array FWA (empty for bios). Done
# inline (not via mapfile+subshell, which mangled the multi-token -drive args).
set_firmware_args() {  # $1 = bios|uefi
  FWA=()
  [ "$1" = uefi ] || return 0
  local vars; vars="$(mktemp /tmp/ovmf-vars.XXXXXX.fd)"
  cp "$OVMF_VARS_SRC" "$vars"
  FWA=(
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,file=$vars"
  )
}

case "$MODE" in
  iso)
    ISO="${2:?}"; LOG="${3:?}"; SECS="${4:-180}"; FW="${5:-bios}"
    set_firmware_args "$FW"
    run_qemu "$LOG" "$SECS" \
      -m 6144 -smp 2 -machine q35 \
      "${FWA[@]}" \
      -cdrom "$ISO" -boot d
    ;;
  disk)
    IMG="${2:?}"; LOG="${3:?}"; SECS="${4:-180}"; FW="${5:-bios}"
    set_firmware_args "$FW"
    run_qemu "$LOG" "$SECS" \
      -m 6144 -smp 2 -machine q35 \
      "${FWA[@]}" \
      -drive file="$IMG",format=raw,if=none,id=d0 \
      -device nvme,drive=d0,serial=solnix0 \
      -boot c
    ;;
  install)
    ISO="${2:?}"; SCRATCH="${3:?}"; LOG="${4:?}"; SECS="${5:-300}"; FW="${6:-bios}"
    set_firmware_args "$FW"
    # scratch target on AHCI/SATA (NOT nvme — illumos nvme driver panics on
    # qemu's NVMe emulation). The ISO cdrom is on the machine's built-in AHCI.
    run_qemu "$LOG" "$SECS" \
      -m 6144 -smp 2 -machine q35 \
      "${FWA[@]}" \
      -cdrom "$ISO" -boot d \
      -drive file="$SCRATCH",format=raw,if=none,id=t0 \
      -device ahci,id=ahci1 \
      -device ide-hd,drive=t0,bus=ahci1.0
    ;;
  *) echo "usage: qemu-boottest.sh iso|disk|install ..." >&2; exit 1 ;;
esac
