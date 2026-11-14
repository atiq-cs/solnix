#!/usr/bin/bash
# test-cosmic-config-watch.sh <vendor dir> <Cargo.lock> [workdir]: cosmic-config's watch() on illumos sees a changed setting
# (pkgs/illumos/graphics/cosmic-comp-vendor-fixup.sh item 14). An illumos host with cargo + a cc on PATH, offline.
#   <vendor dir>: a COSMIC app's cargo vendor dir (has cosmic-config, notify and their deps), e.g. cosmic-panel-1.11.0-vendor;
#   <Cargo.lock>: that app's Cargo.lock (the source tree's).
# Builds one probe twice, against cosmic-config as vendored (NEG) and as item 14 leaves it (FIX). The probe watches a
# config dir, sets a key from a second Config handle (atomicwrites, as cosmic-settings does), and prints the keys its
# callback got. FIX must report the key within 5 s; NEG must report nothing within 40 s (notify's default poll is 30 s).
# Exits 0 on pass, 1 on any FAIL.
set -u
V=${1:?vendor dir}; LOCK=${2:?the app's Cargo.lock (pins the vendor's git crates)}; W=${3:-$(mktemp -d /var/tmp/ccwatch.XXXXXX)}
F=$(cd "$(dirname "$0")/.." && pwd)/pkgs/illumos/graphics/cosmic-comp-vendor-fixup.sh
bad=0; ok() { echo "ok: $1"; }; no() { echo "FAIL: $1"; bad=1; }
[ -d "$V/cosmic-config" ] && [ -d "$V/notify" ] || { echo "FAIL: $V has no cosmic-config/notify"; exit 1; }
mkdir -p "$W" && cd "$W" || exit 1
for v in neg fix; do
  mkdir -p $v/vendor $v/src $v/.cargo
  for c in "$V"/*; do [ "$(basename "$c")" = cosmic-config ] || ln -sfn "$c" "$v/vendor/$(basename "$c")"; done
  cp -R "$V/cosmic-config" $v/vendor/cosmic-config; chmod -R u+w $v/vendor/cosmic-config
done
# FIX: item 14 exactly as the fixup script has it, with the script's own edit()/have() (and its checksum re-stamp)
{ echo 'V=$1'; sed -n '/^have() /p; /^edit() {/,/^}/p' "$F"; echo ': > "$V/.illumos-edited"'
  sed -n '/^# 14\. cosmic-config watch()/,/^# re-stamp checksums/p' "$F" | sed '$d'
  sed -n '/^# re-stamp checksums/,$p' "$F"; } > fix14.sh
grep -q 'RecommendedWatcher::new' fix14.sh || { echo "FAIL: no item 14 in $F"; exit 1; }
(cd "$W/fix/vendor" && bash -eu "$W/fix14.sh" "$W/fix/vendor") > fix14.log 2>&1 || { no "item 14 did not apply: $(tail -2 fix14.log)"; exit 1; }
cmp -s neg/vendor/cosmic-config/src/lib.rs fix/vendor/cosmic-config/src/lib.rs && { no "item 14 changed nothing"; exit 1; }
for v in neg fix; do
  # the vendor's own source replacements (crates-io and the git crates), pointed at this probe's vendor dir
  sed 's|^directory = .*|directory = "vendor"|' "$V/.cargo-config.toml" > $v/.cargo/config.toml
  cat > $v/Cargo.toml <<'E'
[package]
name = "ccwatch"
version = "0.0.0"
edition = "2021"
[dependencies]
cosmic-config = { path = "vendor/cosmic-config", default-features = false }
E
  cat > $v/src/main.rs <<'E'
// watch a config, set a key from another handle, print what the callback saw within the deadline
use cosmic_config::{Config, ConfigSet};
use std::{sync::mpsc, time::{Duration, Instant}};
fn main() {
    let secs: u64 = std::env::args().nth(1).and_then(|s| s.parse().ok()).unwrap_or(5);
    let a = Config::new("org.solnix.CcWatch", 1).expect("config");
    a.set("anchor", "Bottom").expect("set");
    std::thread::sleep(Duration::from_millis(1500));   // the watcher's first scan sees the key as it is
    let (tx, rx) = mpsc::channel();
    let _w = a.watch(move |_c, keys| { let _ = tx.send(keys.to_vec()); }).expect("watch");
    std::thread::sleep(Duration::from_millis(1500));
    let b = Config::new("org.solnix.CcWatch", 1).expect("config");
    b.set("anchor", "Left").expect("set");
    let t = Instant::now();
    let mut got = Vec::new();
    let mut first = None;   // every key delivered from the first event until 1.5 s after it
    while t.elapsed() < Duration::from_secs(secs) && first.map_or(true, |f: Instant| f.elapsed() < Duration::from_millis(1500)) {
        if let Ok(k) = rx.recv_timeout(Duration::from_millis(200)) { first.get_or_insert(Instant::now()); got.extend(k); }
    }
    got.sort(); got.dedup();
    println!("keys {:?} after {:.1} s", got, first.map_or(t.elapsed(), |f| f - t).as_secs_f32());
}
E
  # cargo resolves the probe from the app's lock (a git crate behind a source replacement needs a lock), then prunes it
  cp "$LOCK" $v/Cargo.lock; chmod u+w $v/Cargo.lock
  (cd $v && nice -n 19 cargo build --release --offline -j 4 > ../$v-build.log 2>&1) ||
    { no "$v probe build: $(grep '^error' $v-build.log | head -1)"; exit 1; }
done
probe() { mkdir -p "$W/home-$1"; env -i PATH="$PATH" HOME="$W/home-$1" XDG_CONFIG_HOME="$W/home-$1/.config" "$W/$1/target/release/ccwatch" "$2"; }
o=$(probe fix 5); echo "FIX: $o"
case "$o" in 'keys ["anchor"] '*) ok "patched cosmic-config: the change reaches watch() ($o)";; *) no "patched: $o";; esac
o=$(probe neg 40); echo "NEG: $o"
case "$o" in 'keys []'*) ok "NEG vendored cosmic-config: watch() never sees it in 40 s";; *) no "NEG saw a change: $o";; esac
[ $bad = 0 ] && echo "RESULT PASS" || echo "RESULT FAIL"; exit $bad
