#!/bin/sh
# solnix-nvidia-guard: the dGPU thermal guard for a BE where nvidia drives the GPU
# (hardware.graphics.nvidia.attachAtBoot, modules/config/wireless-iwx.nix).
#
# In that BE tzmon skips its boot-time dGPU power-off (solnix-dgpu-off=0), so the GPU
# sits in D0 from the start of boot. Unmanaged it went 53 -> 94 C in ten minutes and
# the EC cut power (scripts/patches/0005). This samples the EC's own dGPU sensor
# (GPUT, via the dgputemp module's kstat; it needs no nvidia driver) every INTERVAL
# seconds and reboots at MAXT C or above, or when the sensor cannot be read: an
# unreadable sensor counts as too hot. The BE is boot-once, so the reboot lands in
# one where tzmon powers the GPU off again.
# env: MAXT (C), INTERVAL (s), LOG; SENSOR (kstat statistic, default gput_C);
#      DRYRUN=1 logs "would reboot" instead of rebooting and exits (the test mode);
#      SAMPLES=n stops after n samples (0 = run until stopped); OKFILE is touched after every good
#      sample (tmpfs, so gone at boot): site/solnix-nvidia waits for it before it powers RM up.
# A GPU that is powered OFF (runtime D3cold, hardware.graphics.nvidia.rtd3) makes no heat and has no
# reading (GPUT 0x80). That is accepted only when the hardware says off: the root port's power resource
# (pr3_sta) AND the GPU's power GPIO/reset (psta, PEG1.PSTA) both 0. After an off -> on edge the EC needs
# a moment for a first reading (RM init takes seconds): up to GRACE samples (default 10 = 30 s) may be
# unreadable while powered. The GPU was off, so it starts cool, and unmanaged it heated about 4 C a minute
# (53 -> 94 C in ten). Anything else that cannot be read still counts as too hot.
set -u
PATH=/usr/sbin:/usr/bin:/sbin
: "${SENSOR:=gput_C}" "${INTERVAL:=3}" "${DRYRUN:=0}" "${SAMPLES:=0}" "${OKFILE:=/var/run/solnix-nvidia-guard.ok}" "${GRACE:=10}"
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) solnix-nvidia-guard: $*" | tee -a "$LOG"; }
bail() {
  if [ "$DRYRUN" = 1 ]; then log "would reboot: $*"; exit 0; fi
  log "REBOOTING: $*"
  dmesg 2>/dev/null | grep -i -E 'NVRM|nvidia|tzmon' | tail -40 >> "$LOG"
  sync; reboot
  exit 1
}
read_k() { kstat -p "dgputemp:0:ec:$1" 2>/dev/null | awk '{print $2}'; }
[ -n "$(kstat -p dgputemp:0:ec:reads 2>/dev/null)" ] || modload -p misc/dgputemp >/dev/null 2>&1
log "start: sensor dgputemp:0:ec:$SENSOR, limit ${MAXT} C, every ${INTERVAL} s$( [ "$DRYRUN" = 1 ] && echo ', DRY RUN')"
n=0 off=0 grace=0
while :; do
  t=$(read_k "$SENSOR"); n=$((n + 1))
  case $t in
    ''|*[!0-9]*)
      p=$(read_k psta); s=$(read_k pr3_sta)
      if [ "$p" = 0 ] && [ "$s" = 0 ]; then
        [ "$off" = 1 ] || log "sample $n: dGPU powered off (psta 0, pr3_sta 0); no reading needed"
        off=1 grace=$GRACE
      elif [ "$grace" -gt 0 ]; then
        [ "$off" = 1 ] && log "sample $n: dGPU powered on (psta '$p', pr3_sta '$s'), waiting for a reading"
        off=0 grace=$((grace - 1))
      else
        bail "dgputemp:0:ec:$SENSOR unreadable ('$t') with the dGPU powered (psta '$p', pr3_sta '$s')"
      fi
      [ "$DRYRUN" = 1 ] || touch "$OKFILE"
      [ "$SAMPLES" -gt 0 ] && [ "$n" -ge "$SAMPLES" ] && { log "quiet after $n samples (dGPU off)"; exit 0; }
      sleep "$INTERVAL"; continue;;
  esac
  [ "$t" -ge "$MAXT" ] && bail "dGPU at ${t} C >= ${MAXT} C (dgputemp:0:ec:$SENSOR)"
  [ "$off" = 1 ] && log "sample $n: dGPU powered on: ${t} C"
  off=0 grace=0
  [ "$DRYRUN" = 1 ] || touch "$OKFILE"
  [ $((n % 20)) -eq 1 ] && log "sample $n: ${t} C"
  [ "$SAMPLES" -gt 0 ] && [ "$n" -ge "$SAMPLES" ] && { log "quiet after $n samples (last ${t} C)"; exit 0; }
  sleep "$INTERVAL"
done
