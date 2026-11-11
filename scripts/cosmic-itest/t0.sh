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

# 6b. precision touchpad (tpad4): ihid found the PTP collection, exports an evdev node linked as /dev/input/event*, and the
# solnix libudev reports it with ID_INPUT_TOUCHPAD=1 (what cosmic-settings' Touchpad page and libinput ask). None of this
# opens the node (an open switches the pad to multitouch mode), so it is safe while the touchpad is in use.
# Negative controls: ITEST_TOUCHPAD_INPUT_DIR=/nonexistent (no node: touchpad no), ITEST_TOUCHPAD_KSTAT=<other module>.
km=${ITEST_TOUCHPAD_KSTAT:-ihid}
if kstat -p "$km:::input_mode" > /dev/null 2>&1 && [ -n "$(kstat -p "$km:::input_mode" 2>/dev/null)" ]; then
  r PASS touchpad-ptp "$km: input_mode $(kstat -p "$km:::input_mode" | awk '{print $2}'), PTP contacts kstats present"
elif kstat -m ihid > /dev/null 2>&1; then r FAIL touchpad-ptp "$km has no input_mode kstat: an ihid without PTP support"
else r GAP touchpad-ptp "no ihid instance"; fi
idir=${ITEST_TOUCHPAD_INPUT_DIR:-/dev/input}
ev=$(ls "$idir"/event* 2>/dev/null | head -1)
lu=$(ls /run/current-system/sw/lib/amd64/libudev.so.1 2>/dev/null)
if [ -z "$ev" ]; then
  kstat -m ihid > /dev/null 2>&1 && r FAIL touchpad-evdev-node "no $idir/event* (devlink.tab ddi_input:evdev rule?)" || r GAP touchpad-evdev-node "no ihid"
else
  t=$(rp "$ev"); case $t in *ihid@*:event) r PASS touchpad-evdev-node "$ev -> $t";; *) r FAIL touchpad-evdev-node "$ev -> $t (not ihid's event minor)";; esac
fi
if [ -n "$lu" ] && command -v udevtest > /dev/null 2>&1; then
  LIBUDEV_SOLNIX_INPUT_DIR=$idir udevtest > /dev/null 2>&1 && r PASS touchpad-udev "libudev: ID_INPUT_TOUCHPAD=1 under $idir" \
    || r FAIL touchpad-udev "libudev reports no touchpad under $idir"
else r GAP touchpad-udev "no solnix libudev/udevtest in the system profile"; fi

# 7. data the session needs: desktop entries and cursor themes reach sw/share
a=$(ls /run/current-system/sw/share/applications/*.desktop 2>/dev/null | wc -l)
[ "$a" -ge 50 ] && r PASS xdg-applications "$a desktop entries" || r FAIL xdg-applications "$a desktop entries (< 50)"
ls /run/current-system/sw/share/applications/com.system76.CosmicTerm.desktop > /dev/null 2>&1 && r PASS cosmic-term-desktop "present" || r FAIL cosmic-term-desktop "no CosmicTerm.desktop: COSMIC Terminal is not in the launcher"

# 7b. help on the desktop (help1): the man: URI handler is the default for x-scheme-handler/man, it refuses a URI that
# is not a page name, and the launcher's man plugin answers "man ls" from the whatis index. Files only, no window.
# Negative controls: ITEST_HELP_SHARE=<a share dir without the handler>, ITEST_HELP_PLUGIN=<a plugin.ron naming no plugin>.
hs=${ITEST_HELP_SHARE:-/run/current-system/sw/share}
d=$(HOME=/nonexistent XDG_DATA_HOME=/nonexistent XDG_CONFIG_HOME=/nonexistent XDG_DATA_DIRS=$hs xdg-mime query default x-scheme-handler/man 2>/dev/null)
c=$(SOLNIX_MAN_OPEN_PRINT=1 solnix-man-open 'man:printf(3c)' 2>&1); x=$(SOLNIX_MAN_OPEN_PRINT=1 solnix-man-open 'man:ls;id' 2>&1) && x=accepted
if [ "$d" = solnix-man.desktop ] && [ "$c" = "man -s 3c printf" ] && [ "$x" != accepted ]; then r PASS help-man-uri "x-scheme-handler/man -> $d"
else r FAIL help-man-uri "default '${d:-none}' in $hs, 'man:printf(3c)' -> '$c', 'man:ls;id' $([ "$x" = accepted ] && echo ACCEPTED || echo refused)"; fi
pr=${ITEST_HELP_PLUGIN:-/etc/pop-launcher/plugins/man/plugin.ron}; pb=$(sed -n 's/.*path: "\(.*\)".*/\1/p' "$pr" 2>/dev/null)
po=$([ -x "$pb" ] && printf '{"Search":"man ls"}\n"Exit"\n' | "$pb" 2>/dev/null)
echo "$po" | grep -q '"name":"ls(1)' && r PASS help-launcher-man "$pr answers 'man ls'" || r FAIL help-launcher-man "plugin '${pb:-none}' from $pr: ${po:-no answer}"
[ -e /run/current-system/sw/share/applications/solnix-manual.desktop ] && r PASS help-manual-entry "Solnix Manual desktop entry" \
  || r FAIL help-manual-entry "no solnix-manual.desktop"

# 7c. accounts: cosmic-settings' Users page and cosmic-greeter list every passwd uid in login.defs' UID_MIN..UID_MAX
# (1000..60000 when the file is missing). None of those may be a system account (no-login shell or /var/empty home).
# Negative control: ITEST_LOGINDEFS=/nonexistent (cosmic-settings' fallback range takes in nixbld 30001+).
ld=${ITEST_LOGINDEFS:-/etc/login.defs}
lo=$(awk '$1=="UID_MIN"{print $2}' "$ld" 2>/dev/null); hi=$(awk '$1=="UID_MAX"{print $2}' "$ld" 2>/dev/null)
sa=$(getent passwd | awk -F: -v lo="${lo:-1000}" -v hi="${hi:-60000}" '$3>=lo && $3<=hi && ($7~/(false|nologin)$/ || $6=="/var/empty"){printf " %s", $1}')
[ -z "$sa" ] && r PASS users-uid-range "no system account in ${lo:-1000}..${hi:-60000} ($ld)" \
  || r FAIL users-uid-range "system accounts in ${lo:-1000}..${hi:-60000} ($ld):$(echo $sa | cut -c1-80)"

# 7d. accounts: Settings > Users shows a user as Administrator iff org.freedesktop.Accounts says AccountType 1. Every user
# with the Primary Administrator profile in user_attr must get 1 from solnix-accounts (services.solnix-accounts).
# Without the service the page falls back to the group sudo and shows nobody as an administrator.
# Negative control: ITEST_ACCOUNTS_DEST=<a name nobody owns> (the bus answers ServiceUnknown, as with no service).
ad=${ITEST_ACCOUNTS_DEST:-org.freedesktop.Accounts}
pa=$(awk -F: '!/^#/ && $5 ~ /(^|;)profiles=([^;]*,)?Primary Administrator(,|;|$)/ {print $1}' /etc/user_attr 2>/dev/null)
if [ -z "$pa" ]; then r SKIP users-admin "no Primary Administrator user in /etc/user_attr"
else bad= ok=
  for u in $pa; do id=$(getent passwd "$u" | cut -d: -f3); [ -n "$id" ] || continue
    t=$(dbus-send --system --print-reply --dest="$ad" "/org/freedesktop/Accounts/User$id" org.freedesktop.DBus.Properties.Get \
        string:org.freedesktop.Accounts.User string:AccountType 2>&1 | awk '/int32/{print $NF}')
    [ "$t" = 1 ] && ok="$ok $u" || bad="$bad $u(${t:-no answer})"; done
  [ -z "$bad" ] && [ -n "$ok" ] && r PASS users-admin "AccountType 1 from $ad:$ok" || r FAIL users-admin "not administrator in Settings > Users:$bad (services.solnix-accounts)"
fi

# 8. integrations not present yet (GAP rows from docs/cosmic-illumos-integration-tests.md section 7)
for g in pipewire:audio-server upower:battery NetworkManager:network-applet bluetoothd:bluetooth xdg-desktop-portal:portal; do
  command -v "${g%%:*}" > /dev/null 2>&1 && r PASS "${g#*:}" "${g%%:*} present" || r GAP "${g#*:}" "no ${g%%:*}"; done

echo "cosmic-itest t0: $pass PASS $fail FAIL $gap GAP $skip SKIP"
[ $fail -eq 0 ]
