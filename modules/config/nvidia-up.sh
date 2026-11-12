#!/bin/sh
# solnix-nvidia: bring the dGPU up once the dump device is armed (hardware.graphics.nvidia.attachAtBoot).
# Runs after site/solnix-nvidia-guard (the thermal guard, which covers the whole time the GPU is powered)
# and system/dumpadm, so a panic in the first RmInitAdapter leaves a dump.
#
# nvidia is bound at boot with NVreg_GpuInitOnProbe=0: its PCI attach maps the BARs and makes /dev/nvidia0
# without touching the GSP. The probe's first open of /dev/nvidia0 runs RmInitAdapter and boots the GSP,
# and the probe keeps it open (RM shuts the GPU down at the last close). A failure is logged with the
# kernel's messages and left to the guard: no reboot here, so the failed state can be read over ssh.
# RTD3=1 (hardware.graphics.nvidia.rtd3): tzmon powered the GPU off at boot; the open of nvidia@0:nvidia-poweron
# attaches nvidia to it (the cold attach). The probe then opens the GPU once (RmInitAdapter, GSP) and closes it, so
# the nvidia module powers it off right after RM shuts down (runtime D3cold); this then logs the power state every 60 s.
# MODESET=1 (hardware.graphics.nvidia.modeset): after the probe, configure nvidia_modeset (it refuses to load before
# RM is up): /dev/nvidia-modeset. DRM=1 (hardware.graphics.nvidia.drm) also starts nvidia-drm by opening its ctl
# node: /dev/dri/card1 and renderD129. nvidia-drm holds no GPU while no client has card1/renderD129 open, so RTD3
# still powers the GPU off.
# env: PROBE (nvidia-probe), LOG, OKFILE (the guard's per-sample file), RTD3, MODESET, DRM.
set -u
PATH=/usr/sbin:/usr/bin:/sbin
: "${OKFILE:=/var/run/solnix-nvidia-guard.ok}"
log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) solnix-nvidia: $*" | tee -a "$LOG"; }
kheap() { kstat -p unix:0:system_pages:pp_kernel 2>/dev/null | awk '{printf "%d MB", $2 * 4 / 1024}'; }
fail() { log "FAILED: $*"; dmesg 2>/dev/null | grep -i -E 'NVRM|nvidia' | tail -60 >> "$LOG"; exit 0; }
log "start: $(uname -v); dump device: $(dumpadm 2>/dev/null | sed -n 's/.*Dump device: //p'); kernel heap: $(kheap)"
# the guard must be sampling right now: its file has to come back within 10 s of being removed
rm -f "$OKFILE"; sleep 10
[ -e "$OKFILE" ] || fail "the thermal guard is not sampling ($OKFILE not renewed in 10 s); not starting RM"
devfsadm -i nvidia >> "$LOG" 2>&1 || log "devfsadm -i nvidia rc=$?"
if [ "${RTD3:-0}" = 1 ]; then
  # tzmon powered the GPU off at boot and offlined it: the cold attach (nvidia-oss patches/0003) powers it on,
  # restores and verifies its BARs, and attaches nvidia; it refuses (GPU off again) on any mismatch
  c=/devices/pseudo/nvidia@0:nvidia-poweron
  if ( exec 3< "$c" ) 2>> "$LOG"; then
    log "cold attach: ok (GPUT $(kstat -p dgputemp:0:ec:gput_C 2>/dev/null | awk '{print $2}'), psta $(kstat -p dgputemp:0:ec:psta 2>/dev/null | awk '{print $2}'))"
  else
    fail "cold attach (open $c) failed: $(dmesg 2>/dev/null | grep 'cold attach' | tail -3 | tr '\n' ' ')"
  fi
  devfsadm -i nvidia >> "$LOG" 2>&1 || log "devfsadm -i nvidia rc=$?"
fi
[ -c /dev/nvidiactl ] || fail "no /dev/nvidiactl (nvidia did not attach)"
[ -c /dev/nvidia0 ] || fail "no /dev/nvidia0 (the GPU did not attach)"
drm_up() {
  [ "${MODESET:-0}" = 1 ] || return 0
  devfsadm -i nvidia_modeset >> "$LOG" 2>&1 || log "devfsadm -i nvidia_modeset rc=$?"
  [ -c /dev/nvidia-modeset ] || { log "nvidia_modeset: no /dev/nvidia-modeset (it did not attach)"; return 0; }
  log "nvidia_modeset: /dev/nvidia-modeset"
  [ "${DRM:-0}" = 1 ] || return 0
  devfsadm -i nvidia_drm >> "$LOG" 2>&1 || log "devfsadm -i nvidia_drm rc=$?"
  c=/devices/pseudo/nvidia_drm@0:ctl
  [ -c "$c" ] || { log "nvidia-drm: no $c (nvidia_drm did not attach)"; return 0; }
  # the open is the start (NVKMS enumerates the GPUs); the subshell's fd closes as it exits
  if ( exec 3< "$c" ) 2>> "$LOG"; then
    devfsadm -i nvidia_drm >> "$LOG" 2>&1 || true   # links for the card/renderD minors the start made
    log "nvidia-drm started: /dev/dri: $(ls /dev/dri 2>/dev/null | tr '\n' ' ')"
  else
    log "nvidia-drm: start (open $c) failed"
    dmesg 2>/dev/null | grep -i -E 'nvidia-drm|nvidia_drm|nvidia-modeset' | tail -20 >> "$LOG"
  fi
}
if [ "${RTD3:-0}" = 1 ]; then
  "$PROBE" >> "$LOG" 2>&1 || fail "nvidia-probe failed (RmInitAdapter/GSP? see the probe lines above)"
  drm_up
  log "probed and released; runtime D3cold: off once RM has shut down"
  i=0
  while :; do
    sleep 60; i=$((i + 60))
    log "up ${i}s: rtd3 $(kstat -p nvidia:0:rtd3 2>/dev/null | awk '{sub(/.*:/, "", $1); printf "%s=%s ", $1, $2}')EC GPUT $(kstat -p dgputemp:0:ec:gput_C 2>/dev/null | awk '{print $2}') C, psta $(kstat -p dgputemp:0:ec:psta 2>/dev/null | awk '{print $2}'), kernel heap $(kheap)"
  done
fi
l0=$(wc -l < "$LOG" | tr -d ' ')   # LOG is appended across boots: look only at this probe's lines
"$PROBE" -w 0 >> "$LOG" 2>&1 &
pid=$!
# nvidia_modeset loads only once RM is up: wait (up to 120 s) for this probe's "holding the GPU open" line
held() { tail -n +$((l0 + 1)) "$LOG" | grep -q '^holding the GPU open'; }
if [ "${MODESET:-0}" = 1 ]; then
  n=0
  while [ $n -lt 120 ] && kill -0 "$pid" 2>/dev/null && ! held; do sleep 1; n=$((n + 1)); done
  if held; then drm_up; else log "nvidia_modeset: RM not up after ${n}s; not configured"; fi
fi
i=0
while kill -0 "$pid" 2>/dev/null; do
  sleep 60; i=$((i + 60))
  # RM's own GPU temperature beside the EC's, so the two sensors can be compared
  log "up ${i}s: RM GPU $("$PROBE" -t 2>/dev/null) C, EC GPUT $(kstat -p dgputemp:0:ec:gput_C 2>/dev/null | awk '{print $2}') C, kernel heap $(kheap)"
done
fail "nvidia-probe exited (RmInitAdapter/GSP failed? see the probe lines above)"
