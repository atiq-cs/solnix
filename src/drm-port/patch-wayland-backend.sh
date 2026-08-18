#!/usr/bin/env bash
# Apply illumos/solaris arms to a vendored wayland-backend 0.3.x (epoll + CMSG_CLOEXEC).
set -eu
WB="${1:?usage: patch-wayland-backend.sh <vendor/wayland-backend dir>}"
CP="$WB/src/rs/server_impl/common_poll.rs"
HD="$WB/src/rs/server_impl/handle.rs"
SK="$WB/src/rs/socket.rs"
# common_poll.rs: single-line epoll cfgs
gsed -i 's/#\[cfg(any(target_os = "linux", target_os = "android", target_os = "redox"))\]/#[cfg(any(target_os = "linux", target_os = "android", target_os = "redox", target_os = "illumos", target_os = "solaris"))]/g' "$CP"
# common_poll.rs: multi-line epoll::delete cfg
perl -0pi -e 's/target_os = "linux",\n(\s*)target_os = "android",\n(\s*)target_os = "redox"\n/target_os = "linux",\n$1target_os = "android",\n$2target_os = "redox",\n$2target_os = "illumos",\n$2target_os = "solaris"\n/g' "$CP"
# handle.rs: the `let ret = {` epoll register-client cfg
perl -0pi -e 's/#\[cfg\(any\(target_os = "linux", target_os = "android", target_os = "redox"\)\)\]\n(\s*)let ret = \{/#[cfg(any(target_os = "linux", target_os = "android", target_os = "redox", target_os = "illumos", target_os = "solaris"))]\n$1let ret = {/g' "$HD"
# socket.rs: CMSG_CLOEXEC (illumos rustix lacks it) -> DONTWAIT + fcntl fallback
perl -0pi -e 's/#\[cfg\(not\(any\(target_os = "macos", target_os = "redox"\)\)\)\]/#[cfg(not(any(target_os = "macos", target_os = "redox", target_os = "illumos", target_os = "solaris")))]/g' "$SK"
perl -0pi -e 's/#\[cfg\(any\(target_os = "macos", target_os = "redox"\)\)\]/#[cfg(any(target_os = "macos", target_os = "redox", target_os = "illumos", target_os = "solaris"))]/g' "$SK"
# clear vendored per-file checksums (keep package key for lock verify)
python3 - "$WB/.cargo-checksum.json" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p)); d["files"]={}; json.dump(d,open(p,"w"))
PY
echo "patched $WB"
