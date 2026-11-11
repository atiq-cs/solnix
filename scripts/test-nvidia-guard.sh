#!/bin/sh
# test-nvidia-guard.sh -- modules/config/nvidia-guard.sh against stub tools (no GPU, no EC, no reboot).
# The stub kstat prints the temperature in $T/temp (empty = unreadable), psta and pr3_sta from $T/psta and
# $T/pr3_sta (default 1 = powered). A sequence file $T/seq.<stat> gives one value per sample instead (the
# sample counter advances on each read of the temperature). PASS when the guard reboots exactly in the
# failure cases, never in the healthy one, and DRYRUN=1 only logs "would reboot".
# usage: sh scripts/test-nvidia-guard.sh   (GUARD=<file> tests another copy: the negative controls)
set -u
G=${GUARD:-$(cd "$(dirname "$0")/.." && pwd)/modules/config/nvidia-guard.sh}
T=$(mktemp -d "${TMPDIR:-/tmp}/nvguard.XXXXXX"); trap 'find "$T" -depth -delete' EXIT
mkdir -p "$T/bin"
for c in dmesg sync modload; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$c"; done
printf '#!/bin/sh\necho REBOOT >> "%s/reboots"\nexit 0\n' "$T" > "$T/bin/reboot"
cat > "$T/bin/kstat" <<EOF
#!/bin/sh
s=\${2##*:}; T=$T
if [ "\$s" = gput_C ] || [ "\$s" = tmp0_C ]; then f=\$T/temp; echo \$((\$(cat \$T/n 2>/dev/null || echo 0) + 1)) > \$T/n
else f=\$T/\$s; [ -f \$f ] || [ -f \$T/seq.\$s ] || { printf '%s\\t1\\n' "\$2"; exit 0; }; fi
n=\$(cat \$T/n 2>/dev/null || echo 1)
if [ -f \$T/seq.\$s ]; then t=\$(sed -n "\${n}p" \$T/seq.\$s); [ -n "\$t" ] || t=\$(tail -1 \$T/seq.\$s)
else t=\$(cat \$f 2>/dev/null); fi
[ "\$t" = none ] && t=
[ -n "\$t" ] && printf '%s\\t%s\\n' "\$2" "\$t"
exit 0
EOF
chmod +x "$T"/bin/*
fail=0
run() {  # name want(reboot|ok|would) temp [env...]; psta/pr3_sta/seq.* files are set by the caller
  name=$1 want=$2; : > "$T/reboots"; : > "$T/log"; printf '%s' "$3" > "$T/temp"; rm -f "$T/n"; shift 3
  sed -e "s#^PATH=.*#PATH=$T/bin:/usr/bin:/bin#" "$G" > "$T/g.sh"
  env MAXT=80 INTERVAL=0 SAMPLES=50 LOG="$T/log" OKFILE="$T/ok" "$@" sh "$T/g.sh" > /dev/null 2>&1
  got=ok; grep -q 'would reboot' "$T/log" && got=would; grep -q REBOOT "$T/reboots" && got=reboot
  if [ "$got" = "$want" ]; then echo "PASS $name ($got)"; else echo "FAIL $name: want $want, got $got"; tail -2 "$T/log"; fail=1; fi
}
run healthy        ok     52
run hot            reboot 94
run at-limit       reboot 80
run unreadable     reboot ""
run garbage        reboot "?"
run negative       reboot -1
run dryrun-hot     would  94 DRYRUN=1
run dryrun-quiet   ok     52 DRYRUN=1
# runtime D3cold: no reading is fine only while the hardware says the GPU is off
off() { printf '%s' "$1" > "$T/psta"; printf '%s' "$2" > "$T/pr3_sta"; }
off 0 0; run off-both-0       ok     -1
off 0 0; run off-empty        ok     ""
off 0 1; run off-psta-only    reboot -1
off 1 0; run off-sta-only     reboot -1
off "" 0; run off-psta-unread reboot -1
off 0 0; run off-but-hot      reboot 94
rm -f "$T/psta" "$T/pr3_sta"
# off -> on: up to GRACE (5 here) unreadable samples while powered, then a reading
printf '%s\n' -1 -1 -1 -1 -1 -1 55 > "$T/seq.gput_C"; printf '%s\n' 0 1 1 1 1 1 1 > "$T/seq.psta"; cp "$T/seq.psta" "$T/seq.pr3_sta"
run on-grace-ok       ok     x SAMPLES=7 GRACE=5
printf '%s\n' -1 -1 -1 -1 -1 -1 -1 55 > "$T/seq.gput_C"; printf '%s\n' 0 1 1 1 1 1 1 1 > "$T/seq.psta"; cp "$T/seq.psta" "$T/seq.pr3_sta"
run on-grace-over     reboot x SAMPLES=8 GRACE=5
# no grace without a preceding off: powered and unreadable from the first sample
printf '%s\n' -1 55 > "$T/seq.gput_C"; printf '%s\n' 1 1 > "$T/seq.psta"; cp "$T/seq.psta" "$T/seq.pr3_sta"
run no-off-no-grace   reboot x SAMPLES=2
rm -f "$T"/seq.*
# the bring-up (nvidia-up.sh) must refuse to start RM unless the guard renews OKFILE
U=$(dirname "$G")/nvidia-up.sh
for c in devfsadm dumpadm mdb; do printf '#!/bin/sh\nexit 0\n' > "$T/bin/$c"; done; chmod +x "$T"/bin/*
sed -e "s#^PATH=.*#PATH=$T/bin:/usr/bin:/bin#" -e "s#sleep 10#sleep 1#" "$U" > "$T/u.sh"
: > "$T/log"; rm -f "$T/ok"; PROBE=/bin/false LOG="$T/log" OKFILE="$T/ok" sh "$T/u.sh" > /dev/null 2>&1
if grep -q 'guard is not sampling' "$T/log"; then echo "PASS up-without-guard (refused)"; else echo "FAIL up-without-guard"; fail=1; fi
: > "$T/log"; ( while :; do touch "$T/ok"; /bin/sleep 0.2; done ) & tp=$!
PROBE=/bin/false LOG="$T/log" OKFILE="$T/ok" sh "$T/u.sh" > /dev/null 2>&1; kill $tp
if grep -q 'guard is not sampling' "$T/log"; then echo "FAIL up-with-guard (refused)"; fail=1; else echo "PASS up-with-guard (past the guard check: $(grep -o 'FAILED: no /dev/nvidiactl' "$T/log"))"; fi
exit $fail
