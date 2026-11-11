#!/bin/sh
# nvidia-up.sh's MODESET/DRM path with stub tools: devfsadm, probe, the /dev and /devices nodes (no GPU).
# Cases: (1) probe holds -> nvidia_modeset configured, ctl opened; (2) a "holding" line from an EARLIER boot in LOG
# and a probe that never gets there -> must NOT configure (negative control of the per-boot window);
# (3) MODESET=0 -> nothing.
# usage: sh scripts/test-nvidia-up-drm.sh [nvidia-up.sh] [extra PATH dir]   (an illumos host has the tools in
#        /usr/bin; elsewhere pass a dir with sleep, awk, sed, grep, tail, wc, ...)
set -u
U=${1:-$(cd "$(dirname "$0")/.." && pwd)/modules/config/nvidia-up.sh}; SHIM=${2:-/usr/bin}; fail=0
T=$(mktemp -d /tmp/nvupt.XXXXXX); trap 'find "$T" -depth -delete' EXIT
mkdir -p "$T/bin" "$T/dev" "$T/devices/pseudo"
cat > "$T/bin/devfsadm" <<EOF2
#!/bin/sh
echo "devfsadm \$*" >> $T/calls
case "\$2" in nvidia) : > $T/dev/nvidiactl; : > $T/dev/nvidia0;; nvidia_modeset) : > $T/dev/nvidia-modeset;; nvidia_drm) : > $T/devices/pseudo/nvidia_drm@0:ctl;; esac
EOF2
cat > "$T/bin/probe" <<EOF2
#!/bin/sh
echo "probe \$*" >> $T/calls
[ "\$1" = -w ] || exit 0
[ -f $T/never ] || { echo "open /dev/nvidia0: ok (RM initialized the GPU)"; echo "holding the GPU open (until killed)"; }
sleep 30
EOF2
for c in dmesg dumpadm kstat; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$c"; done
chmod +x "$T"/bin/*
# the script tests -c (char device): rewrite its node paths to plain files under $T and -c to -e
sed -e "s#^PATH=.*#PATH=$T/bin:$SHIM:/usr/bin:/bin#" -e "s#sleep 10#sleep 1#" -e "s#/dev/#$T/dev/#g" \
    -e "s#/devices/#$T/devices/#g" -e 's#\[ -c #[ -e #g' -e "s#while \[ \$n -lt 120 \]#while [ \$n -lt 4 ]#" "$U" > "$T/u.sh"
run() {  # name, env..., then checks via calls
  name=$1; shift; : > "$T/calls"; : > "$T/okf"
  ( while :; do : > "$T/okf"; sleep 0.3; done ) & k=$!
  env "$@" PROBE="$T/bin/probe" LOG="$T/log" OKFILE="$T/okf" sh "$T/u.sh" > /dev/null 2>&1 & p=$!
  sleep 8; kill $p $k 2>/dev/null; pkill -f "$T/bin/probe" 2>/dev/null; wait 2>/dev/null
}
# 1
: > "$T/log"; rm -f "$T/never" "$T"/dev/* "$T"/devices/pseudo/*
run held MODESET=1 DRM=1
grep -q 'devfsadm -i nvidia_modeset' "$T/calls" && grep -q 'nvidia-drm started' "$T/log" \
  && echo "PASS held (modeset configured, drm started)" || { echo "FAIL held"; cat "$T/calls" "$T/log"; fail=1; }
# 2: negative control: an old boot's line in LOG, this probe never holds
printf 'holding the GPU open (until killed)\n' > "$T/log"; : > "$T/never"; rm -f "$T"/dev/* "$T"/devices/pseudo/*
run stale MODESET=1 DRM=1
! grep -q 'devfsadm -i nvidia_modeset' "$T/calls" && grep -q 'RM not up after' "$T/log" \
  && echo "PASS stale (an earlier boot's line is not taken)" || { echo "FAIL stale"; cat "$T/calls"; tail -5 "$T/log"; fail=1; }
# 3
: > "$T/log"; rm -f "$T/never" "$T"/dev/* "$T"/devices/pseudo/*
run off
! grep -q 'nvidia_modeset\|nvidia_drm' "$T/calls" && echo "PASS off (MODESET unset: nothing)" || { echo "FAIL off"; fail=1; }
# 4, 5: RTD3=1 -- the cold attach (open nvidia@0:nvidia-poweron) comes before any probe; a failed one stops there
: > "$T/log"; rm -f "$T/never" "$T"/dev/* "$T"/devices/pseudo/*
run cold-missing RTD3=1
grep -q 'FAILED: cold attach' "$T/log" && ! grep -q '^probe' "$T/calls" \
  && echo "PASS cold-missing (no poweron node: refused, no probe)" || { echo "FAIL cold-missing"; cat "$T/calls"; tail -5 "$T/log"; fail=1; }
: > "$T/log"; rm -f "$T/never" "$T"/dev/* "$T"/devices/pseudo/*; : > "$T/devices/pseudo/nvidia@0:nvidia-poweron"
run cold-ok RTD3=1
grep -q 'cold attach: ok' "$T/log" && grep -q '^probe' "$T/calls" \
  && echo "PASS cold-ok (cold attach, then the probe)" || { echo "FAIL cold-ok"; cat "$T/calls"; tail -5 "$T/log"; fail=1; }
exit $fail
