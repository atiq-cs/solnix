#!/usr/bin/bash
# cosmic-itest tier 0 (docs/cosmic-illumos-integration-tests.md): static and probe checks, no desktop session, safe while
# someone uses the machine. Each check: PASS | FAIL | GAP | SKIP, then a summary line. Override the object a check inspects
# with an env var to run its negative control (run.sh --negctl does that), e.g. ITEST_I915=<old module> must FAIL.
#   t0.sh            the installed system;   ITEST_JSON=<file> also writes JSON lines
PATH=/run/current-system/sw/bin:/usr/bin:/usr/sbin
pass=0 fail=0 gap=0 skip=0
r() { printf '%-5s %-28s %s\n' "$1" "$2" "$3"; [ -n "$ITEST_JSON" ] && printf '{"tier":0,"check":"%s","status":"%s","detail":"%s"}\n' "$2" "$1" "$3" >> "$ITEST_JSON"
      case $1 in PASS) pass=$((pass+1));; FAIL) fail=$((fail+1));; GAP) gap=$((gap+1));; *) skip=$((skip+1));; esac; }
OBJDUMP=$(command -v gobjdump || echo /usr/bin/gobjdump)
# realpath without readlink(1) (not on every illumos): follow symlinks with ls -l
rp() { f=$1; i=0; while [ -L "$f" ] && [ $i -lt 20 ]; do l=$(ls -l "$f" | sed 's/.* -> //'); case $l in /*) f=$l;; *) f=$(dirname "$f")/$l;; esac; i=$((i+1)); done; echo "$f"; }
I915=${ITEST_I915:-$(rp /run/current-system/kernel/drv/amd64/i915)}

# 1. i915 errno ABI: drm_syncobj_array_wait_timeout's timeout return is -ETIME (62 on illumos), not -ETIMEDOUT (145)
if [ -r "$I915" ]; then
  d=$($OBJDUMP -d --no-show-raw-insn "$I915" 2>/dev/null | awk '/<drm_syncobj_array_wait_timeout[^>]*>:/{f=1;next} f&&/^$/{exit} f')
  if [ -z "$d" ]; then r SKIP i915-errno-etime "no drm_syncobj_array_wait_timeout in $I915"
  elif echo "$d" | grep -qiE '\$0xffffffffffffff6f|\$-0x91'; then r FAIL i915-errno-etime "returns -145 (ETIMEDOUT): $I915"
  elif echo "$d" | grep -qiE '\$0xffffffffffffffc2|\$-0x3e'; then r PASS i915-errno-etime "returns -62 (ETIME)"
  else r FAIL i915-errno-etime "neither constant found in $I915"; fi
  # 2. MSI barrier: intr_barrier must not toggle the vector (no ddi_intr_disable/enable calls in it)
  b=$($OBJDUMP -dr --no-show-raw-insn "$I915" 2>/dev/null | awk '/<intr_barrier>:/{f=1;next} f&&/^$/{exit} f')
  if [ -z "$b" ]; then r SKIP i915-intr-barrier "no intr_barrier symbol"
  elif echo "$b" | grep -qE 'ddi_intr_(disable|enable)'; then r FAIL i915-intr-barrier "toggles MSI enable (ddi_intr_disable/enable)"
  else r PASS i915-intr-barrier "waits for handlers, no MSI toggle"; fi
else r SKIP i915-errno-etime "no module at $I915"; r SKIP i915-intr-barrier "no module"; fi

# 3. event loops: every COSMIC binary built with `polling` uses its epoll backend, not event ports (calloop self-wake loop)
bad= n=0
for f in ${ITEST_POLLING_BINS:-$(ls /run/current-system/sw/bin/cosmic-* /run/current-system/sw/libexec/cosmic-* 2>/dev/null)}; do
  f=$(rp "$f"); [ -f "$f" ] || continue
  s=$(elfdump -s -N .symtab "$f" 2>/dev/null) || continue
  p=$(echo "$s" | grep -c '7polling4port'); e=$(echo "$s" | grep -c '7polling5epoll')
  [ "$p" -eq 0 ] && [ "$e" -eq 0 ] && continue
  n=$((n+1)); [ "$p" -gt 0 ] && bad="$bad $(basename "$f")"
done
if [ "$n" -eq 0 ]; then r SKIP polling-epoll "no binary with polling symbols"
elif [ -n "$bad" ]; then r FAIL polling-epoll "event-port backend in:$bad"
else r PASS polling-epoll "$n binaries, all epoll"; fi

# 4. mimalloc: pop-launcher starts and exits cleanly (mimalloc 2.x's NULL-segment test on illumos amd64 addresses)
PL=${ITEST_POPLAUNCHER:-/run/current-system/sw/bin/pop-launcher}
if [ -x "$PL" ]; then
  echo '"Exit"' | env -i PATH=/usr/bin HOME=/tmp "$PL" > /dev/null 2>&1; rc=$?
  [ $rc -eq 0 ] && r PASS mimalloc-pop-launcher "rc 0" || r FAIL mimalloc-pop-launcher "rc $rc (139 = SIGSEGV): $PL"
else r SKIP mimalloc-pop-launcher "no pop-launcher"; fi

# 5. audio: a sound device, and a 1 s tone takes 1 s (the device really clocks samples out)
if ls /dev/sound/*dsp > /dev/null 2>&1; then
  if [ -r /dev/dsp ] || [ "$(id -u)" = 0 ]; then
    t=$(mktemp /tmp/itest.XXXXXX.au); printf '.snd\0\0\0\x18\0\x01\x77\0\0\0\0\x03\0\0\xbb\x80\0\0\0\x01' > "$t"; head -c 96000 /dev/zero >> "$t"
    s=$(date +%s%N); audioplay "$t" > /dev/null 2>&1; rc=$?; e=$(( ($(date +%s%N) - s) / 1000000 )); rm -f "$t"
    [ $rc -eq 0 ] && [ $e -ge 800 ] && [ $e -le 1400 ] && r PASS audio-device "1 s of samples played in ${e} ms" || r FAIL audio-device "audioplay rc $rc in ${e} ms"
  else r SKIP audio-device "/dev/sound present; no permission (console owner only)"; fi
else r FAIL audio-device "no /dev/sound/*dsp"; fi

# 6. touchpad: ihid is attached and polling with no errors
if kstat -m ihid > /dev/null 2>&1; then
  e=$(kstat -p ihid:::errors 2>/dev/null | awk '{s+=$2} END {print s+0}'); p=$(kstat -p ihid:::polls 2>/dev/null | awk '{s+=$2} END {print s+0}')
  [ "$p" -gt 0 ] && [ "$e" -eq 0 ] && r PASS touchpad-ihid "polls $p, errors 0" || r FAIL touchpad-ihid "polls $p errors $e"
else r GAP touchpad-ihid "no ihid instance (hardware.touchpad.i2cHid off?)"; fi

# 7. data the session needs: desktop entries and cursor themes reach sw/share
a=$(ls /run/current-system/sw/share/applications/*.desktop 2>/dev/null | wc -l)
[ "$a" -ge 50 ] && r PASS xdg-applications "$a desktop entries" || r FAIL xdg-applications "$a desktop entries (< 50)"
ls /run/current-system/sw/share/applications/com.system76.CosmicTerm.desktop > /dev/null 2>&1 && r PASS cosmic-term-desktop "present" || r GAP cosmic-term-desktop "no CosmicTerm.desktop (held for the hash-B wave)"

# 8. integrations not present yet (GAP rows from docs/cosmic-illumos-integration-tests.md section 7)
for g in pipewire:audio-server upower:battery NetworkManager:network-applet bluetoothd:bluetooth xdg-desktop-portal:portal; do
  command -v "${g%%:*}" > /dev/null 2>&1 && r PASS "${g#*:}" "${g%%:*} present" || r GAP "${g#*:}" "no ${g%%:*}"; done

echo "cosmic-itest t0: $pass PASS $fail FAIL $gap GAP $skip SKIP"
[ $fail -eq 0 ]
