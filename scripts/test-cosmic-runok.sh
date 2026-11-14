#!/usr/bin/bash
# test-cosmic-runok.sh [cosmic-build.sh]: cosmic-build.sh's run check (runok) on an app that daemonizes (fork, setsid, then
# keeps writing into the build dir, as cosmic-files and cosmic-edit do through fork::daemon). After runok returns, the
# build dir must be removable at once, as the builder's EXIT trap removes it. illumos only (ctrun).
#   FIX: runok as cosmic-build.sh has it (the check in its own process contract, -o noorphan): the child is gone.
#   NEG: the same runok with the ctrun prefix taken out: the child is still writing, the removal fails "File exists"
#        or the dir is not empty (the BE 53 and 11-11 failures).
set -u
B=${1:-$(cd "$(dirname "$0")/.." && pwd)/pkgs/illumos/graphics/cosmic-build.sh}
PY=${PYTHON3:-python3}
bad=0; ok() { echo "ok: $1"; }; no() { echo "FAIL: $1"; bad=1; }
T=$(mktemp -d /var/tmp/runok.XXXXXX)
sed -n '/^runok() {/,/^}/p' "$B" > $T/runok.fix
grep -q 'ctrun -l child -o noorphan' $T/runok.fix || { echo "FAIL: no ctrun in $B's runok"; exit 1; }
sed 's|/usr/bin/ctrun -l child -o noorphan ||' $T/runok.fix > $T/runok.neg   # the same check without its contract
cmp -s $T/runok.fix $T/runok.neg && { echo "FAIL: NEG is the same as FIX"; exit 1; }
mkdir -p $T/out/bin
cat > $T/out/bin/fakeapp <<E
#!$PY
import os, sys, time
if os.fork() == 0:
    os.setsid()
    for i in range(150):
        d = os.path.join(os.environ["W"], "home", ".config", "cosmic", "v1")
        os.makedirs(d, exist_ok=True); open(os.path.join(d, "k%d" % i), "w").write("x")
        time.sleep(0.02)
    os._exit(0)
print("usage: fakeapp")
E
chmod +x $T/out/bin/fakeapp
for v in fix neg; do
  W=$T/w-$v; mkdir -p $W
  ( out=$T/out W=$W; export W; . $T/runok.$v; runok fakeapp --help ) > $T/$v.log 2>&1
  sleep 0.1
  r=0; rm -r "$W" 2> $T/$v.rm || r=$?
  sleep 1
  if [ $r = 0 ] && [ ! -e "$W" ]; then echo "$v: removed cleanly"; else echo "$v: removal rc=$r ($(head -1 $T/$v.rm)), left: $(find $W 2>/dev/null | wc -l) entries"; fi > $T/$v.res
  cat $T/$v.res
done
grep -q 'removed cleanly' $T/fix.res && ok "the check's daemon child dies with the check: the build dir is removable" || no "FIX: $(cat $T/fix.res)"
grep -q 'removed cleanly' $T/neg.res && no "NEG removed cleanly: the test does not reproduce the race" || ok "NEG: without the contract the child outlives the check ($(cut -d: -f2- $T/neg.res))"
# runok judges the exit status: it must see the app's own (0, an error exit, timeout's 124, a signal death >= 128)
rcof() { mkdir -p $T/rc; W=$T/rc; printf '#!/bin/sh\n%s\n' "$1" > $T/out/bin/rcapp; chmod +x $T/out/bin/rcapp
  ( out=$T/out W=$W; . $T/runok.fix; runok rcapp ) > $T/rc.log 2>&1; grep -o '^rc=[0-9]*' $W/solnix-check/rcapp.txt | tail -1 | cut -d= -f2; }
a=$(rcof 'exit 0'); b=$(rcof 'exit 3'); c=$(rcof 'sleep 30'); d=$(rcof 'kill -ABRT $$')
[ "$a" = 0 ] && [ "$b" = 3 ] && [ "$c" = 124 ] && [ "${d:-0}" -ge 128 ] && ok "runok sees the app's status through the contract (0, 3, 124, $d)" ||
  no "runok status: exit0->$a exit3->$b hang->$c abort->$d"
sleep 3   # the NEG run's child stops on its own (150 x 0.02 s); nothing here kills by name
rm -r $T 2>/dev/null
[ $bad = 0 ] && echo "RESULT PASS" || echo "RESULT FAIL"; exit $bad
