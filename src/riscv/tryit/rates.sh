#!/usr/bin/env bash
# rates.sh N -- tryit1: N native boot-test.py runs + N headless-browser runs of the bundle, interleaved; one line each.
set -u; N=${1:-8}; H="$(cd "$(dirname "$0")" && pwd)"; L=${LOGS:-$HOME/w/logs}; mkdir -p $L
for i in $(seq 1 $N); do
	r=$(timeout -s KILL 200 python3 $H/boot-test.py $HOME/w/te/tinyemu-solnix/temu $HOME/w/img $L/native-r$i.log 2>&1)
	echo "native $i: $(echo "$r" | grep SUMMARY) login $(echo "$r" | grep login-prompt | awk '{print $NF}') $(echo "$r" | grep 'CHECK FAIL' | tr '\n' ' ')"
	r=$(bash $H/browser-run.sh $HOME/w/bundle/solnix-wasm-demo r$i 2>&1)
	echo "browser $i: $(echo "$r" | grep SUMMARY) login $(echo "$r" | grep login-prompt | awk '{print $NF}') $(echo "$r" | grep 'CHECK FAIL' | tr '\n' ' ')"
done
echo RATES_DONE
