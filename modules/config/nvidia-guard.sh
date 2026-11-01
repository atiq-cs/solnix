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
set -u
PATH=/usr/sbin:/usr/bin:/sbin
: "${SENSOR:=gput_C}" "${INTERVAL:=3}" "${DRYRUN:=0}" "${SAMPLES:=0}" "${OKFILE:=/var/run/solnix-nvidia-guard.ok}"
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) solnix-nvidia-guard: $*" | tee -a "$LOG"; }
bail() {
  if [ "$DRYRUN" = 1 ]; then log "would reboot: $*"; exit 0; fi
  log "REBOOTING: $*"
  dmesg 2>/dev/null | grep -i -E 'NVRM|nvidia|tzmon' | tail -40 >> "$LOG"
  sync; reboot
  exit 1
}
read_t() { kstat -p "dgputemp:0:ec:$SENSOR" 2>/dev/null | awk '{print $2}'; }
[ -n "$(kstat -p dgputemp:0:ec:reads 2>/dev/null)" ] || modload -p misc/dgputemp >/dev/null 2>&1
log "start: sensor dgputemp:0:ec:$SENSOR, limit ${MAXT} C, every ${INTERVAL} s$( [ "$DRYRUN" = 1 ] && echo ', DRY RUN')"
n=0
while :; do
  t=$(read_t); n=$((n + 1))
  case $t in
    ''|*[!0-9]*) bail "dgputemp:0:ec:$SENSOR unreadable ('$t')";;
  esac
  [ "$t" -ge "$MAXT" ] && bail "dGPU at ${t} C >= ${MAXT} C (dgputemp:0:ec:$SENSOR)"
  [ "$DRYRUN" = 1 ] || touch "$OKFILE"
  [ $((n % 20)) -eq 1 ] && log "sample $n: ${t} C"
  [ "$SAMPLES" -gt 0 ] && [ "$n" -ge "$SAMPLES" ] && { log "quiet after $n samples (last ${t} C)"; exit 0; }
  sleep "$INTERVAL"
done
