#!/usr/bin/env bash
# browser-run.sh <bundle dir> <tag> -- tryit1: serve the bundle on 127.0.0.1, start headless Chromium with a fresh
# profile, run browser-test.mjs against a cache-busted URL, then stop both. Output: $LOGS/browser-<tag>.out
set -u; B=$1; T=$2; H="$(cd "$(dirname "$0")" && pwd)"; L=${LOGS:-$HOME/w/logs}; mkdir -p $L
P=$((8100 + RANDOM % 800)); C=$((9300 + RANDOM % 600)); PROF=$(mktemp -d)
( cd "$B" && exec python3 -m http.server $P --bind 127.0.0.1 ) > $L/http-$T.log 2>&1 & HP=$!
chromium --headless=new --no-sandbox --disable-gpu --user-data-dir=$PROF --remote-debugging-port=$C \
	--remote-allow-origins='*' about:blank > $L/chromium-$T.log 2>&1 & CP=$!
for _ in $(seq 1 50); do curl -s http://127.0.0.1:$C/json/list >/dev/null 2>&1 && break; sleep 0.2; done
WS=$(curl -s http://127.0.0.1:$C/json/list | python3 -c 'import json,sys;print([t for t in json.load(sys.stdin) if t["type"]=="page"][0]["webSocketDebuggerUrl"])')
CDP=$WS timeout -s KILL 240 node "$H/browser-test.mjs" "http://127.0.0.1:$P/index.html?cb=$(date +%s%N)" > $L/browser-$T.out 2>&1; rc=$?
kill $CP $HP 2>/dev/null; wait $CP $HP 2>/dev/null; find $PROF -depth -delete 2>/dev/null
grep -E '^(CHECK|SUMMARY)' $L/browser-$T.out; echo "rc=$rc"
