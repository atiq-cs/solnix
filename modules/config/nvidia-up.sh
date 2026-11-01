#!/bin/sh
# solnix-nvidia: bring the dGPU up once the dump device is armed (hardware.graphics.nvidia.attachAtBoot).
# Runs after site/solnix-nvidia-guard (the thermal guard, which covers the whole time the GPU is powered)
# and system/dumpadm, so a panic in the first RmInitAdapter leaves a dump.
#
# nvidia is bound at boot with NVreg_GpuInitOnProbe=0: its PCI attach maps the BARs and makes /dev/nvidia0
# without touching the GSP. The probe's first open of /dev/nvidia0 runs RmInitAdapter and boots the GSP,
# and the probe keeps it open (RM shuts the GPU down at the last close). A failure is logged with the
# kernel's messages and left to the guard: no reboot here, so the failed state can be read over ssh.
# env: PROBE (nvidia-probe), LOG, OKFILE (the guard's per-sample file).
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
[ -c /dev/nvidiactl ] || fail "no /dev/nvidiactl (nvidia did not attach)"
[ -c /dev/nvidia0 ] || fail "no /dev/nvidia0 (the GPU did not attach)"
"$PROBE" -w 0 >> "$LOG" 2>&1 &
pid=$!
i=0
while kill -0 "$pid" 2>/dev/null; do
  sleep 60; i=$((i + 60))
  # RM's own GPU temperature beside the EC's, so the two sensors can be compared
  log "up ${i}s: RM GPU $("$PROBE" -t 2>/dev/null) C, EC GPUT $(kstat -p dgputemp:0:ec:gput_C 2>/dev/null | awk '{print $2}') C, kernel heap $(kheap)"
done
fail "nvidia-probe exited (RmInitAdapter/GSP failed? see the probe lines above)"
