#!/usr/bin/env bash
# usb-rate.sh <img> <outdir> <n> -- boot IMG on the USB bus N times and count the
# two faults per run. Sequential, each run timeout-bounded by qemu-boottest.sh.
#
# WHY the USB bus specifically: the ZFS + /dev/sad faults appeared in 2/2 USB
# boots and 0/16 virtio/ahci/cdrom boots of the same image, and the X1 boots from
# USB. WHY >=8 runs: faults in this project are BURSTY, so a 4-run sample inside
# or outside a burst reports 25% or 100%, both honestly.
#
# THE FAULT IS A RACE, so THE RATE IS NOT A PROPERTY OF THE IMAGE ALONE: it also
# depends on how fast this host enumerates the emulated USB stack, i.e. on host
# load. Runs are therefore NOT independent, and a rate measured while other work
# (a parallel qemu, a build) runs is not comparable to an idle one. The load is
# recorded per run so an A/B compares like with like instead of comparing a busy
# BEFORE against an idle AFTER and calling the difference a fix.
set -u
IMG="${1:?img}"; OUT="${2:?outdir}"; N="${3:-8}"; SECS="${4:-200}"
mkdir -p "$OUT"
for i in $(seq 1 "$N"); do
  L="$OUT/usb-$i.log"
  bash "$(dirname "$0")/qemu-boottest.sh" disk "$IMG" "$L" "$SECS" uefi usb >/dev/null 2>&1
  sed -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\r//g' "$L" > "$L.clean"
  # `grep -c` prints 0 AND exits 1 when there are no matches, so the
  # `|| echo 0` appended a SECOND line and the output became unparseable.
  # Use a form that always exits 0 and emits exactly one number.
  z=$(grep -c "initialize ZFS" "$L.clean" || true); z=${z:-0}
  s=$(grep -c "sad/user failed" "$L.clean" || true); s=${s:-0}
  g=$(grep -c "console login:" "$L.clean" || true); g=${g:-0}
  # load average at sample time: the fault is a race, so this is evidence, not decoration
  _la=$(uptime 2>/dev/null | sed -n 's/.*load average: *\([0-9.]*\).*/\1/p')
  echo "usb-$i login=$g zfs_err=$z sad_err=$s load=${_la:-?}"
done
