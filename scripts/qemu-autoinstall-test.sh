#!/usr/bin/env bash
# x1install-qemu.sh -- boot the built media under QEMU/OVMF with the media on USB
# (so it enumerates as a disk, exercising the boot-medium exclusion) and a SCRATCH
# AHCI target for the unattended install. Nothing real is attached: the target is
# a freshly-created sparse file per run and the media image is opened snapshot=on.
set -u
IMG="${1:?usage: x1install-qemu.sh <usb.img> <logfile> [secs]}"
LOG="${2:?}"
SECS="${3:-480}"
SCRATCH="${LOG%.txt}.scratch.img"

OVMF_CODE="$(ls /nix/store/*-OVMF-*/FV/OVMF_CODE.fd 2>/dev/null | head -1)"
OVMF_VARS_SRC="$(ls /nix/store/*-OVMF-*/FV/OVMF_VARS.fd 2>/dev/null | head -1)"
VARS="$(mktemp /tmp/ovmf-vars.XXXXXX.fd)"; cp "$OVMF_VARS_SRC" "$VARS"

rm -f "$SCRATCH"; truncate -s 12G "$SCRATCH"     # scratch target, per run
: > "$LOG"
cpu=max; accel=tcg; [ -w /dev/kvm ] && { cpu=host; accel=kvm; }

# snapshot=on on the media: writes are discarded, so the deliverable image on disk
# can never be modified by a run.
nohup timeout --kill-after=10 "$SECS" qemu-system-x86_64 -cpu "$cpu" -accel "$accel" \
  -m 6144 -smp 2 -machine q35 \
  -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
  -drive "if=pflash,format=raw,file=$VARS" \
  -drive file="$IMG",format=raw,if=none,id=d0,snapshot=on \
  -device qemu-xhci,id=xhci -device usb-storage,bus=xhci.0,drive=d0 \
  -drive file="$SCRATCH",format=raw,if=none,id=t0 \
  -device ahci,id=ahci1 -device ide-hd,drive=t0,bus=ahci1.0 \
  -boot c -display none -serial "file:$LOG" >/dev/null 2>&1 &
qpid=$!
( sleep $((SECS + 15)); kill -KILL "$qpid" 2>/dev/null ) & wpid=$!
wait "$qpid" 2>/dev/null || true
kill "$wpid" 2>/dev/null || true
rm -f "$VARS"
echo "[qemu] $LOG: $(wc -c < "$LOG") bytes; scratch $SCRATCH kept for the boot-alone test" >&2
